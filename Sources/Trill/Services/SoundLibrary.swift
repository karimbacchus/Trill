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

    func allSounds(userSounds: [Sound]) -> [Sound] {
        func rank(_ k: Sound.Kind) -> Int {
            switch k { case .system: return 0; case .builtIn: return 1; case .user: return 2 }
        }
        let user = userSounds.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        return (systemSounds() + builtInSounds() + user).sorted {
            let (a, b) = (rank($0.kind), rank($1.kind))
            if a != b { return a < b }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
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
