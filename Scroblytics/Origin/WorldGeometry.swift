import Foundation
import SwiftUI

/// The Robinson projection: a world map that is neither stretched at the poles nor squeezed at the edges. Longitude and latitude in
/// degrees go to a flat point with x and y both between -1 and 1 (y up); the whole map is `aspect` times as wide as it is tall.
enum RobinsonProjection {
    /// The table every Robinson map uses: at each 5° of latitude from 0 to 90, how wide a line of latitude is and how far from the equator it sits.
    private static let width: [Double] = [1.0000, 0.9986, 0.9954, 0.9900, 0.9822, 0.9730, 0.9600, 0.9427, 0.9216, 0.8962, 0.8679, 0.8350, 0.7986, 0.7597, 0.7186, 0.6732, 0.6213, 0.5722, 0.5322]
    private static let height: [Double] = [0.0000, 0.0620, 0.1240, 0.1860, 0.2480, 0.3100, 0.3720, 0.4340, 0.4958, 0.5571, 0.6176, 0.6769, 0.7346, 0.7903, 0.8435, 0.8936, 0.9394, 0.9761, 1.0000]
    /// The map's scale factors: full width is 0.8487·π, full height 1.3523 (both for a unit sphere).
    private static let xScale = 0.8487 * Double.pi
    private static let yScale = 1.3523
    /// Width divided by height of the whole globe, pole to pole.
    static let fullAspect = (2 * xScale) / (2 * yScale)
    /// The map shows only the latitudes where there is land people are from: from 84°N (the top of Greenland) to 58°S (below Tierra del Fuego),
    /// so the frame is not wasted on Antarctica and the empty Arctic.
    static let topLatitude = 84.0
    static let bottomLatitude = -58.0
    /// The projected y of those two latitudes, which are the top and bottom of the frame.
    static let top = Double(project(longitude: 0, latitude: topLatitude).y)
    static let bottom = Double(project(longitude: 0, latitude: bottomLatitude).y)
    /// Width divided by height of the frame the map is drawn in.
    static let aspect = (2 * xScale) / (yScale * (top - bottom))

    private static func interpolate(_ table: [Double], _ absoluteLatitude: Double) -> Double {
        let position = min(max(absoluteLatitude, 0), 90) / 5
        let lower = Int(position.rounded(.down))
        if lower >= table.count - 1 { return table[table.count - 1] }
        let fraction = position - Double(lower)
        return table[lower] + (table[lower + 1] - table[lower]) * fraction
    }

    static func project(longitude: Double, latitude: Double) -> CGPoint {
        let absolute = abs(latitude)
        let x = interpolate(width, absolute) * (longitude * Double.pi / 180) * 0.8487 / xScale
        let y = interpolate(height, absolute) * (latitude < 0 ? -1 : 1)
        return CGPoint(x: x, y: y)
    }
}

/// One country's outline as the map draws it: its outer rings in longitude and latitude, and the same points projected.
struct WorldCountry: Sendable {
    let iso: String
    let name: String
    /// Each ring is a list of points; x is longitude and y latitude.
    let rings: [[CGPoint]]
    /// The rings in projected space (x and y between -1 and 1).
    let projected: [[CGPoint]]
    let bounds: CGRect
}

/// The world's countries, drawn from a bundled outline (Natural Earth 1:110m, public domain), with the projection, hit testing and a
/// "centre" for every country, used for shading countries and for placing an artist whose city is not known.
struct WorldGeometry: Sendable {
    let countries: [WorldCountry]
    private let byCode: [String: Int]

    private struct File: Decodable {
        struct Entry: Decodable { let iso: String; let name: String; let rings: [[Double]] }
        let countries: [Entry]
    }

    init(countries: [WorldCountry]) {
        self.countries = countries
        byCode = Dictionary(countries.enumerated().map { ($1.iso, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Reads the bundled outline. A missing or unreadable file gives an empty world, so the map shows nothing instead of crashing.
    init(data: Data) {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { self.init(countries: []); return }
        self.init(countries: file.countries.map { entry in
            let rings = entry.rings.map { flat -> [CGPoint] in
                stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
            }
            let projected = rings.map { $0.map { RobinsonProjection.project(longitude: Double($0.x), latitude: Double($0.y)) } }
            let all = projected.flatMap { $0 }
            let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 0, minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 0
            return WorldCountry(iso: entry.iso, name: entry.name, rings: rings, projected: projected, bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        })
    }

    /// The outline that ships in the app.
    static let bundled: WorldGeometry = {
        guard let url = Bundle.main.url(forResource: "world-110m", withExtension: "json"), let data = try? Data(contentsOf: url) else { return WorldGeometry(countries: []) }
        return WorldGeometry(data: data)
    }()

    func country(_ iso: String) -> WorldCountry? { byCode[iso.uppercased()].map { countries[$0] } }

    /// The country under a point of the projected map (x and y between -1 and 1), or nil over the sea.
    func countryAt(_ point: CGPoint) -> String? {
        for country in countries where country.bounds.insetBy(dx: -0.001, dy: -0.001).contains(point) {
            if country.projected.contains(where: { Self.contains($0, point) }) { return country.iso }
        }
        return nil
    }

    private static func contains(_ ring: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var previous = ring.count - 1
        for index in ring.indices {
            let a = ring[index], b = ring[previous]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            previous = index
        }
        return inside
    }

    /// A good place to put one marker for a whole country: the middle of its biggest piece of land, as longitude and latitude.
    func centre(of iso: String) -> (latitude: Double, longitude: Double)? {
        guard let country = country(iso), let ring = country.rings.max(by: { abs(Self.area($0)) < abs(Self.area($1)) }), ring.count > 2 else { return nil }
        let area = Self.area(ring)
        guard abs(area) > 1e-9 else {
            return (ring.map { Double($0.y) }.reduce(0, +) / Double(ring.count), ring.map { Double($0.x) }.reduce(0, +) / Double(ring.count))
        }
        var x = 0.0, y = 0.0
        var previous = ring.count - 1
        for index in ring.indices {
            let a = ring[previous], b = ring[index]
            let cross = Double(a.x * b.y - b.x * a.y)
            x += Double(a.x + b.x) * cross
            y += Double(a.y + b.y) * cross
            previous = index
        }
        return (y / (6 * area), x / (6 * area))
    }

    /// Signed area of a ring in square degrees (positive when it runs counter-clockwise).
    private static func area(_ ring: [CGPoint]) -> Double {
        var sum = 0.0
        var previous = ring.count - 1
        for index in ring.indices {
            sum += Double(ring[previous].x * ring[index].y - ring[index].x * ring[previous].y)
            previous = index
        }
        return sum / 2
    }

    /// A country's outline as a path in `rect`, which should have the frame's aspect ratio (see `RobinsonProjection.aspect`).
    func path(for country: WorldCountry, in rect: CGRect) -> Path {
        var path = Path()
        for ring in country.projected where ring.count > 2 {
            path.addLines(ring.map { Self.point($0, in: rect) })
            path.closeSubpath()
        }
        return path
    }

    /// A projected point (x and y between -1 and 1, y up) placed in `rect`, which shows the latitudes from `RobinsonProjection.topLatitude`
    /// down to `bottomLatitude`.
    static func point(_ projected: CGPoint, in rect: CGRect) -> CGPoint {
        let span = RobinsonProjection.top - RobinsonProjection.bottom
        return CGPoint(x: rect.minX + (projected.x + 1) / 2 * rect.width, y: rect.minY + CGFloat((RobinsonProjection.top - Double(projected.y)) / span) * rect.height)
    }

    /// The projected point at a spot of the frame: the opposite of `point(_:in:)`.
    static func projected(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let span = RobinsonProjection.top - RobinsonProjection.bottom
        return CGPoint(x: (point.x - rect.minX) / rect.width * 2 - 1, y: CGFloat(RobinsonProjection.top - Double((point.y - rect.minY) / rect.height) * span))
    }
}
