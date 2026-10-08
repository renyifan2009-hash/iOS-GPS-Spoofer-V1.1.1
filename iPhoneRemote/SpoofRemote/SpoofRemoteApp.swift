import SwiftUI

/// SpoofRemote: the iPhone app for iOS GPS Spoofer. Either the Mac holds the
/// simulated location (via Apple's developer location service) and this app
/// tells it where to go, or, in the iPhone-only mode, this app sets the
/// location itself.
@main
struct SpoofRemoteApp: App {
    @State private var connection = ConnectionManager()
    @State private var locations = LocationController()
    @State private var phone = OnDeviceController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connection)
                .environment(locations)
                .environment(phone)
                .tint(Brand.indigo)
        }
    }
}
