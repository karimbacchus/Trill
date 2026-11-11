# Trill — plan

Trill is a native macOS menu bar app that plays a different sound per notification,
based on user-written rules (per app, channel, person, keyword). It is an original
app with the same purpose as chirpy.pro; it does not reuse that product's name,
artwork, sounds or copy. No licensing/trial code.

## Constraints

- This Mac has **Command Line Tools only, no Xcode**. Everything builds with
  `swift build` (SwiftPM). No `.xcodeproj`, no asset catalogs, no storyboards.
- swift-tools-version 5.9 (Swift 5 language mode), deployment target macOS 13.
  Dev machine runs macOS 27, Apple Silicon.
- The `.app` bundle is assembled by `Scripts/build-app.sh` and ad-hoc signed.
- Everything is local. No network code at all.

## How it works

1. `NotificationWatcher` observes the system notification UI process
   (`com.apple.notificationcenterui`) through the Accessibility API (`AXObserver`).
2. When a banner appears it extracts app name / bundle ID / title / subtitle / body
   into a `CapturedNotification`.
3. `RuleEngine` picks the first enabled rule that matches (rules are ordered).
4. `ActionRunner` performs the rule's action: play a sound at the rule's volume
   (0–200%), speak the notification, run a Shortcut, or stay silent.
5. Every captured notification is logged (in memory, last 200) for the Diagnostics window.

## Features (v1)

- Rules: optional app filter + query expression + action + per-rule volume, reorderable, enable/disable.
- Query language: bare words and "quoted phrases" (case-insensitive substring),
  `*` wildcard, `AND` / `OR` / `NOT` (uppercase keywords), parentheses, implicit AND
  between adjacent terms, optional field prefixes `title:` `subtitle:` `body:` `app:`.
  Examples: `#prod-* OR #incident-*`, `#alerts AND deploy`, `deploy NOT failed`.
  Empty query matches everything.
- Sound library: macOS system sounds (`/System/Library/Sounds`), a set of built-in
  procedurally synthesized sounds (generated to disk on first launch — we ship no
  audio files), and user-imported audio files. Preview from any list.
- Volume per rule, 0–200% (boost above 100% needs AVAudioEngine gain, not AVAudioPlayer.volume).
- Speak action with a per-rule voice and a template (`{app}`, `{title}`, `{subtitle}`, `{body}`).
- "Text to sound": synthesize typed text with a voice into an audio file saved to the library.
- Shortcut action: `/usr/bin/shortcuts run "<name>"`, notification text on stdin.
- Diagnostics: accessibility permission status, live log of captured notifications
  with which rule matched, "Create rule for this", "Send test notification", "Copy AX dump".
- Preferences: appearance (System/Light/Dark), launch at login (`SMAppService.mainApp`), pause all.
- Menu bar item: pause/resume, open Rules, Diagnostics, Preferences, Quit. `LSUIElement` (no Dock icon).

## Layout and ownership

Three agents work in parallel. **Only edit files in your own area.** `Package.swift`
and this file belong to the coordinator (exception: the Core agent may adjust the
test target if XCTest/Testing is unavailable with Command Line Tools).

| Area | Path | Owner |
|---|---|---|
| Core | `Sources/TrillCore/**`, `Tests/TrillCoreTests/**` | Core agent |
| Services | `Sources/Trill/Services/**` | Services agent |
| UI + packaging | `Sources/Trill/App/**`, `Sources/Trill/UI/**`, `Scripts/**`, `Resources/**`, `README.md` | UI agent |

Other agents' files may not exist yet while you work. Code against the contract
below exactly. Near the end, run `swift build`; if it fails only because another
area isn't finished, wait a minute and retry (up to ~10 minutes), and fix only errors
in your own files. If the contract itself seems wrong, do NOT change it — work
within it and mention the issue in your final report.

## Contract: TrillCore (public API, `import TrillCore`)

All types are `public`, with public memberwise inits (defaults where shown),
`Codable, Hashable, Sendable`.

```swift
public struct CapturedNotification: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID            // default UUID()
    public var date: Date          // default Date()
    public var appName: String     // "" if unknown
    public var bundleID: String?   // nil if unknown
    public var title: String
    public var subtitle: String    // default ""
    public var body: String
    public var searchText: String { get }   // title, subtitle, body joined by "\n" (non-empty parts)
}

public enum RuleAction: Codable, Hashable, Sendable {
    case sound(soundID: String)
    case speak(voiceID: String?, template: String)  // default template "{title}. {body}"
    case shortcut(name: String)
    case silent                                      // match and do nothing
}

public struct Rule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID            // default UUID()
    public var name: String
    public var isEnabled: Bool     // default true
    public var appFilter: String?  // bundle ID or app display name, case-insensitive; nil = any app
    public var query: String       // query language; "" = match everything
    public var action: RuleAction
    public var volume: Double      // 0.0...2.0, default 1.0
}

public struct Sound: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case system, builtIn, user }
    public var id: String          // stable: "system:Glass", "builtin:chime-up", "user:<uuid>"
    public var name: String
    public var kind: Kind
    public var url: URL
}

public enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark }

public struct AppSettings: Codable, Hashable, Sendable {
    public var appearance: Appearance   // default .system
    public var isPaused: Bool           // default false
    public init()
}

public enum QueryParseError: Error, LocalizedError, Equatable { ... } // human-readable errorDescription

public struct QueryExpression: Sendable {
    public init(parsing source: String) throws   // throws QueryParseError
    public func matches(_ notification: CapturedNotification) -> Bool
    public static func validate(_ source: String) -> String?   // nil if valid, else error message
}

public enum RuleEngine {
    /// First enabled rule (in array order) whose appFilter and query match. Invalid queries never match.
    public static func firstMatch(for n: CapturedNotification, in rules: [Rule]) -> Rule?
    public static func matches(_ rule: Rule, _ n: CapturedNotification) -> Bool
    /// "{app}", "{title}", "{subtitle}", "{body}" substitution.
    public static func render(template: String, with n: CapturedNotification) -> String
}

public final class Store {
    public static var defaultDirectory: URL { get }   // ~/Library/Application Support/Trill
    public init(directory: URL = Store.defaultDirectory)
    public let directory: URL
    public var soundsDirectory: URL { get }           // <directory>/Sounds, created on demand
    public func loadRules() -> [Rule]                 // [] if missing/corrupt
    public func saveRules(_ rules: [Rule])            // atomic JSON write
    public func loadSettings() -> AppSettings
    public func saveSettings(_ settings: AppSettings)
    public func loadUserSounds() -> [Sound]           // metadata index of imported/generated sounds
    public func saveUserSounds(_ sounds: [Sound])
}
```

Query semantics: precedence `NOT` > `AND` (explicit or implicit) > `OR`. A term is a
case-insensitive substring match; `*` matches any run of characters (including none)
inside the term, and the term may match anywhere in the text. Unprefixed terms match
against `searchText`; `app:` matches `appName` or `bundleID`. `and`/`or`/`not` in
lowercase are ordinary words. `#`, `@`, `-`, `_`, `.` are ordinary term characters.

## Contract: Services (`Sources/Trill/Services`)

The UI talks to exactly one object:

```swift
struct LogEntry: Identifiable, Hashable {
    let id: UUID
    let notification: CapturedNotification
    let matchedRuleID: UUID?
    let matchedRuleName: String?
}
struct AppInfo: Identifiable, Hashable { var id: String { bundleID }; let name: String; let bundleID: String }
struct VoiceInfo: Identifiable, Hashable { let id: String; let name: String; let language: String }

@MainActor final class AppState: ObservableObject {
    static let shared: AppState
    @Published var rules: [Rule]              // persisted on change
    @Published var settings: AppSettings      // persisted on change
    @Published private(set) var sounds: [Sound]          // system + builtIn + user, sorted by kind then name
    @Published private(set) var log: [LogEntry]          // newest first, max 200
    @Published private(set) var isAccessibilityTrusted: Bool   // re-polled every ~2s until true
    @Published private(set) var watcherStatus: String    // short human-readable, for Diagnostics

    func start()                               // call once at launch: load, generate built-in sounds, start watcher
    func requestAccessibilityPermission()      // AXIsProcessTrustedWithOptions prompt + open System Settings pane
    func sound(withID id: String) -> Sound?
    func preview(sound: Sound, volume: Double)
    func preview(action: RuleAction, volume: Double, sample: CapturedNotification?)  // nil sample = canned one
    func stopPreview()
    func importSounds(from urls: [URL]) throws -> [Sound]      // copies into Store.soundsDirectory
    func deleteSound(_ sound: Sound)                           // user sounds only
    func generateSpokenSound(text: String, voiceID: String?, name: String) async throws -> Sound
    var voices: [VoiceInfo] { get }
    func installedApps() -> [AppInfo]          // /Applications, /System/Applications, ~/Applications + running apps, deduped, sorted
    func shortcutNames() async -> [String]     // `shortcuts list`
    func handle(_ notification: CapturedNotification)   // match + act + log; no-op action when paused (still logs)
    func sendTestNotification(_ notification: CapturedNotification)   // feeds handle() directly, bypassing AX
    func accessibilityDump() -> String         // text dump of the notification UI's AX tree, for bug reports
    func clearLog()
}
```

Internal pieces (Services agent's own design): `NotificationWatcher`, `SoundPlayer`
(AVAudioEngine, gain up to 2.0, overlapping playback OK), `Speaker`
(AVSpeechSynthesizer), `ShortcutRunner`, `BuiltInSounds` (procedural synthesis to
`.wav`/`.caf` in `<Store.directory>/BuiltIn`, ~24 distinct sounds: chimes, bells,
blips, plucks, boings, knocks, alarms), `SoundLibrary`.

### NotificationWatcher notes

- Find the process with bundle ID `com.apple.notificationcenterui`; create an
  `AXObserver` on it; subscribe to window-created / created / layout-changed style
  notifications on the app element; also re-scan on a low-frequency timer (~1s) as a
  fallback only while trusted. Re-attach if the process restarts.
- Walk the AX tree for banner/alert elements (historically `AXGroup`/`AXButton` with
  subrole `AXNotificationCenterBanner` / `AXNotificationCenterAlert`); collect
  `AXStaticText` values in order (title, subtitle?, body); app name from
  `AXDescription` / `AXStackingIdentifier` / `AXIdentifier` where present. The tree shape
  differs across macOS versions and this machine runs macOS 27, so be defensive:
  log unknown shapes into `watcherStatus`, and make `accessibilityDump()` thorough
  (role, subrole, identifier, description, value, title for every node, depth ≤ 12).
- De-duplicate: the same banner must fire once (key on AX element identity plus text,
  with a short TTL), and banners already on screen at launch must not fire.
- Never crash on AX errors; all AX calls off the main thread or with a messaging timeout.
- Also support `Trill --dump-ax` (print the dump and exit) — expose a static function
  the App entry point can call.

## UI (`Sources/Trill/App`, `Sources/Trill/UI`) — SwiftUI

- `@main` App with `MenuBarExtra` (SF Symbol icon; different symbol when paused) and
  `Window` scenes: **Rules** (main), **Diagnostics**, plus `Settings`. Handle
  `--dump-ax` before starting the app. Activate the app (`NSApp.activate`) when opening
  windows since it is `LSUIElement`.
- Rules window: `NavigationSplitView`. Sidebar = ordered rule list (enable toggle, name,
  action summary, drag to reorder, add/duplicate/delete, arrow-key navigation, ⌘N).
  Detail = editor: name, app picker (Any app + installed apps with icons, searchable),
  query field with live validation message and a syntax help popover, action picker
  (Sound / Speak / Shortcut / Silent) with the matching sub-editor, volume slider
  0–200% with a marker at 100%, Preview button, and a "Test against text" field that
  shows whether the query matches.
- Sound picker: grouped by System / Built-in / Yours, search, click to preview,
  Import… (`.audio` file types, also drag & drop), delete for user sounds,
  "Text to sound…" sheet (text, voice, name → `generateSpokenSound`).
- Diagnostics window: permission status with a Grant button, watcher status, log table
  (time, app, title, body, matched rule), "Create rule for this" on a row (prefills app
  filter + a quoted title query and opens it in Rules), "Send test notification" form,
  "Copy AX dump", Clear.
- First launch / untrusted: an onboarding card in the Rules window explaining why
  Accessibility is needed (read locally, nothing leaves the Mac) with the Grant button.
- Preferences: appearance (apply via `NSApp.appearance`), launch at login toggle
  (`SMAppService.mainApp`, show the error if not running from an .app bundle), pause.
- Empty state seeds nothing automatically but offers "Add example rules".

## Packaging

- `Resources/Info.plist`: `CFBundleIdentifier` `com.karimbacchus.trill`, `LSUIElement` true,
  `LSMinimumSystemVersion` 13.0, `NSAccessibilityUsageDescription`.
- `Scripts/build-app.sh`: `swift build -c release`, assemble `build/Trill.app`
  (`Contents/MacOS/Trill`, `Contents/Info.plist`), generate an `.icns` if cheap (a
  script-drawn icon is fine, optional), `codesign --force --sign -`. `Scripts/run.sh`
  builds and opens it.
- README: what it is, build/run, granting Accessibility (and that ad-hoc signing means
  macOS may ask again after a rebuild), query syntax, troubleshooting via Diagnostics.

## Done means

`Scripts/build-app.sh` builds with no errors, `swift run trill-selftest` passes for the query language and rule engine, `Scripts/build-app.sh`
produces a launchable `build/Trill.app`.
