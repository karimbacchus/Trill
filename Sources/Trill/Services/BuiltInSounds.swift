import Foundation

/// Procedurally synthesized built-in sounds, written as 16-bit mono WAV files on first launch.
enum BuiltInSounds {
    struct Entry {
        let slug: String
        let name: String
        let render: () -> [Float]
        var id: String { "builtin:\(slug)" }
        var fileName: String { "\(slug).wav" }
    }

    static let sampleRate = 44100.0

    static var catalog: [Entry] { entries }

    /// Writes any missing sound files into `directory`.
    static func generateIfNeeded(in directory: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for e in entries {
            let url = directory.appendingPathComponent(e.fileName)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 44 { continue }
            let samples = Synth.finalize(e.render())
            do { try Synth.wavData(samples).write(to: url, options: .atomic) } catch {
                NSLog("Trill: could not write built-in sound \(e.slug): \(error)")
            }
        }
    }

    private static let entries: [Entry] = {
        func hz(_ m: Double) -> Double { 440 * pow(2, (m - 69) / 12) }
        typealias S = Synth

        return [
            Entry(slug: "chime-up", name: "Rising Chime") {
                var o = S.silence(1.4)
                for (i, m) in [72.0, 76, 79, 84].enumerated() { S.add(&o, S.bell(hz(m), 0.9, decay: 4), at: Double(i) * 0.11) }
                return o
            },
            Entry(slug: "chime-down", name: "Falling Chime") {
                var o = S.silence(1.4)
                for (i, m) in [84.0, 79, 76, 72].enumerated() { S.add(&o, S.bell(hz(m), 0.9, decay: 4), at: Double(i) * 0.11) }
                return o
            },
            Entry(slug: "bell", name: "Little Bell") { S.bell(hz(88), 1.4, decay: 3.2) },
            Entry(slug: "temple-bell", name: "Temple Bell") { S.bell(hz(55), 2.8, decay: 1.5) },
            Entry(slug: "blip", name: "Blip") { S.osc(0.1, freq: { _ in hz(84) }, decay: 24) },
            Entry(slug: "double-blip", name: "Double Blip") {
                var o = S.silence(0.32)
                S.add(&o, S.osc(0.09, freq: { _ in hz(79) }, decay: 26), at: 0)
                S.add(&o, S.osc(0.12, freq: { _ in hz(86) }, decay: 22), at: 0.1)
                return o
            },
            Entry(slug: "pluck", name: "Pluck") { S.pluck(hz(67), 0.9) },
            Entry(slug: "harp-run", name: "Harp Run") {
                var o = S.silence(1.4)
                for (i, m) in [60.0, 64, 67, 72, 76, 79].enumerated() { S.add(&o, S.pluck(hz(m), 0.9, damping: 0.997), at: Double(i) * 0.07) }
                return o
            },
            Entry(slug: "boing", name: "Boing") {
                S.osc(0.8, freq: { t in 220 * (1 + 1.6 * exp(-4 * t) * cos(2 * .pi * 7 * t)) },
                      partials: [(1, 1), (2, 0.35)], decay: 3.5)
            },
            Entry(slug: "spring", name: "Spring") {
                S.osc(0.55, freq: { t in 420 + 320 * sin(2 * .pi * 18 * t) * exp(-5 * t) },
                      partials: [(1, 1), (3, 0.2)], decay: 5)
            },
            Entry(slug: "knock", name: "Knock") { S.knock() },
            Entry(slug: "double-knock", name: "Double Knock") {
                var o = S.silence(0.4)
                S.add(&o, S.knock(), at: 0)
                S.add(&o, S.knock(), at: 0.15, gain: 0.85)
                return o
            },
            Entry(slug: "alarm", name: "Alarm") {
                var o = S.silence(1.0)
                for i in 0..<4 {
                    let f = i % 2 == 0 ? 880.0 : 660.0
                    S.add(&o, S.osc(0.16, freq: { _ in f }, partials: [(1, 1), (3, 0.33), (5, 0.2)], attack: 0.006, decay: 5), at: Double(i) * 0.2)
                }
                return o
            },
            Entry(slug: "siren", name: "Soft Siren") {
                S.osc(1.0, freq: { t in 700 + 260 * sin(2 * .pi * 2.5 * t) }, partials: [(1, 1), (2, 0.2)],
                      attack: 0.08, decay: 0, tail: 0.25)
            },
            Entry(slug: "marimba", name: "Marimba") {
                var o = S.silence(0.8)
                S.add(&o, S.osc(0.6, freq: { _ in hz(69) }, partials: [(1, 1), (4, 0.35), (10, 0.08)], decay: 8), at: 0)
                S.add(&o, S.osc(0.6, freq: { _ in hz(76) }, partials: [(1, 1), (4, 0.35), (10, 0.08)], decay: 8), at: 0.12)
                return o
            },
            Entry(slug: "glass", name: "Glass Tap") { S.fm(1800, ratio: 1.41, index: 3, dur: 0.6, decay: 9, indexDecay: 14) },
            Entry(slug: "droplet", name: "Droplet") {
                S.osc(0.22, freq: { t in 500 + 1300 * (1 - exp(-t * 35)) }, decay: 20)
            },
            Entry(slug: "coin", name: "Coin") {
                var o = S.silence(0.7)
                let sq: [(Double, Double)] = [(1, 1), (3, 0.3), (5, 0.18), (7, 0.1)]
                S.add(&o, S.osc(0.08, freq: { _ in hz(83) }, partials: sq, decay: 6), at: 0)
                S.add(&o, S.osc(0.55, freq: { _ in hz(88) }, partials: sq, decay: 6), at: 0.07)
                return o
            },
            Entry(slug: "ding", name: "Ding") { S.fm(hz(81), ratio: 2, index: 1.6, dur: 1.1, decay: 4.5, indexDecay: 6) },
            Entry(slug: "tri-tone", name: "Tri-tone") {
                var o = S.silence(0.9)
                for (i, m) in [79.0, 86, 83].enumerated() { S.add(&o, S.fm(hz(m), ratio: 2, index: 1.2, dur: 0.5, decay: 6, indexDecay: 9), at: Double(i) * 0.13) }
                return o
            },
            Entry(slug: "sparkle", name: "Sparkle") {
                var o = S.silence(0.9)
                var rng = S.LCG(seed: 7)
                for i in 0..<9 {
                    let m = 96 + Double(Int(rng.next() * 12))
                    let t = Double(i) * 0.045 + rng.next() * 0.02
                    S.add(&o, S.osc(0.3, freq: { _ in hz(m) }, decay: 14), at: t, gain: Float(0.5 + rng.next() * 0.5))
                }
                return o
            },
            Entry(slug: "pop", name: "Pop") {
                S.osc(0.08, freq: { t in 200 + 900 * exp(-t * 60) }, decay: 55)
            },
            Entry(slug: "zap", name: "Zap") {
                S.osc(0.22, freq: { t in 2000 * pow(0.05, t / 0.2) }, partials: [(1, 1), (2, 0.5), (3, 0.33), (4, 0.25)], decay: 8)
            },
            Entry(slug: "fanfare", name: "Little Fanfare") {
                var o = S.silence(1.3)
                let brass: [(Double, Double)] = [(1, 1), (2, 0.5), (3, 0.35), (4, 0.2)]
                let notes: [(Double, Double, Double)] = [(72, 0, 0.14), (72, 0.15, 0.14), (76, 0.3, 0.14), (79, 0.45, 0.8)]
                for (m, t, d) in notes {
                    S.add(&o, S.osc(d, freq: { _ in hz(m) }, partials: brass, attack: 0.02, decay: d > 0.5 ? 2.5 : 3, tail: 0.04), at: t)
                }
                return o
            },
        ]
    }()
}

/// Small additive/FM/physical-model synthesis toolkit.
enum Synth {
    static let sr = BuiltInSounds.sampleRate

    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        /// Uniform in [0, 1).
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func silence(_ dur: Double) -> [Float] { [Float](repeating: 0, count: Int(dur * sr)) }

    static func add(_ dst: inout [Float], _ src: [Float], at t: Double, gain: Float = 1) {
        let start = Int(t * sr)
        if dst.count < start + src.count { dst.append(contentsOf: [Float](repeating: 0, count: start + src.count - dst.count)) }
        for i in 0..<src.count { dst[start + i] += src[i] * gain }
    }

    /// General oscillator bank with a time-varying fundamental, attack ramp, exponential decay
    /// and a short release tail.
    static func osc(_ dur: Double, freq: (Double) -> Double, amp: (Double) -> Double = { _ in 1 },
                    partials: [(Double, Double)] = [(1, 1)], attack: Double = 0.003,
                    decay: Double = 6, tail: Double = 0.01) -> [Float] {
        let n = Int(dur * sr)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        let norm = partials.reduce(0) { $0 + $1.1 }
        for i in 0..<n {
            let t = Double(i) / sr
            phase += 2 * .pi * freq(t) / sr
            var s = 0.0
            for (m, a) in partials { s += a * sin(phase * m) }
            var env = min(1, t / max(attack, 1e-4)) * exp(-decay * t) * amp(t)
            let left = dur - t
            if left < tail { env *= left / tail }
            out[i] = Float(s / norm * env)
        }
        return out
    }

    static func fm(_ carrier: Double, ratio: Double, index: Double, dur: Double, decay: Double, indexDecay: Double) -> [Float] {
        let n = Int(dur * sr)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            let idx = index * exp(-indexDecay * t)
            let s = sin(2 * .pi * carrier * t + idx * sin(2 * .pi * carrier * ratio * t))
            out[i] = Float(s * min(1, t / 0.003) * exp(-decay * t))
        }
        return out
    }

    static func bell(_ f: Double, _ dur: Double, decay: Double) -> [Float] {
        let parts: [(Double, Double, Double)] = [   // ratio, amp, decay multiplier
            (0.5, 0.35, 0.8), (1.0, 1.0, 1.0), (1.19, 0.5, 1.2), (1.56, 0.3, 1.5),
            (2.0, 0.55, 1.8), (2.74, 0.35, 2.4), (3.76, 0.2, 3.2), (5.4, 0.1, 4.5),
        ]
        let n = Int(dur * sr)
        var out = [Float](repeating: 0, count: n)
        for (r, a, dm) in parts {
            let w = 2 * .pi * f * r / sr
            let d = decay * dm
            for i in 0..<n {
                let t = Double(i) / sr
                out[i] += Float(a * sin(w * Double(i)) * exp(-d * t))
            }
        }
        let tail = 0.03
        for i in 0..<n {
            let t = Double(i) / sr
            let env = min(1, t / 0.002) * min(1, (dur - t) / tail)
            out[i] *= Float(env)
        }
        return out
    }

    /// Karplus-Strong plucked string.
    static func pluck(_ f: Double, _ dur: Double, damping: Double = 0.996) -> [Float] {
        let n = Int(dur * sr)
        let period = max(2, Int(sr / f))
        var rng = LCG(seed: UInt64(f * 100))
        var line = (0..<period).map { _ in Float(rng.next() * 2 - 1) }
        // Soften the initial noise burst.
        for i in 1..<period { line[i] = 0.5 * line[i] + 0.5 * line[i - 1] }
        var out = [Float](repeating: 0, count: n)
        var idx = 0
        let d = Float(damping)
        for i in 0..<n {
            let next = (idx + 1) % period
            let v = line[idx]
            out[i] = v
            line[idx] = d * 0.5 * (v + line[next])
            idx = next
        }
        let tail = min(n, Int(0.05 * sr))
        for i in 0..<tail { out[n - 1 - i] *= Float(i) / Float(tail) }
        return out
    }

    static func knock() -> [Float] {
        var o = osc(0.18, freq: { t in 70 + 110 * exp(-t * 40) }, partials: [(1, 1), (2.3, 0.25)], attack: 0.001, decay: 30)
        var rng = LCG(seed: 99)
        var lp: Float = 0
        var click = [Float](repeating: 0, count: Int(0.02 * sr))
        for i in 0..<click.count {
            let w = Float(rng.next() * 2 - 1)
            lp += 0.25 * (w - lp)
            click[i] = lp * Float(exp(-Double(i) / sr * 160)) * 0.7
        }
        add(&o, click, at: 0)
        return o
    }

    /// Normalizes to a comfortable peak and applies short fades to avoid clicks.
    static func finalize(_ s: [Float]) -> [Float] {
        var out = s
        let peak = out.reduce(0) { max($0, abs($1)) }
        let g: Float = peak > 0 ? 0.8 / peak : 1
        let fin = Int(0.002 * sr), fout = Int(0.02 * sr)
        for i in 0..<out.count {
            var v = out[i] * g
            if i < fin { v *= Float(i) / Float(fin) }
            let left = out.count - 1 - i
            if left < fout { v *= Float(left) / Float(fout) }
            out[i] = v
        }
        return out
    }

    static func wavData(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let dataSize = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sr)); u32(UInt32(sr) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            u16(UInt16(bitPattern: v))
        }
        return d
    }
}
