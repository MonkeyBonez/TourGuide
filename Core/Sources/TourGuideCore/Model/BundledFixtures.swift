import Foundation

/// The 6 Oct 2026 Kanazawa snapshot (Kanazawa Station → Murataya Ryokan), tiered and matched.
/// The app's offline demo, the UI tests' data, and the compare tool's oracle.
public enum BundledFixtures {
    public static let kanazawaStart = Place(name: "Kanazawa Station", lat: 36.5781, lon: 136.6480)
    public static let kanazawaEnd = Place(name: "Murataya Ryokan", lat: 36.5597, lon: 136.6534)

    public static func kanazawa() throws -> FetchBox {
        try load("kanazawa")
    }

    /// A synthetic street-visibility scenario, used only by deterministic tests.
    public static func visibility() throws -> FetchBox {
        try load("visibility")
    }

    private static func load(_ name: String) throws -> FetchBox {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(FetchBox.self, from: Data(contentsOf: url))
    }
}
