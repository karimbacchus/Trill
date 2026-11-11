import Foundation

/// Volume above 100% without harsh clipping: scale by the headroom first, then soft-clip the rest.
public enum Gain {
    public static let ceiling: Float = 0.98
    public static let knee: Float = 0.6

    /// The linear scale to apply first: the full gain, limited so the sound's peak stays under `ceiling`.
    /// At or below 100% the gain is returned unchanged.
    public static func headroomScale(gain: Float, peak: Float) -> Float {
        guard gain > 1, peak > 0 else { return gain }
        return min(gain, max(1, ceiling / peak))
    }

    /// Identity up to `knee`, then a smooth tanh curve towards ±1.
    public static func softClip(_ x: Float, knee: Float = Gain.knee) -> Float {
        let a = abs(x)
        if a <= knee { return x }
        let limited = knee + (1 - knee) * tanhf((a - knee) / (1 - knee))
        return x < 0 ? -limited : limited
    }

    /// Applies a gain of `gain` to a sample of a sound whose peak is `peak`. 100% and below is plain scaling.
    public static func apply(_ sample: Float, gain: Float, peak: Float) -> Float {
        if gain <= 1 { return sample * gain }
        let first = headroomScale(gain: gain, peak: peak)
        let rest = gain / first
        return softClip(sample * first * rest)
    }
}
