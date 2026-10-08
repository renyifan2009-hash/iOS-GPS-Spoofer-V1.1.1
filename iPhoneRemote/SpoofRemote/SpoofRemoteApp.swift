import SwiftUI

/// SpoofRemote: the iPhone remote for iOS GPS Spoofer. The Mac holds the
/// simulated location (via Apple's developer location service); this app
/// picks places and tells the Mac to start, move or stop.
@main
struct SpoofRemoteApp: App {
    @State private var connection = ConnectionManager()
    @State private var locations = LocationController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(connection)
                .environment(locations)
                .tint(Brand.indigo)
        }
    }
}
