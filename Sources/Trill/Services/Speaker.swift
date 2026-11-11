import Foundation
import AVFoundation

enum ServicesError: LocalizedError {
    case unreadableAudio(String)
    case synthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAudio(let n): return "\u{201C}\(n)\u{201D} is not an audio file macOS can read."
        case .synthesisFailed(let m): return "Could not generate speech audio: \(m)"
        }
    }
}

/// AVSpeechSynthesizer wrapper. Speech volume is capped at 1.0 by the system.
@MainActor
final class Speaker {
    private let synth = AVSpeechSynthesizer()

    private func utterance(_ text: String, voiceID: String?, volume: Double) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        if let id = voiceID, let v = AVSpeechSynthesisVoice(identifier: id) { u.voice = v }
        u.volume = Float(max(0, min(1, volume)))
        return u
    }

    func speak(_ text: String, voiceID: String?, volume: Double) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, volume > 0 else { return }
        synth.speak(utterance(t, voiceID: voiceID, volume: volume))
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    /// Render speech to an audio file (CAF) at `url`.
    func render(text: String, voiceID: String?, to url: URL) async throws {
        let state = RenderState(url: url)
        let u = utterance(text, voiceID: voiceID, volume: 1)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            state.continuation = cont
            state.synth.write(u) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    state.finish(error: ServicesError.synthesisFailed("unsupported audio buffer"))
                    return
                }
                if pcm.frameLength == 0 {
                    state.finish(error: nil)
                    return
                }
                state.append(pcm)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                state.finish(error: ServicesError.synthesisFailed("timed out"))
            }
        }
    }
}

private final class RenderState: @unchecked Sendable {
    let synth = AVSpeechSynthesizer()
    let url: URL
    var continuation: CheckedContinuation<Void, Error>?
    private var file: AVAudioFile?
    private var done = false
    private var failure: Error?
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func append(_ pcm: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if done || failure != nil { return }
        do {
            if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
            try file?.write(from: pcm)
        } catch {
            failure = error
        }
    }

    func finish(error: Error?) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let hadFile = file != nil
        let err = failure ?? error
        file = nil   // closes and flushes the file
        let c = continuation
        continuation = nil
        lock.unlock()
        if let err {
            try? FileManager.default.removeItem(at: url)
            c?.resume(throwing: err)
        } else if !hadFile {
            c?.resume(throwing: ServicesError.synthesisFailed("the voice produced no audio"))
        } else {
            c?.resume()
        }
    }
}
