import Foundation

// Visibility grouping for items in the switcher.
// Order is significant for sorting: normal (0) -> atEnd (1).
public enum VisibilityTier: Int {
    case normal = 0
    case atEnd = 1
}

// Preference for how to treat hidden/minimized/no-window items.
// normal: treat like main tier; atEnd: include but place after main tier; exclude: omit from lists.
public enum PlacementPreference: Int {
    case normal = 0
    case atEnd = 1
    case exclude = 2
}

public enum PreferenceUtils {
    // Reads HiddenApps placement preference with backward-compatibility to legacy IncludeHiddenApps (Bool).
    public static func hiddenPlacement() -> PlacementPreference {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: "HiddenAppsPlacement") as? Int, let pref = PlacementPreference(rawValue: raw) {
            return pref
        }
        // Fallback to legacy boolean (default true -> normal)
        let legacy = defaults.object(forKey: "IncludeHiddenApps") as? Bool ?? true
        return legacy ? .normal : .exclude
    }

    // Reads MinimizedApps placement preference with backward-compatibility to legacy IncludeMinimizedApps (Bool).
    public static func minimizedPlacement() -> PlacementPreference {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: "MinimizedAppsPlacement") as? Int, let pref = PlacementPreference(rawValue: raw) {
            return pref
        }
        // Fallback to legacy boolean (default true -> normal)
        let legacy = defaults.object(forKey: "IncludeMinimizedApps") as? Bool ?? true
        return legacy ? .normal : .exclude
    }

    // Reads NoWindowApps placement preference (default: normal).
    public static func noWindowPlacement() -> PlacementPreference {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: "NoWindowAppsPlacement") as? Int, let pref = PlacementPreference(rawValue: raw) {
            return pref
        }
        return .normal
    }
}
