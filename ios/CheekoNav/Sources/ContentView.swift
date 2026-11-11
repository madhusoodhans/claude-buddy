// Screens: search ("Where to?"), route card, navigating, free ride.

import CoreLocation
import MapKit
import SwiftUI

extension Color {
    static let lime = Color(red: 0.745, green: 0.949, blue: 0.314)  // the Cheeko's accent
    static let panel = Color(white: 0.11)
    static let page = Color(white: 0.06)
}

private func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
}

private func distanceText(_ m: Double) -> String {
    m < 1000 ? "\(Int((m / 10).rounded()) * 10) m" : String(format: "%.1f km", m / 1000)
}

struct ContentView: View {
    @ObservedObject var session: RideSession
    @ObservedObject var ble: BLELink
    @ObservedObject var location: LocationFeed
    @StateObject private var search = PlaceSearch()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusLine
            Text("Cheeko Nav").font(mono(30, .bold))
            switch session.mode {
            case .navigating: navigating
            case .freeRide: freeRide
            case .idle:
                if let preview = session.preview { routeCard(preview) } else { searchScreen }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.page)
        .onAppear { location.prepare() }
    }

    // MARK: Search

    private var searchScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Where to?", text: $search.query)
                .font(mono(17))
                .padding(14)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 14))
                .autocorrectionDisabled()
                .onChange(of: search.query) { search.focus(near: location.last) }

            if session.planning {
                HStack { ProgressView(); Text("Finding a route...").font(mono(14)).foregroundStyle(.secondary) }
            }
            if let problem = session.problem {
                Text(problem).font(mono(13)).foregroundStyle(.orange)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(search.results, id: \.self) { place in
                        Button {
                            Task {
                                if let item = await search.resolve(place) {
                                    search.query = ""
                                    session.plan(to: item)
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(place.title).font(mono(15, .semibold)).foregroundStyle(.white)
                                if !place.subtitle.isEmpty {
                                    Text(place.subtitle).font(mono(12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                        }
                        Divider().overlay(Color.panel)
                    }
                }
            }
            Spacer(minLength: 0)
            secondaryButton("Free ride (no route)") { session.startFreeRide() }
            footnote("Turn on the Cheeko. It switches to Navigation by itself when you start.")
        }
    }

    // MARK: Route card

    private func routeCard(_ preview: RideSession.Preview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.destination.name ?? "Destination").font(mono(20, .bold))
                if let address = preview.destination.placemark.title {
                    Text(address).font(mono(12)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((preview.route.expectedTravelTime / 60).rounded())) min").font(mono(30, .bold))
                Spacer()
                Text(distanceText(preview.route.distance)).font(mono(18, .semibold))
            }
            .padding(18)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.lime, lineWidth: 1.5))
            Spacer()
            primaryButton("Start") { session.startNavigation() }
            secondaryButton("Back") { session.cancelPreview() }
        }
    }

    // MARK: Navigating

    private var navigating: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if session.arrived {
                    Text("You've arrived").font(mono(26, .bold)).foregroundStyle(Color.lime)
                } else if session.rerouting {
                    Text("Rerouting...").font(mono(26, .bold))
                } else if let turn = session.nextTurn {
                    Text(turn.kind == .arrive ? "Arrive in" : turn.kind.words).font(mono(15)).foregroundStyle(.secondary)
                    Text(distanceText(session.nextTurnDistance)).font(mono(34, .bold))
                    if !turn.street.isEmpty { Text(turn.street).font(mono(16, .semibold)).lineLimit(1) }
                } else {
                    Text("Starting...").font(mono(20, .bold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color.panel, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 12) {
                stat("ARRIVE", session.eta.map { $0.formatted(date: .omitted, time: .shortened) } ?? "-")
                stat("TO GO", distanceText(session.remaining))
                stat("SPEED", speed)
            }
            if !session.roadName.isEmpty {
                Text("On \(session.roadName)").font(mono(14)).foregroundStyle(.secondary)
            }
            Text("\(session.streetCount) streets on the map  ·  \(session.sent) updates sent")
                .font(mono(11)).foregroundStyle(.secondary)
            Spacer()
            secondaryButton("End ride") { session.stop() }
            footnote("You can lock your phone. The Cheeko keeps navigating.")
        }
    }

    // MARK: Free ride

    private var freeRide: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                stat("SPEED", speed)
                stat("GPS", accuracy)
                stat("SENT", "\(session.sent)")
            }
            if !session.roadName.isEmpty {
                Text("On \(session.roadName)").font(mono(14)).foregroundStyle(.secondary)
            }
            Spacer()
            secondaryButton("Stop ride") { session.stop() }
            footnote("You can lock your phone. The Cheeko keeps showing where you are.")
        }
    }

    // MARK: Pieces

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text("Cheeko  \(statusText)").font(mono(13)).foregroundStyle(.secondary)
            if location.denied {
                Text("· location off").font(mono(13)).foregroundStyle(.orange)
            }
        }
    }

    private var statusText: String {
        switch ble.status {
        case .bluetoothOff: return "Bluetooth is off"
        case .searching: return "searching..."
        case .connecting: return "connecting..."
        case .connected: return "connected"
        }
    }

    private var statusColor: Color {
        switch ble.status {
        case .connected: return .lime
        case .bluetoothOff: return .red
        default: return .orange
        }
    }

    private var speed: String {
        guard let loc = location.last, loc.speed >= 0 else { return "-" }
        return "\(Int((loc.speed * 3.6).rounded())) km/h"
    }

    private var accuracy: String {
        guard let loc = location.last else { return "-" }
        return "±\(Int(loc.horizontalAccuracy.rounded())) m"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(mono(11, .semibold)).foregroundStyle(.secondary)
            Text(value).font(mono(17, .bold)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(mono(20, .bold)).frame(maxWidth: .infinity).padding(.vertical, 18)
                .background(Color.lime, in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(.black)
        }
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(mono(17, .bold)).frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(mono(12)).foregroundStyle(.secondary)
    }
}
