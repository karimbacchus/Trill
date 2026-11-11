import Foundation
import AVFoundation
import TrillCore

/// AVAudioEngine-based player. Gain is applied to the PCM samples (with a soft limiter),
/// so volumes up to 2.0 are a true boost. Overlapping playback is supported.
final class SoundPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Trill.SoundPlayer")
    private let engine = AVAudioEngine()
    private struct Playing {
        let node: AVAudioPlayerNode
        let buffer: AVAudioPCMBuffer
        let replays: Int
    }
    private static let idleTimeout: TimeInterval = 60
    private var active: [UUID: Playing] = [:]
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var cacheOrder: [String] = []
    private var idleWork: DispatchWorkItem?
    private var configObserver: NSObjectProtocol?

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.resetAfterConfigChange() }
        }
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Starts the audio engine ahead of a probable sound (called when a banner is first seen, ~0.25 s before the
    /// rules run), so the first samples are not clipped by engine and Bluetooth start-up. It stops again after
    /// the usual idle period if nothing plays.
    func prewarm() {
        queue.async { [self] in
            guard active.isEmpty else { return }
            if !engine.isRunning {
                _ = engine.mainMixerNode   // an engine with nothing connected to the output cannot be prepared
                engine.prepare()
                do { try engine.start() } catch { return }   // the real play() retries
            }
            scheduleIdleStop()
        }
    }

    /// Play a file at `volume` (0.0...2.0).
    func play(url: URL, volume: Double) {
        queue.async { [self] in
            guard let base = loadBuffer(url) else { return }
            let gain = Float(max(0, min(2, volume)))
            guard gain > 0, let buffer = Self.applyGain(base, gain) else { return }
            startPlaying(buffer, replays: 0, attempt: 0)
        }
    }

    private static let startRetries = 2
    private static let retryDelay: TimeInterval = 0.3
    private static let maxReplays = 2

    /// Must run on `queue`. If the engine will not start, tries again a couple of times instead of dropping the sound.
    private func startPlaying(_ buffer: AVAudioPCMBuffer, replays: Int, attempt: Int) {
        idleWork?.cancel(); idleWork = nil
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                engine.detach(node)
                if attempt < Self.startRetries {
                    queue.asyncAfter(deadline: .now() + Self.retryDelay) { [self] in
                        startPlaying(buffer, replays: replays, attempt: attempt + 1)
                    }
                } else {
                    NSLog("Trill: audio engine failed to start: \(error)")
                    scheduleIdleStop()
                }
                return
            }
        }
        let id = UUID()
        active[id] = Playing(node: node, buffer: buffer, replays: replays)
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async { self?.finish(id) }
        }
        node.play()
    }

    /// Stop everything that is playing (used for previews).
    func stopAll() {
        queue.async { [self] in
            for (id, _) in active { finish(id) }
        }
    }

    private func finish(_ id: UUID) {
        guard let playing = active.removeValue(forKey: id) else { return }
        playing.node.stop()
        engine.detach(playing.node)
        if active.isEmpty { scheduleIdleStop() }
    }

    private func scheduleIdleStop() {
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.active.isEmpty else { return }
            self.engine.stop()
        }
        idleWork = w
        queue.asyncAfter(deadline: .now() + Self.idleTimeout, execute: w)
    }

    /// The output device changed (e.g. Bluetooth connected): the engine stopped. Restart it and replay the sounds
    /// that had not finished.
    private func resetAfterConfigChange() {
        let unfinished = active.values.filter { $0.replays < Self.maxReplays }
        let old = active
        active.removeAll()           // first, so completion callbacks fired by stop() find nothing to finish
        for (_, p) in old { p.node.stop(); engine.detach(p.node) }
        engine.stop()
        for p in unfinished { startPlaying(p.buffer, replays: p.replays + 1, attempt: 0) }
    }

    private func loadBuffer(_ url: URL) -> AVAudioPCMBuffer? {
        let key = url.path
        if let b = cache[key] { return b }
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let maxFrames = AVAudioFramePosition(format.sampleRate * 60)
            let frames = AVAudioFrameCount(min(file.length, maxFrames))
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
            try file.read(into: buf, frameCount: frames)
            if frames < 500_000 {
                cache[key] = buf; cacheOrder.append(key)
                if cacheOrder.count > 40 { cache[cacheOrder.removeFirst()] = nil }
            }
            return buf
        } catch {
            NSLog("Trill: cannot read audio \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Scales the sound by `gain`: up to 100% plainly; above that first by the headroom the sound has, then a
    /// soft clip for the remainder (see `Gain`).
    private static func applyGain(_ src: AVAudioPCMBuffer, _ gain: Float) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength),
              let s = src.floatChannelData, let d = dst.floatChannelData else { return nil }
        dst.frameLength = src.frameLength
        let n = Int(src.frameLength)
        let channels = Int(src.format.channelCount)
        var peak: Float = 0
        if gain > 1 {
            for ch in 0..<channels { for i in 0..<n { peak = max(peak, abs(s[ch][i])) } }
        }
        for ch in 0..<channels {
            let sp = s[ch], dp = d[ch]
            for i in 0..<n { dp[i] = Gain.apply(sp[i], gain: gain, peak: peak) }
        }
        return dst
    }
}
