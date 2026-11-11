// A ride. Either free ride (just your position) or navigating an Apple Maps
// route: upload the route and nearby streets to the Cheeko, then once a second
// send position, next turn, upcoming turns and trip; re-route if you leave it.

import CoreLocation
import Foundation
import MapKit

@MainActor
final class RideSession: ObservableObject {
    enum Mode { case idle, freeRide, navigating }

    struct Preview {
        let route: MKRoute
        let destination: MKMapItem
    }

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var sent = 0
    @Published private(set) var roadName = ""
    @Published private(set) var preview: Preview?
    @Published private(set) var planning = false
    @Published private(set) var problem: String?
    // While navigating, for the phone screen:
    @Published private(set) var nextTurn: NavTurn?
    @Published private(set) var nextTurnDistance = 0.0
    @Published private(set) var remaining = 0.0
    @Published private(set) var eta: Date?
    @Published private(set) var arrived = false
    @Published private(set) var rerouting = false
    @Published private(set) var streetCount = 0

    let ble = BLELink()
    let location = LocationFeed()

    private var nav: NavRoute?
    private var destination: MKMapItem?
    private var streets: [[XY]] = []
    private var hint = 0
    private var offRouteTicks = 0

    private var frame: LocalFrame?  // free ride origin
    private var latest: CLLocation?
    private var timer: Timer?
    private var lastHeading = 0.0
    private let geocoder = CLGeocoder()
    private var lastGeocode: (at: Date, where: CLLocation)?

    init() {
        location.onLocation = { [weak self] loc in self?.handle(loc) }
        ble.onHello = { [weak self] in self?.resync() }
    }

    // MARK: Planning

    func plan(to item: MKMapItem) {
        planning = true
        problem = nil
        location.start()  // a fresh fix for the start of the route
        Task {
            defer { planning = false }
            do {
                let route = try await Self.directions(from: .forCurrentLocation(), to: item)
                preview = Preview(route: route, destination: item)
            } catch {
                problem = "Couldn't find a route there. Try another place."
            }
            if mode == .idle && preview == nil { location.stop() }
        }
    }

    func cancelPreview() {
        preview = nil
        if mode == .idle { location.stop() }
    }

    private static func directions(from: MKMapItem, to: MKMapItem) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = from
        request.destination = to
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        guard let route = try await MKDirections(request: request).calculate().routes.first else {
            throw URLError(.cannotFindHost)
        }
        return route
    }

    // MARK: Starting and stopping

    func startNavigation() {
        guard let preview else { return }
        destination = preview.destination
        nav = NavRoute(preview.route, destinationName: preview.destination.name ?? "Destination")
        streets = []
        self.preview = nil
        begin(.navigating)
        upload()
    }

    func startFreeRide() {
        frame = nil
        begin(.freeRide)
        ble.send(Msg.reset(), reliable: true)
    }

    func stop() {
        mode = .idle
        timer?.invalidate()
        timer = nil
        location.stop()
        ble.cancelBulk()
        ble.send(Msg.reset(), reliable: true)
        nav = nil
        nextTurn = nil
        eta = nil
    }

    private func begin(_ m: Mode) {
        mode = m
        sent = 0
        hint = 0
        offRouteTicks = 0
        arrived = false
        latest = nil
        location.start()
        timer?.invalidate()
        // Background location keeps the app running when locked, so this keeps firing.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Talking to the Cheeko

    /// Route first (must arrive, in order), then the streets (best effort, in the background).
    private func upload() {
        guard let nav else { return }
        ble.cancelBulk()
        ble.send(Msg.reset(), reliable: true)
        ble.send(Msg.routeBegin, reliable: true)
        for i in stride(from: 0, to: nav.pts.count, by: Msg.pointsPerMessage) {
            ble.send(Msg.routePoints(nav.pts[i..<min(i + Msg.pointsPerMessage, nav.pts.count)]), reliable: true)
        }
        ble.send(Msg.routeEnd, reliable: true)
        ble.send(Msg.state(.navigating), reliable: true)
        if !roadName.isEmpty { ble.send(Msg.road(roadName), reliable: true) }

        if !streets.isEmpty {
            sendStreets()
        } else {
            Task {
                let found = await StreetNetwork.fetch(around: nav)
                guard self.nav?.pts.count == nav.pts.count else { return }  // route changed meanwhile
                self.streets = found
                self.streetCount = found.count
                self.sendStreets()
            }
        }
    }

    private func sendStreets() {
        var messages = [Msg.roadsClear]
        let step = Msg.pointsPerMessage - 1  // pieces share an end point so lines stay joined
        for line in streets {
            for i in stride(from: 0, to: line.count - 1, by: step) {
                messages.append(Msg.roadsLine(line[i..<min(i + Msg.pointsPerMessage, line.count)]))
            }
        }
        ble.sendBulk(messages)
    }

    /// The Cheeko (re)connected or restarted: give it everything again.
    private func resync() {
        switch mode {
        case .navigating: upload()
        case .freeRide:
            frame = nil
            ble.send(Msg.reset(), reliable: true)
            if !roadName.isEmpty { ble.send(Msg.road(roadName), reliable: true) }
        case .idle: break
        }
    }

    // MARK: Every second

    private func handle(_ loc: CLLocation) {
        latest = loc
        // GPS course is only meaningful when moving; hold the last one when stopped.
        if loc.course >= 0 && loc.speed > 0.8 { lastHeading = loc.course }
        if mode != .idle { lookUpRoad(loc) }
    }

    /// Runs whether or not GPS had anything new: iOS sends fixes rarely when you
    /// stand still or are indoors, and the Cheeko treats silence as trouble.
    private func tick() {
        guard let loc = latest else { return }
        let stale = Date().timeIntervalSince(loc.timestamp) > 3  // no new fix: we're not moving
        let speed = stale ? 0 : max(0, loc.speed)

        switch mode {
        case .idle:
            return
        case .freeRide:
            if frame == nil { frame = LocalFrame(origin: loc.coordinate) }
            guard let frame else { return }
            let p = frame.xy(loc.coordinate)
            ble.send(Msg.pos(x: p.x, y: p.y, heading: lastHeading, speed: speed, accuracy: loc.horizontalAccuracy))
        case .navigating:
            guard let nav else { return }
            let p = nav.frame.point(loc.coordinate)
            ble.send(Msg.pos(x: p.x, y: p.y, heading: lastHeading, speed: speed, accuracy: loc.horizontalAccuracy))
            follow(nav, at: p, loc: loc)
        }
        sent += 1
    }

    private func follow(_ nav: NavRoute, at p: XY, loc: CLLocation) {
        let pr = nav.project(p, near: hint)
        hint = pr.segment

        // Off the route for 5 s (and GPS good enough to be sure): plan again from here.
        offRouteTicks = pr.offRoute > 40 && loc.horizontalAccuracy < 30 ? offRouteTicks + 1 : 0
        if offRouteTicks >= 5 && !rerouting && !arrived { reroute(from: loc) }

        let k = nav.nextTurn(after: pr.progress)
        let t = nav.turns[k]
        let toTurn = max(0, nav.cum[t.index] - pr.progress)
        let left = max(0, nav.length - pr.progress)
        let seconds = left * nav.secondsPerMetre
        ble.send(Msg.turn(t.kind, exit: t.exit, index: t.index, distance: toTurn, street: t.street))
        ble.send(Msg.upcoming(nav.turns.dropFirst(k + 1)))
        ble.send(Msg.trip(eta: Date().addingTimeInterval(seconds), remaining: left, minutes: Int((seconds / 60).rounded(.up))))

        nextTurn = t
        nextTurnDistance = toTurn
        remaining = left
        eta = Date().addingTimeInterval(seconds)

        if left < 20 && !arrived {
            arrived = true
            ble.send(Msg.state(.arrived), reliable: true)
        }
    }

    private func reroute(from loc: CLLocation) {
        guard let destination else { return }
        rerouting = true
        ble.send(Msg.state(.rerouting), reliable: true)
        Task {
            defer { rerouting = false; offRouteTicks = 0 }
            let here = MKMapItem(placemark: MKPlacemark(coordinate: loc.coordinate))
            guard mode == .navigating, let route = try? await Self.directions(from: here, to: destination) else {
                ble.send(Msg.state(.navigating), reliable: true)
                return
            }
            nav = NavRoute(route, destinationName: destination.name ?? "Destination")
            streets = []
            hint = 0
            upload()
        }
    }

    private func lookUpRoad(_ loc: CLLocation) {
        if let last = lastGeocode,
           Date().timeIntervalSince(last.at) < 20 || loc.distance(from: last.where) < 60 { return }
        lastGeocode = (Date(), loc)
        geocoder.reverseGeocodeLocation(loc) { [weak self] places, _ in
            guard let street = places?.first?.thoroughfare else { return }
            Task { @MainActor in
                guard let self, street != self.roadName else { return }
                self.roadName = street
                self.ble.send(Msg.road(street), reliable: true)
            }
        }
    }
}
