import SwiftUI
import AppKit
import TrillCore

/// Process entry point. Handles `--dump-ax` before any UI starts.
@main
enum TrillEntry {
    /// Held for the life of the process (the kernel drops it on exit, including a crash).
    private static var lockFD: Int32 = -1

    /// Takes an exclusive lock on `<data dir>/.lock`, so two copies cannot both play every sound and overwrite
    /// each other's rules. The lock lives in the data directory, so `TRILL_DATA_DIR` runs stay independent.
    /// If another instance holds it, brings that one forward and returns false.
    private static func acquireSingleInstanceLock() -> Bool {
        let dir = Store.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }   // cannot lock: better to run than to refuse to start
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            return true
        }
        close(fd)
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != me }
        let other: NSRunningApplication?
        if let bundleID = Bundle.main.bundleIdentifier {
            other = running.first { $0.bundleIdentifier == bundleID }
        } else {
            other = running.first { $0.executableURL != nil && $0.executableURL == Bundle.main.executableURL }
        }
        other?.activate(options: [.activateIgnoringOtherApps])
        return false
    }

    static func main() {
        if CommandLine.arguments.contains("--dump-ax") {
            print(NotificationWatcher.dumpAccessibilityTree())
            exit(0)
        }
        guard acquireSingleInstanceLock() else { return }
        TrillApp.main()
    }
}
