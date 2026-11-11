import Foundation
import AVFoundation
import TrillCore

/// Assembles the sound list: macOS system sounds, built-in synthesized sounds, user sounds.
struct SoundLibrary {
    let store: Store

    var builtInDirectory: URL { store.directory.appendingPathComponent("BuiltIn", isDirectory: true) }

    func generateBuiltIns() {
        BuiltInSounds.generateIfNeeded(in: builtInDirectory)
    }

    func systemSounds() -> [Sound] {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["aiff", "aif", "caf", "wav", "mp3", "m4a"].contains($0.pathExtension.lowercased()) }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                return Sound(id: "system:\(name)", name: name, kind: .system, url: url)
            }
    }

    func builtInSounds() -> [Sound] {
        BuiltInSounds.catalog.compactMap { e in
            let url = builtInDirectory.appendingPathComponent(e.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Sound(id: e.id, name: e.name, kind: .builtIn, url: url)
        }
    }

    // MARK: Bundled sound packs

    private static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aif", "aiff", "caf", "ogg", "oga", "flac"]

    /// Where the sound packs live: the app bundle's Resources/Sounds, else $TRILL_SOUNDS_DIR, else a
    /// Resources/Sounds folder found by walking up from the executable (development runs of the bare binary).
    static func bundledSoundsDirectory() -> URL? {
        let fm = FileManager.default
        func isDir(_ u: URL) -> Bool {
            var d: ObjCBool = false
            return fm.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue
        }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Sounds", isDirectory: true), isDir(r) { return r }
        if let env = ProcessInfo.processInfo.environment["TRILL_SOUNDS_DIR"], !env.isEmpty {
            let u = URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
            if isDir(u) { return u }
        }
        var dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Resources/Sounds", isDirectory: true)
            if isDir(candidate) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    private static func slug(_ s: String) -> String {
        let mapped = s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    /// Every pack folder under the sounds directory becomes a group; ids are `pack:<pack-slug>/<file-stem-slug>`.
    func bundledPackSounds() -> [Sound] {
        guard let root = Self.bundledSoundsDirectory() else { return [] }
        let fm = FileManager.default
        let packs = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        var sounds: [Sound] = []
        for pack in packs {
            let packName = pack.lastPathComponent
            let files = (try? fm.contentsOfDirectory(at: pack, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for f in files where Self.audioExtensions.contains(f.pathExtension.lowercased()) {
                let stem = f.deletingPathExtension().lastPathComponent
                sounds.append(Sound(id: "pack:\(Self.slug(packName))/\(Self.slug(stem))", name: stem,
                                    kind: .builtIn, url: f, group: packName))
            }
        }
        return sounds
    }

    func allSounds(userSounds: [Sound]) -> [Sound] {
        func rank(_ k: Sound.Kind) -> Int {
            switch k { case .system: return 0; case .builtIn: return 1; case .user: return 2 }
        }
        let user = userSounds.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        return (systemSounds() + builtInSounds() + bundledPackSounds() + user).sorted {
            let (a, b) = (rank($0.kind), rank($1.kind))
            if a != b { return a < b }
            // Ungrouped sounds first, then by group.
            switch ($0.group, $1.group) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (x?, y?):
                let c = x.localizedStandardCompare(y)
                if c != .orderedSame { return c == .orderedAscending }
            default: break
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Copies readable audio files into the sounds directory. Returns the new sounds.
    func importFiles(_ urls: [URL]) throws -> [Sound] {
        var imported: [Sound] = []
        var firstFailure: String?
        let dir = store.soundsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard (try? AVAudioFile(forReading: url)) != nil else {
                if firstFailure == nil { firstFailure = url.lastPathComponent }
                continue
            }
            let uuid = UUID()
            let ext = url.pathExtension.isEmpty ? "caf" : url.pathExtension.lowercased()
            let dest = dir.appendingPathComponent("\(uuid.uuidString).\(ext)")
            do { try FileManager.default.copyItem(at: url, to: dest) } catch {
                if firstFailure == nil { firstFailure = url.lastPathComponent }
                continue
            }
            imported.append(Sound(id: "user:\(uuid.uuidString)", name: url.deletingPathExtension().lastPathComponent,
                                  kind: .user, url: dest))
        }
        if imported.isEmpty, let f = firstFailure { throw ServicesError.unreadableAudio(f) }
        return imported
    }
}
