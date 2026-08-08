import Foundation

/// Speed-of-sound conversions shared wherever a timing delta (IR peak, burst
/// arrival) needs a distance readout. Distinct from `RoomAcoustics` (IR-derived
/// decay parameters like C50/D50/Ts) — this is just the ms↔m arithmetic, factored
/// out once it had three separate call sites.
public enum Acoustics {
    /// Speed of sound in air at ~20°C, m/s.
    public static let speedOfSoundMPerSec: Double = 343.0

    /// One-way path-length difference equivalent to a timing delta. Sign is
    /// preserved (does not take `abs`) — callers wanting a magnitude apply
    /// `abs()` themselves, same as the call sites this replaces already did.
    public static func distanceMeters(forDeltaMs deltaMs: Double) -> Double {
        deltaMs / 1000.0 * speedOfSoundMPerSec
    }
}
