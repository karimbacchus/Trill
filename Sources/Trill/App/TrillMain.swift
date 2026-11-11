import SwiftUI
import AppKit

/// Process entry point. Handles `--dump-ax` before any UI starts.
@main
enum TrillEntry {
    static func main() {
        if CommandLine.arguments.contains("--dump-ax") {
            print(NotificationWatcher.dumpAccessibilityTree())
            exit(0)
        }
        TrillApp.main()
    }
}
