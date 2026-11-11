// "Where to?": Apple Maps place suggestions as you type, near where you are.

import MapKit

@MainActor
final class PlaceSearch: NSObject, ObservableObject {
    @Published var query = "" {
        didSet { query.isEmpty ? (results = []) : (completer.queryFragment = query) }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func focus(near location: CLLocation?) {
        guard let location else { return }
        completer.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 60_000,
                                              longitudinalMeters: 60_000)
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first
    }
}

extension PlaceSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let found = Array(completer.results.prefix(6))
        Task { @MainActor in self.results = self.query.isEmpty ? [] : found }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}
}
