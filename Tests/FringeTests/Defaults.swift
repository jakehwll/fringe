import Foundation

/// A throwaway `UserDefaults` per test, so nothing here can see or disturb the
/// real preferences — the bug class these tests exist for is persisted state
/// nobody can see.
func scratchDefaults(
    _ seed: [String: Any] = [:],
    function: String = #function
) -> UserDefaults {
    let suite = "FringeTests.\(function).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    for (key, value) in seed {
        defaults.set(value, forKey: key)
    }
    return defaults
}
