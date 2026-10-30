import Foundation
import CoreLocation

/// Lokatory Maidenhead, odległość i azymut po kole wielkim (kula o promieniu 6371 km).
enum Geo {
    static func isValidGrid(_ grid: String) -> Bool {
        grid.range(of: "^[A-Ra-r]{2}[0-9]{2}([A-Xa-x]{2})?$", options: .regularExpression) != nil
    }

    /// Środek pola lokatora (4 lub 6 znaków).
    static func coordinate(fromGrid raw: String) -> CLLocationCoordinate2D? {
        let grid = raw.trimmingCharacters(in: .whitespaces)
        guard isValidGrid(grid) else { return nil }
        let g = Array(grid.uppercased().unicodeScalars).map { Int($0.value) }
        var lon = Double(g[0] - 65) * 20 - 180 + Double(g[2] - 48) * 2
        var lat = Double(g[1] - 65) * 10 - 90 + Double(g[3] - 48)
        if g.count == 6 {
            lon += Double(g[4] - 65) * 5 / 60 + 2.5 / 60
            lat += Double(g[5] - 65) * 2.5 / 60 + 1.25 / 60
        } else {
            lon += 1
            lat += 0.5
        }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Lokator 6-znakowy dla współrzędnych.
    static func grid(for coordinate: CLLocationCoordinate2D) -> String {
        let lon = min(max(coordinate.longitude + 180, 0), 359.999)
        let lat = min(max(coordinate.latitude + 90, 0), 179.999)
        let scalars: [Character] = [
            Character(UnicodeScalar(65 + Int(lon / 20))!),
            Character(UnicodeScalar(65 + Int(lat / 10))!),
            Character(UnicodeScalar(48 + Int(lon.truncatingRemainder(dividingBy: 20) / 2))!),
            Character(UnicodeScalar(48 + Int(lat.truncatingRemainder(dividingBy: 10)))!),
            Character(UnicodeScalar(97 + Int(lon.truncatingRemainder(dividingBy: 2) * 12))!),
            Character(UnicodeScalar(97 + Int(lat.truncatingRemainder(dividingBy: 1) * 24))!)
        ]
        return String(scalars)
    }

    static func distanceKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * 6371 * asin(min(1, sqrt(h)))
    }

    /// Azymut początkowy (stopnie od północy, zgodnie z ruchem wskazówek zegara).
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dl) * cos(p2)
        let x = cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Kierunek świata (16 kierunków, np. ENE).
    static func compass(_ bearing: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return names[Int((bearing / 22.5).rounded()) % 16]
    }
}
