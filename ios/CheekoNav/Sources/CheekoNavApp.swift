import SwiftUI

@main
struct CheekoNavApp: App {
    @StateObject private var session = RideSession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session, ble: session.ble, location: session.location)
                .preferredColorScheme(.dark)
        }
    }
}
