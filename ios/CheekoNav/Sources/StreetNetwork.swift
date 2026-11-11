// Streets around a route, from OpenStreetMap (Overpass), for the Cheeko's map.
// Optional: if this fails the route still works, just without side streets.

import Foundation

enum StreetNetwork {
    static let maxLines = 1200, maxPoints = 9000  // keeps the Bluetooth upload to a few seconds

    static func fetch(around route: NavRoute, margin: Double = 300) async -> [[XY]] {
        let xs = route.pts.map(\.x), ys = route.pts.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [] }
        let sw = route.frame.coordinate(XY(x: minX - margin, y: minY - margin))
        let ne = route.frame.coordinate(XY(x: maxX + margin, y: maxY + margin))
        let types = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|"
            + "motorway_link|trunk_link|primary_link|secondary_link|tertiary_link"
        let query = String(format: "[out:json][timeout:25];way[\"highway\"~\"^(%@)$\"](%.5f,%.5f,%.5f,%.5f);out geom;",
                           types, sw.latitude, sw.longitude, ne.latitude, ne.longitude)

        var request = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("cheeko-nav/0.3", forHTTPHeaderField: "User-Agent")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")".data(using: .utf8)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { return [] }

        var lines: [[XY]] = []
        for way in elements {
            guard let geometry = way["geometry"] as? [[String: Double]] else { continue }
            var line: [XY] = []
            for node in geometry {
                guard let lat = node["lat"], let lon = node["lon"] else { continue }
                let p = route.frame.point(.init(latitude: lat, longitude: lon))
                if line.last.map({ dist($0, p) >= 3 }) ?? true { line.append(p) }  // drop near-duplicates
            }
            if line.count >= 2 { lines.append(line) }
        }

        // Keep the streets nearest the route if there are too many.
        let stride = max(1, route.pts.count / 150)
        let sample = Swift.stride(from: 0, to: route.pts.count, by: stride).map { route.pts[$0] }
        func nearness(_ line: [XY]) -> Double {
            let step = max(1, line.count / 5)
            return Swift.stride(from: 0, to: line.count, by: step).map { p in sample.map { dist2(line[p], $0) }.min() ?? 0 }.min() ?? 0
        }
        let sorted = lines.map { ($0, nearness($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
        var kept: [[XY]] = [], points = 0
        for line in sorted {
            guard kept.count < maxLines, points + line.count <= maxPoints else { break }
            kept.append(line)
            points += line.count
        }
        return kept
    }
}
