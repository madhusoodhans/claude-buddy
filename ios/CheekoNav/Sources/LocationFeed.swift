// GPS at navigation accuracy, kept running with the phone locked during a ride.

import CoreLocation
import Foundation

final class LocationFeed: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var last: CLLocation?
    @Published private(set) var denied = false
    var onLocation: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .otherNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Ask for permission and get one fix, so search can suggest places nearby.
    func prepare() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        // Started from the foreground, this keeps GPS running when the phone locks
        // (UIBackgroundModes: location), with the blue location pill showing.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        denied = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        last = loc
        onLocation?(loc)
    }
}
