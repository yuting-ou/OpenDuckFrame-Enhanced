import Foundation

/// Remembers the last viewing setup the user picked in the player, so the
/// next video can start with the same brightness boost and interpolation
/// cadence instead of asking again.
///
/// Only values the user has actually chosen are stored. A missing key means
/// "never touched", which lets the player keep its default behavior instead
/// of forcing an enhancement on first launch.
enum ViewingPreferences {
    private static let brightnessKey = "odf.viewing.brightnessBoost"
    private static let interpolationKey = "odf.viewing.interpolationMultiplier"

    /// Last brightness-boost choice. Nil until the user toggles the chip.
    static var brightnessBoost: Bool? {
        get { UserDefaults.standard.object(forKey: brightnessKey) as? Bool }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: brightnessKey)
            } else {
                UserDefaults.standard.removeObject(forKey: brightnessKey)
            }
        }
    }

    /// Last interpolation cadence: 0 off, 2 for X2, 3 for X3. Nil until the
    /// user applies an interpolation choice.
    static var interpolationMultiplier: Int? {
        get { UserDefaults.standard.object(forKey: interpolationKey) as? Int }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: interpolationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: interpolationKey)
            }
        }
    }
}
