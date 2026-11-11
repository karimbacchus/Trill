import Foundation

/// Runs and lists Shortcuts through /usr/bin/shortcuts, always off the main thread.
enum ShortcutRunner {
    private static let queue = DispatchQueue(label: "Trill.ShortcutRunner", qos: .utility, attributes: .concurrent)
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Fire and forget. `input` is written to the shortcut's stdin.
    static func run(name: String, input: String) {
        _ = ignoreSIGPIPE
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", name]
            let stdin = Pipe()
            p.standardInput = stdin
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                NSLog("Trill: cannot run shortcuts: \(error)")
                return
            }
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            queue.asyncAfter(deadline: .now() + 120, execute: killer)
            p.waitUntilExit()
            killer.cancel()
            if p.terminationStatus != 0 {
                NSLog("Trill: shortcut \"\(name)\" exited with status \(p.terminationStatus)")
            }
        }
    }

    static func list() async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            queue.async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
                p.arguments = ["list"]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: []); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                queue.asyncAfter(deadline: .now() + 20, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                let names = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                cont.resume(returning: names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            }
        }
    }
}
