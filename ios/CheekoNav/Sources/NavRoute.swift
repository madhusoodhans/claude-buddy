// An Apple Maps route in the Cheeko's terms: points in metres around an origin,
// and the turns along it. Apple gives each step as text ("Turn right onto X"),
// so the turn type comes from the road shape at the step, with the text for
// roundabouts, U-turns and keep-left/right.

import CoreLocation
import MapKit

struct NavTurn {
    var index: Int  // route point where the turn is
    var kind: Maneuver
    var exit: UInt8 = 0
    var street: String = ""
}

struct NavRoute {
    let frame: LocalFrame
    let pts: [XY]
    let cum: [Double]  // distance along the route at each point
    let turns: [NavTurn]  // the last one is always .arrive
    let secondsPerMetre: Double
    let destinationName: String

    var length: Double { cum.last ?? 0 }

    init(_ route: MKRoute, destinationName: String) {
        let n = route.polyline.pointCount
        let coords = (0..<n).map { route.polyline.points()[$0].coordinate }
        let frame = LocalFrame(origin: coords.first ?? CLLocationCoordinate2D())
        let pts = coords.map(frame.point)
        let cum = Self.cumulative(pts)
        self.frame = frame
        self.pts = pts
        self.cum = cum
        secondsPerMetre = route.distance > 0 ? route.expectedTravelTime / route.distance : 0.12
        self.destinationName = destinationName

        var turns: [NavTurn] = []
        var searchFrom = 0
        for step in route.steps where step.polyline.pointCount > 0 {
            let start = frame.point(step.polyline.points()[0].coordinate)
            // Nearest route point to where the step starts, searching forward to keep order.
            guard searchFrom < pts.count else { break }
            let idx = (searchFrom..<pts.count).min { dist2(pts[$0], start) < dist2(pts[$1], start) } ?? searchFrom
            searchFrom = idx
            guard idx > 0, idx < pts.count - 1, !step.instructions.isEmpty else { continue }
            if let t = Self.turn(step.instructions, at: idx, pts: pts, cum: cum) { turns.append(t) }
        }
        turns = Self.addMissingBends(turns, pts: pts, cum: cum)
        turns = Self.mergeUTurns(turns, cum: cum)
        turns.append(NavTurn(index: max(0, pts.count - 1), kind: .arrive, street: destinationName))
        self.turns = turns
    }

    // MARK: Following along

    /// Progress along the route of the point nearest p, and how far p is from it.
    func project(_ p: XY, near hint: Int) -> (progress: Double, offRoute: Double, segment: Int) {
        func scan(_ range: Range<Int>) -> (Double, Double, Int) {
            var best = (Double.infinity, 0.0, 0)
            for i in range where i + 1 < pts.count {
                let a = pts[i], b = pts[i + 1]
                let vx = b.x - a.x, vy = b.y - a.y, l2 = vx * vx + vy * vy
                let t = l2 > 0 ? max(0, min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / l2)) : 0
                let d2 = pow(a.x + vx * t - p.x, 2) + pow(a.y + vy * t - p.y, 2)
                if d2 < best.0 { best = (d2, cum[i] + (cum[i + 1] - cum[i]) * t, i) }
            }
            return (best.1, best.0.squareRoot(), best.2)
        }
        var r = scan(max(0, hint - 30)..<min(pts.count, hint + 150))
        if r.1 > 40 { r = scan(0..<pts.count) }
        return (r.0, r.1, r.2)
    }

    func nextTurn(after progress: Double) -> Int {
        turns.firstIndex { cum[$0.index] > progress + 1 } ?? turns.count - 1
    }

    // MARK: Building

    private static func cumulative(_ pts: [XY]) -> [Double] {
        var c = [0.0]
        for i in 1..<max(1, pts.count) { c.append(c[i - 1] + dist(pts[i - 1], pts[i])) }
        return c
    }

    private static func pointAt(_ p: Double, pts: [XY], cum: [Double]) -> XY {
        let p = max(0, min(p, cum.last ?? 0))
        var i = 0
        while i + 2 < pts.count && cum[i + 1] < p { i += 1 }
        let seg = cum[i + 1] - cum[i]
        let t = seg > 0 ? (p - cum[i]) / seg : 0
        return XY(x: pts[i].x + (pts[i + 1].x - pts[i].x) * t, y: pts[i].y + (pts[i + 1].y - pts[i].y) * t)
    }

    /// Change of direction at point i, comparing 20 m before with 20 m after (degrees, + = right).
    private static func bend(at i: Int, pts: [XY], cum: [Double], window: Double = 20) -> Double {
        let before = pointAt(cum[i] - window, pts: pts, cum: cum), after = pointAt(cum[i] + window, pts: pts, cum: cum)
        let d = bearing(pts[i], after) - bearing(before, pts[i])
        return (d + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private static func classify(_ d: Double) -> Maneuver {
        let a = abs(d), right = d > 0
        if a > 165 { return right ? .uTurn : .uTurnLeft }
        if a > 120 { return right ? .sharpRight : .sharpLeft }
        if a > 55 { return right ? .right : .left }
        return right ? .slightRight : .slightLeft
    }

    private static func turn(_ text: String, at idx: Int, pts: [XY], cum: [Double]) -> NavTurn? {
        let lower = text.lowercased()
        let street = streetName(text)
        if lower.contains("arrive") || lower.contains("destination") { return nil }  // added at the end
        if lower.contains("roundabout") || lower.contains("rotary") {
            let exit = lower.range(of: #"(\d+)(st|nd|rd|th) exit"#, options: .regularExpression)
                .flatMap { UInt8(lower[$0].prefix { $0.isNumber }) } ?? 0
            return NavTurn(index: idx, kind: .roundabout, exit: exit, street: street)
        }
        let d = bend(at: idx, pts: pts, cum: cum)
        if lower.contains("u-turn") || lower.contains("u turn") {
            return NavTurn(index: idx, kind: d < 0 ? .uTurnLeft : .uTurn, street: street)
        }
        if lower.contains("keep left") || lower.contains("bear left") { return NavTurn(index: idx, kind: .keepLeft, street: street) }
        if lower.contains("keep right") || lower.contains("bear right") { return NavTurn(index: idx, kind: .keepRight, street: street) }
        if abs(d) < 25 { return nil }  // "continue onto ...": no real turn, don't hide the next one
        return NavTurn(index: idx, kind: classify(d), street: street)
    }

    /// "Turn right onto Rye Lane" -> "Rye Lane".
    private static func streetName(_ text: String) -> String {
        for marker in [" onto ", " on to ", " on ", " toward ", " towards "] {
            if let r = text.range(of: marker, options: .caseInsensitive) {
                return String(text[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            }
        }
        return ""
    }

    /// Routers skip bends where the road keeps its name, but a 90 degree bend
    /// still needs announcing on a bike.
    private static func addMissingBends(_ turns: [NavTurn], pts: [XY], cum: [Double]) -> [NavTurn] {
        var out = turns
        var lastBend = -Double.infinity
        for i in 1..<max(1, pts.count - 1) {
            let d = bend(at: i, pts: pts, cum: cum)
            guard abs(d) >= 50, cum[i] - lastBend > 40 else { continue }
            if turns.contains(where: { abs(cum[$0.index] - cum[i]) <= 40 }) { continue }
            out.append(NavTurn(index: i, kind: classify(d)))
            lastBend = cum[i]
        }
        return out.sorted { $0.index < $1.index }
    }

    /// Two turns the same way a few metres apart (through a median gap) are one U-turn.
    private static func mergeUTurns(_ turns: [NavTurn], cum: [Double]) -> [NavTurn] {
        func side(_ k: Maneuver) -> Int { [.left, .sharpLeft].contains(k) ? -1 : ([.right, .sharpRight].contains(k) ? 1 : 0) }
        var out: [NavTurn] = []
        for t in turns {
            if let prev = out.last, side(t.kind) != 0, side(prev.kind) == side(t.kind), cum[t.index] - cum[prev.index] < 45 {
                out[out.count - 1] = NavTurn(index: prev.index, kind: side(t.kind) < 0 ? .uTurnLeft : .uTurn,
                                             street: t.street.isEmpty ? prev.street : t.street)
            } else {
                out.append(t)
            }
        }
        return out
    }
}

func dist(_ a: XY, _ b: XY) -> Double { hypot(b.x - a.x, b.y - a.y) }
func dist2(_ a: XY, _ b: XY) -> Double { pow(b.x - a.x, 2) + pow(b.y - a.y, 2) }
func bearing(_ a: XY, _ b: XY) -> Double { atan2(b.x - a.x, b.y - a.y) * 180 / .pi }
