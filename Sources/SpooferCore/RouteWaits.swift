import PhoneOnlyCore

/// The Mac's way to the shared wait rules (`PhoneOnlyCore.WaitDuration`), for code that can't import
/// PhoneOnlyCore beside SpooferCore (both have a `SavedRoute`).
public enum RouteWaits {
    /// A stop's wait made safe to use: 0 if it isn't a number, at most a day.
    public static func clamp(_ seconds: Double) -> Double { WaitDuration.clamp(seconds) }
}
