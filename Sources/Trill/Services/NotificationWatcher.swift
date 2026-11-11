import Foundation
import AppKit
import ApplicationServices
import TrillCore

/// Watches the system notification UI process through the Accessibility API and reports
/// newly appeared banners. All AX work happens on one dedicated thread (with its own run loop).
final class NotificationWatcher: @unchecked Sendable {
    static let notificationUIBundleID = "com.apple.notificationcenterui"

    /// Called on the watcher thread. Hop to the main actor yourself.
    var onNotification: (@Sendable (CapturedNotification) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?
    private var stopRequested = false

    // Watcher-thread-only state.
    private var pid: pid_t = 0
    private var appElement: AXUIElement?
    private var observer: AXObserver?
    private var registeredWindows = Set<CFHashCode>()
    private var shown: [String: Date] = [:]          // fired (or baseline) banners -> last time seen
    private var pending: [String: Date] = [:]        // candidate banners -> first time seen (needs to be stable)
    private var scanScheduled = false
    private var lastStatus = ""
    private var lastShape = "no banners seen yet"

    private static let stableDelay: TimeInterval = 0.25
    private static let shownTTL: TimeInterval = 2.5

    // MARK: Lifecycle

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard thread == nil else { return }
        stopRequested = false
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "Trill.NotificationWatcher"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    func stop() {
        lock.lock()
        stopRequested = true
        let rl = threadRunLoop
        thread = nil
        lock.unlock()
        if let rl { CFRunLoopStop(rl) }
    }

    private var isStopRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func threadMain() {
        lock.lock(); threadRunLoop = CFRunLoopGetCurrent(); lock.unlock()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.current.add(timer, forMode: .default)
        tick()
        while !isStopRequested {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1.0))
        }
        timer.invalidate()
        detach()
        lock.lock(); threadRunLoop = nil; lock.unlock()
    }

    // MARK: Attach / detach

    private func report(_ s: String) {
        guard s != lastStatus else { return }
        lastStatus = s
        onStatus?(s)
    }

    private func tick() {
        guard AXIsProcessTrusted() else {
            detach()
            report("Accessibility permission not granted")
            return
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.notificationUIBundleID).first else {
            detach()
            report("Notification UI process (\(Self.notificationUIBundleID)) is not running")
            return
        }
        if app.processIdentifier != pid || appElement == nil {
            detach()
            attach(pid: app.processIdentifier)
        }
        scan(suppress: false)
    }

    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let me = Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue()
        me.scheduleScan(after: 0.08)
    }

    private static let observedNotifications = [
        "AXWindowCreated", "AXCreated", "AXLayoutChanged", "AXFocusedWindowChanged",
        "AXValueChanged", "AXTitleChanged", "AXSelectedChildrenChanged", "AXUIElementDestroyed",
    ]

    private func attach(pid newPID: pid_t) {
        pid = newPID
        let el = AXUIElementCreateApplication(newPID)
        AXUIElementSetMessagingTimeout(el, 1.0)
        appElement = el
        shown.removeAll(); pending.removeAll(); registeredWindows.removeAll()

        var obs: AXObserver?
        let err = AXObserverCreate(newPID, Self.observerCallback, &obs)
        if err == .success, let obs {
            observer = obs
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            var failures: [String] = []
            for n in Self.observedNotifications {
                let e = AXObserverAddNotification(obs, el, n as CFString, refcon)
                if e != .success && e != .notificationAlreadyRegistered { failures.append("\(n):\(e.rawValue)") }
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
            if !failures.isEmpty { report("Watching pid \(newPID); some observer registrations failed (\(failures.joined(separator: ", "))); relying on polling") }
        } else {
            report("Watching pid \(newPID) by polling only (AXObserverCreate failed: \(err.rawValue))")
        }
        // Banners already on screen right now must not fire.
        scan(suppress: true)
        report("Watching notification UI (pid \(newPID)); \(lastShape)")
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        appElement = nil
        pid = 0
        registeredWindows.removeAll()
    }

    private func scheduleScan(after delay: TimeInterval) {
        guard !scanScheduled else { return }
        scanScheduled = true
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.scanScheduled = false
            self?.scan(suppress: false)
        }
        RunLoop.current.add(t, forMode: .default)
    }

    // MARK: Scanning

    private struct Candidate {
        let element: AXUIElement
        let via: String
    }

    private func topLevel(_ app: AXUIElement) -> [AXUIElement] {
        var els = AX.children(app)
        if els.isEmpty { els = AX.elements(app, "AXWindows") }
        return els
    }

    private func registerWindow(_ w: AXUIElement) {
        guard let obs = observer else { return }
        let h = CFHash(w)
        guard !registeredWindows.contains(h) else { return }
        registeredWindows.insert(h)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in ["AXLayoutChanged", "AXCreated", "AXValueChanged"] {
            _ = AXObserverAddNotification(obs, w, n as CFString, refcon)
        }
    }

    private func scan(suppress: Bool) {
        guard let app = appElement else { return }
        let now = Date()
        var candidates: [Candidate] = []
        var usedHeuristic = false
        let windows = topLevel(app)
        for w in windows {
            registerWindow(w)
            var found: [Candidate] = []
            Self.findBySubrole(w, depth: 0, into: &found)
            if found.isEmpty && !Self.looksLikeWidgetWindow(w) {
                var heur: [AXUIElement] = []
                Self.findHeuristic(w, depth: 0, into: &heur)
                found = heur.map { Candidate(element: $0, via: "heuristic") }
                if !found.isEmpty { usedHeuristic = true }
            }
            candidates.append(contentsOf: found)
        }

        var occurrences: [String: Int] = [:]
        var seenKeys = Set<String>()
        var extractedCount = 0
        for c in candidates {
            guard let n = Self.extract(from: c.element) else { continue }
            extractedCount += 1
            let sig = "\(n.appName)|\(n.title)|\(n.subtitle)|\(n.body)"
            let idx = occurrences[sig, default: 0]
            occurrences[sig] = idx + 1
            let key = "\(sig)#\(idx)"
            seenKeys.insert(key)
            if shown[key] != nil {
                shown[key] = now
            } else if suppress {
                shown[key] = now
            } else if let first = pending[key] {
                if now.timeIntervalSince(first) >= Self.stableDelay {
                    pending[key] = nil
                    shown[key] = now
                    onNotification?(n)
                } else {
                    scheduleScan(after: Self.stableDelay)
                }
            } else {
                pending[key] = now
                scheduleScan(after: Self.stableDelay)
            }
        }
        for k in pending.keys where !seenKeys.contains(k) { pending[k] = nil }
        for (k, t) in shown where now.timeIntervalSince(t) > Self.shownTTL && !seenKeys.contains(k) { shown[k] = nil }

        if !candidates.isEmpty || !windows.isEmpty {
            let via = usedHeuristic ? "heuristic extraction (no banner subrole found)" : "subrole/identifier match"
            if extractedCount > 0 {
                lastShape = "\(extractedCount) banner(s) in \(windows.count) window(s) via \(via)"
            } else if !candidates.isEmpty {
                lastShape = "banner element(s) found but no usable text (\(candidates.count) candidate(s)); run --dump-ax"
            }
        }
        if pid != 0 { report("Watching notification UI (pid \(pid)); last: \(lastShape)") }
    }

    // MARK: Banner detection

    private static func isBannerNode(_ el: AXUIElement) -> Bool {
        let sub = AX.subrole(el).lowercased()
        if sub.contains("banner") || sub.contains("alert") || sub.contains("notificationcenter") { return true }
        for attr in ["AXStackingIdentifier", "AXIdentifier"] {
            if let s = AX.string(el, attr)?.lowercased(), !s.isEmpty {
                if s.contains("bundleidentifier=") || s.contains("banner") || s.contains("notification") { return true }
            }
        }
        return false
    }

    private static func findBySubrole(_ el: AXUIElement, depth: Int, into out: inout [Candidate]) {
        if depth > 12 { return }
        if depth > 0, isBannerNode(el) {
            out.append(Candidate(element: el, via: "subrole"))
            return
        }
        for c in AX.children(el) { findBySubrole(c, depth: depth + 1, into: &out) }
    }

    /// Notification Center keeps desktop widget windows in this process; never treat those as banners.
    private static func looksLikeWidgetWindow(_ w: AXUIElement) -> Bool {
        let title = (AX.string(w, "AXTitle") ?? "").lowercased()
        if title.contains("::") || title.contains("widget") { return true }
        if AX.subrole(w) == "AXUnknown" { return true }
        return false
    }

    private struct Collected {
        var texts: [String] = []
        var images: [String] = []
        var byID: [String: String] = [:]   // AXIdentifier ("title"/"subtitle"/"body") -> text
        var nodes = 0
    }

    private static func collect(_ el: AXUIElement, depth: Int, into c: inout Collected) {
        if depth > 12 || c.nodes > 400 { return }
        c.nodes += 1
        let role = AX.role(el)
        if role == "AXStaticText" {
            let t = AX.string(el, "AXValue") ?? AX.string(el, "AXTitle") ?? AX.string(el, "AXDescription")
            if let t = t?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, c.texts.last != t {
                c.texts.append(t)
                if let id = AX.string(el, "AXIdentifier"), !id.isEmpty, c.byID[id] == nil { c.byID[id] = t }
            }
        } else if role == "AXImage" {
            if let d = AX.string(el, "AXDescription")?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
                c.images.append(d)
            }
        }
        for ch in AX.children(el) { collect(ch, depth: depth + 1, into: &c) }
    }

    private static func textCount(_ el: AXUIElement) -> Int {
        var c = Collected()
        collect(el, depth: 0, into: &c)
        return c.texts.count
    }

    /// Fallback: the smallest container under a window that holds a plausible banner's worth of text.
    private static func findHeuristic(_ el: AXUIElement, depth: Int, into out: inout [AXUIElement]) {
        if depth > 12 { return }
        let total = textCount(el)
        if total == 0 { return }
        let kids = AX.children(el)
        let textual = kids.filter { textCount($0) > 0 }
        if total > 4, !textual.isEmpty {
            for k in textual { findHeuristic(k, depth: depth + 1, into: &out) }
            return
        }
        // A window itself is never a banner unless it is all we have.
        if textual.count == 1 && AX.role(el) != "AXStaticText" && depth < 12 && AX.role(el) == "AXWindow" {
            findHeuristic(textual[0], depth: depth + 1, into: &out)
            return
        }
        out.append(el)
    }

    // MARK: Extraction

    private static let timeLike = try! NSRegularExpression(pattern: "^(now|just now|\\d+\\s?(s|m|min|h|hr|d)( ago)?|yesterday)$", options: [.caseInsensitive])

    private static func isTimeText(_ s: String) -> Bool {
        timeLike.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func lookupAppName(_ id: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        if let b = Bundle(url: url) {
            if let n = b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !n.isEmpty { return n }
            if let n = b.object(forInfoDictionaryKey: "CFBundleName") as? String, !n.isEmpty { return n }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func parseBundleID(_ s: String) -> String? {
        if let r = s.range(of: "bundleIdentifier=") {
            let rest = s[r.upperBound...]
            let id = rest.prefix { $0 != "," && $0 != ";" && $0 != " " && $0 != "&" }
            return id.isEmpty ? nil : String(id)
        }
        // Looks like a bare reverse-DNS id.
        if s.contains("."), !s.contains(" "), s.split(separator: ".").count >= 2, s.count < 120, s.first?.isLetter == true {
            return s
        }
        return nil
    }

    static func extract(from banner: AXUIElement) -> CapturedNotification? {
        var c = Collected()
        collect(banner, depth: 0, into: &c)
        var texts = c.texts.filter { !isTimeText($0) }
        guard !texts.isEmpty else { return nil }

        var bundleID: String?
        for attr in ["AXStackingIdentifier", "AXIdentifier"] {
            if bundleID == nil, let s = AX.string(banner, attr), let b = parseBundleID(s) { bundleID = b }
        }
        var appName: String? = bundleID.flatMap { lookupAppName($0) }

        let desc = (AX.string(banner, "AXDescription") ?? AX.string(banner, "AXTitle"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if appName == nil, !desc.isEmpty {
            if texts.contains(desc) {
                // description duplicates a text; not an app name
            } else if let first = texts.first, let r = desc.range(of: first) {
                // Composite description such as "Mail, Alex, Hello": app name precedes the first text.
                let prefix = desc[..<r.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " ,.:-–—\n"))
                if !prefix.isEmpty && prefix.count <= 60 { appName = prefix }
            } else if desc.count <= 60 && !desc.contains("\n") {
                appName = desc
            }
        }
        if appName == nil, let img = c.images.first(where: { !$0.isEmpty && $0.count <= 60 }) { appName = img }
        if appName == nil, texts.count >= 3 {
            let running = NSWorkspace.shared.runningApplications.compactMap { $0.localizedName?.lowercased() }
            if running.contains(texts[0].lowercased()) { appName = texts.removeFirst() }
        }
        if let a = appName, texts.count >= 2, texts[0] == a { texts.removeFirst() }
        if bundleID == nil, let a = appName {
            bundleID = NSWorkspace.shared.runningApplications.first { $0.localizedName == a }?.bundleIdentifier
                ?? InstalledApps.shared.bundleID(forName: a)
        }

        var title = texts[0]
        var subtitle = ""
        var body = ""
        if let t = c.byID["title"], !isTimeText(t) {
            // macOS 27 shape: static texts carry id "title" / "subtitle" / "body".
            title = t
            subtitle = c.byID["subtitle"] ?? ""
            body = c.byID["body"] ?? ""
        } else {
        switch texts.count {
        case 1: break
        case 2: body = texts[1]
        default:
            subtitle = texts[1]
            body = texts.dropFirst(2).joined(separator: "\n")
        }
        }
        return CapturedNotification(appName: appName ?? "", bundleID: bundleID, title: title, subtitle: subtitle, body: body)
    }

    // MARK: Dump

    /// Thorough text dump of the notification UI's AX tree (every node, depth <= 12).
    static func dumpAccessibilityTree() -> String {
        var out = ""
        let trusted = AXIsProcessTrusted()
        out += "Trill AX dump  \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "AXIsProcessTrusted: \(trusted)\n"
        if !trusted { out += "WARNING: this process is not trusted for Accessibility; the tree below will be empty.\n" }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: notificationUIBundleID)
        guard let app = apps.first else {
            out += "Process \(notificationUIBundleID) is not running.\n"
            return out
        }
        out += "Process \(notificationUIBundleID) pid \(app.processIdentifier)\n\n"
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.0)
        out += "app AXChildren error: \(AX.errorCode(el, "AXChildren").rawValue)  AXWindows error: \(AX.errorCode(el, "AXWindows").rawValue)\n"
        var count = 0
        dumpNode(el, depth: 0, count: &count, into: &out)
        let windows = AX.elements(el, "AXWindows")
        let children = AX.children(el)
        if !windows.isEmpty && children.isEmpty {
            out += "\n-- AXWindows (children was empty) --\n"
            for w in windows { dumpNode(w, depth: 1, count: &count, into: &out) }
        }
        out += "\n\(count) node(s)\n"
        return out
    }

    private static func dumpNode(_ el: AXUIElement, depth: Int, count: inout Int, into out: inout String) {
        if count >= 4000 { if count == 4000 { out += "... node limit reached\n"; count += 1 }; return }
        count += 1
        let pad = String(repeating: "  ", count: depth)
        var parts: [String] = [AX.role(el).isEmpty ? "?" : AX.role(el)]
        func add(_ label: String, _ attr: String) {
            if let s = AX.string(el, attr), !s.isEmpty {
                parts.append("\(label)=\(s.debugDescription)")
            }
        }
        add("subrole", "AXSubrole")
        add("id", "AXIdentifier")
        add("stackingId", "AXStackingIdentifier")
        add("desc", "AXDescription")
        add("title", "AXTitle")
        add("value", "AXValue")
        add("roleDesc", "AXRoleDescription")
        add("help", "AXHelp")
        if let f = AX.frame(el) {
            parts.append("frame=(\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height)))")
        }
        let names = AX.attributeNames(el)
        if !names.isEmpty { parts.append("attrs=[\(names.map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }.joined(separator: ","))]") }
        out += pad + parts.joined(separator: " ") + "\n"
        if depth >= 12 {
            if !AX.children(el).isEmpty { out += pad + "  ... depth limit\n" }
            return
        }
        for c in AX.children(el) { dumpNode(c, depth: depth + 1, count: &count, into: &out) }
    }
}
