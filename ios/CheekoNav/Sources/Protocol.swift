// Messages to the Cheeko, byte for byte as in cheeko/PROTOCOL.md.
// All integers little-endian; positions in decimetres east/north of an origin.

import CoreLocation
import Foundation

enum Msg {
    static func reset() -> Data { Data([0x14]) }

    static func pos(x: Double, y: Double, heading: Double, speed: Double, accuracy: Double) -> Data {
        var d = Data([0x10])
        d.appendLE(Int32(clamping: Int((x * 10).rounded())))
        d.appendLE(Int32(clamping: Int((y * 10).rounded())))
        d.appendLE(UInt16(clamping: Int((heading.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) * 100)))
        d.appendLE(UInt16(clamping: Int(max(0, speed) * 100)))
        d.appendLE(UInt16(clamping: Int(max(0, accuracy) * 10)))
        return d
    }

    static func road(_ name: String) -> Data { Data([0x16]) + deviceText(name) }

    static let routeBegin = Data([0x01]), routeEnd = Data([0x03]), roadsClear = Data([0x04])

    /// One message holds at most this many points (MTU 247, 8 bytes each).
    static let pointsPerMessage = 28

    static func routePoints(_ pts: ArraySlice<XY>) -> Data { points(0x02, pts) }
    static func roadsLine(_ pts: ArraySlice<XY>) -> Data { points(0x05, pts) }

    private static func points(_ type: UInt8, _ pts: ArraySlice<XY>) -> Data {
        var d = Data([type])
        for p in pts {
            d.appendLE(Int32(clamping: Int((p.x * 10).rounded())))
            d.appendLE(Int32(clamping: Int((p.y * 10).rounded())))
        }
        return d
    }

    static func turn(_ kind: Maneuver, exit: UInt8, index: Int, distance: Double, street: String) -> Data {
        var d = Data([0x11, kind.rawValue, exit])
        d.appendLE(UInt16(clamping: index))
        d.appendLE(UInt32(clamping: Int(max(0, distance))))
        return d + deviceText(street)
    }

    static func upcoming(_ turns: ArraySlice<NavTurn>) -> Data {
        var d = Data([0x15])
        for t in turns.prefix(2) {
            d.append(contentsOf: [t.kind.rawValue, t.exit])
            d.appendLE(UInt16(clamping: t.index))
        }
        return d
    }

    static func trip(eta: Date, remaining: Double, minutes: Int) -> Data {
        let c = Calendar.current.dateComponents([.hour, .minute], from: eta)
        var d = Data([0x12, UInt8(c.hour ?? 0), UInt8(c.minute ?? 0)])
        d.appendLE(UInt32(clamping: Int(max(0, remaining))))
        d.appendLE(UInt16(clamping: max(0, minutes)))
        return d
    }

    static func state(_ s: DeviceState) -> Data { Data([0x13, s.rawValue]) }
}

enum Maneuver: UInt8 {
    case none = 0, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight
    case uTurn, roundabout, arrive, keepLeft, keepRight, uTurnLeft

    var words: String {
        switch self {
        case .none, .straight: return "Continue"
        case .slightLeft: return "Slight left"
        case .left: return "Turn left"
        case .sharpLeft: return "Sharp left"
        case .slightRight: return "Slight right"
        case .right: return "Turn right"
        case .sharpRight: return "Sharp right"
        case .uTurn, .uTurnLeft: return "U-turn"
        case .roundabout: return "Roundabout"
        case .arrive: return "Arrive"
        case .keepLeft: return "Keep left"
        case .keepRight: return "Keep right"
        }
    }
}

enum DeviceState: UInt8 { case idle = 0, navigating, rerouting, arrived, noGps }

struct XY { var x: Double, y: Double }

extension Msg {

    /// The Cheeko's fonts are ASCII: fold accents and curly quotes, drop the rest.
    static func deviceText(_ s: String) -> Data {
        let folded = s.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? s
        let ascii = folded.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }
        return Data(String(String.UnicodeScalarView(ascii)).utf8.prefix(47))
    }
}

/// Metres east/north of an origin. Accurate enough across a city.
struct LocalFrame {
    let origin: CLLocationCoordinate2D

    private var kx: Double { 111_320 * cos(origin.latitude * .pi / 180) }

    func xy(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((c.longitude - origin.longitude) * kx, (c.latitude - origin.latitude) * 110_540)
    }

    func point(_ c: CLLocationCoordinate2D) -> XY { let p = xy(c); return XY(x: p.x, y: p.y) }

    func coordinate(_ p: XY) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: origin.latitude + p.y / 110_540, longitude: origin.longitude + p.x / kx)
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) }
    }
}
