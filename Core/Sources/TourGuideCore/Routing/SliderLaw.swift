import Foundation

/// Slider position ↔ corridor slack (PRD §5 step 5, §8.1).
///
/// The left end (position 0) is the most-sights walk, `maxSlack`; the right end (position 1) is
/// the direct route, slack 0. The law is square, so the low-slack end — where the owner's
/// Nagamachi walk lives (slack 0.1, +0.2 min) — gets most of the slider's travel:
/// `slack = maxSlack · (1 − p)²`.
public enum SliderLaw {
    public static func slack(position p: Double, maxSlack: Double) -> Double {
        let q = 1 - min(1, max(0, p))
        return ((maxSlack * q * q) * 1000).rounded() / 1000
    }

    public static func position(slack: Double, maxSlack: Double) -> Double {
        guard maxSlack > 0 else { return 1 }
        return 1 - (min(1, max(0, slack / maxSlack))).squareRoot()
    }
}
