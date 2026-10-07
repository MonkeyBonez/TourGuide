import Foundation

/// When an Apple Maps search result is the same place as an OSM sight (PRD §8.10). Apple's
/// English names beat the on-device translator for Tier-2 temples (専光寺 → "Senko-ji Temple"),
/// but a name search near a pin also finds bus stops and the wrong park: 6 Oct 2026, 武蔵ヶ辻小緑地
/// matched a bus stop and 広坂緑地 a park 113 m away. Pure, so it is tested without MapKit.
public enum AppleNameGuard {
    /// `MKPointOfInterestCategory.rawValue`s that are never a sight.
    public static let blockedCategories: Set<String> = [
        "MKPOICategoryPublicTransport", "MKPOICategoryParking", "MKPOICategoryRestaurant", "MKPOICategoryCafe",
        "MKPOICategoryStore", "MKPOICategoryATM", "MKPOICategoryBank", "MKPOICategoryGasStation",
        "MKPOICategoryHotel", "MKPOICategoryFoodMarket", "MKPOICategoryBakery", "MKPOICategoryPharmacy",
        "MKPOICategoryPostOffice", "MKPOICategoryNightlife", "MKPOICategoryLaundry", "MKPOICategoryEVCharger",
        "MKPOICategoryRestroom", "MKPOICategoryFitnessCenter", "MKPOICategorySchool", "MKPOICategoryHospital",
        "MKPOICategoryPolice", "MKPOICategoryCarRental", "MKPOICategoryAirport", "MKPOICategoryBrewery",
        "MKPOICategoryWinery", "MKPOICategoryUniversity", "MKPOICategoryFireStation",
    ]

    static func isPark(_ poi: POI) -> Bool { ["park", "garden"].contains(poi.tags["leisure"] ?? "") }
    static func isWorship(_ poi: POI) -> Bool { poi.tags["amenity"] == "place_of_worship" }

    /// Area of the sight's outer rings in m² (flat earth; fine at sight scale).
    public static func areaM2(_ poi: POI) -> Double {
        Polygon.ringAreaDeg(poi.rings) * 111_320 * 111_320 * cos(poi.lat * .pi / 180)
    }

    /// How far Apple's coordinate may be from ours: a point sight or a small park must be close;
    /// a big area's Apple pin can sit anywhere on its grounds.
    public static func maxDistance(for poi: POI) -> Double {
        if poi.rings.isEmpty { return 60 }
        if isPark(poi) && areaM2(poi) < 5_000 { return 60 }
        return 150
    }

    public static func accept(poi: POI, resultName: String, distance: Double, categoryRaw: String?) -> Bool {
        guard distance <= maxDistance(for: poi) else { return false }
        if let c = categoryRaw, blockedCategories.contains(c) { return false }
        let n = resultName.lowercased()
        if isPark(poi) {
            if categoryRaw == "MKPOICategoryPark" { return true }      // 木倉町広場 → "Kiguracho Hiroba", 4 m
            return ["park", "garden", "green", "公園", "緑地", "庭園", "園"].contains { n.contains($0) }
        }
        if isWorship(poi) {
            if distance <= 30 { return true }
            return ["temple", "shrine", "-ji", "jinja", "church", "寺", "神社", "宮", "院", "社"].contains { n.contains($0) }
        }
        return true
    }
}
