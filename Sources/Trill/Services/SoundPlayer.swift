import Foundation
import AVFoundation

/// AVAudioEngine-based player. Gain is applied to the PCM samples (with a soft limiter),
/// so volumes up to 2.0 are a true boost. Overlapping playback is supported.
final class SoundPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Trill.SoundPlayer")
    private let engine = AVAudioEngine()
    private var active: [UUID: AVAudioPlayerNode] = [:]
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

    /// Play a file at `volume` (0.0...2.0).
    func play(url: URL, volume: Double) {
        queue.async { [self] in
            guard let base = loadBuffer(url) else { return }
            let gain = Float(max(0, min(2, volume)))
            guard gain > 0, let buffer = Self.applyGain(base, gain) else { return }
            idleWork?.cancel(); idleWork = nil

            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            if !engine.isRunning {
                engine.prepare()
                do { try engine.start() } catch {
                    NSLog("Trill: audio engine failed to start: \(error)")
                    engine.detach(node)
                    return
                }
            }
            let id = UUID()
            active[id] = node
            node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async { self?.finish(id) }
            }
            node.play()
        }
    }

    /// Stop everything that is playing (used for previews).
    func stopAll() {
        queue.async { [self] in
            for (id, _) in active { finish(id) }
        }
    }

    private func finish(_ id: UUID) {
        guard let node = active.removeValue(forKey: id) else { return }
        node.stop()
        engine.detach(node)
        if active.isEmpty {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.active.isEmpty else { return }
                self.engine.stop()
            }
            idleWork = w
            queue.asyncAfter(deadline: .now() + 20, execute: w)
        }
    }

    private func resetAfterConfigChange() {
        for (_, node) in active { node.stop(); engine.detach(node) }
        active.removeAll()
        engine.stop()
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

    private static func applyGain(_ src: AVAudioPCMBuffer, _ gain: Float) -> AVAudioPCMBuffer? {
        guard let dst = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength),
              let s = src.floatChannelData, let d = dst.floatChannelData else { return nil }
        dst.frameLength = src.frameLength
        let n = Int(src.frameLength)
        let knee: Float = 0.9
        for ch in 0..<Int(src.format.channelCount) {
            let sp = s[ch], dp = d[ch]
            for i in 0..<n {
                let y = sp[i] * gain
                let a = abs(y)
                if a <= knee {
                    dp[i] = y
                } else {
                    let limited = knee + (1 - knee) * tanhf((a - knee) / (1 - knee))
                    dp[i] = y < 0 ? -limited : limited
                }
            }
        }
        return dst
    }
}
