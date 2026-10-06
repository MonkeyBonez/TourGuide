import Foundation

public extension POI {
    /// What kind of place this is, in words a tourist uses.
    var kindLabel: String {
        let t = tags
        if t["amenity"] == "place_of_worship" {
            let base: String
            switch t["religion"] {
            case "shinto": base = "Shinto shrine"
            case "buddhist": base = "Buddhist temple"
            case "christian": base = "Church"
            case let r? where r.contains("shinto") && r.contains("buddhist"): base = "Shrine and temple"
            default: base = "Place of worship"
            }
            return base
        }
        if t["historic"] == "castle" || t["building"] == "castle" { return "Castle" }
        switch t["tourism"] {
        case "museum": return "Museum"
        case "gallery": return "Gallery"
        case "artwork": return "Artwork"
        case "viewpoint": return "Viewpoint"
        default: break
        }
        if let h = t["historic"] {
            switch h {
            case "memorial": return "Memorial"
            case "wayside_shrine": return "Wayside shrine"
            case "archaeological_site": return "Archaeological site"
            case "district": return "Historic district"
            default: return "Historic " + h.replacingOccurrences(of: "_", with: " ")
            }
        }
        if t["tourism"] == "attraction" { return "Attraction" }
        switch t["leisure"] { case "garden": return "Garden"; case "park": return "Park"; default: break }
        if t["amenity"] == "marketplace" { return "Market" }
        if let b = t["building"], b != "yes" { return b.capitalized }
        return "Place"
    }

    /// The Buddhist school, when OSM knows it (`denomination=jodo_shinshu` → "Jodo Shinshu").
    var denomination: String? {
        allTags?["denomination"].map { $0.replacingOccurrences(of: "_", with: " ").capitalized }
    }

    /// True when a name has Japanese script in it (a translation candidate).
    static func isJapanese(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }
}
