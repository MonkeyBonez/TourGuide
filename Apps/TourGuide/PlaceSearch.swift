import Foundation
import MapKit

struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D

    static func == (l: SearchResult, r: SearchResult) -> Bool { l.id == r.id }
}

@MainActor
final class PlaceSearch: NSObject, ObservableObject {
    @Published var query: String = "" { didSet { completer.queryFragment = query } }
    @Published var suggestions: [MKLocalSearchCompletion] = []
    @Published var isResolving = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func setRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> SearchResult? {
        isResolving = true
        defer { isResolving = false }
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return SearchResult(name: completion.title.isEmpty ? (item.name ?? "Destination") : completion.title,
                     subtitle: completion.subtitle,
                     coordinate: item.location.coordinate)
    }

    /// Free-text search used when the user hits return without picking a suggestion.
    func searchText(_ text: String, near region: MKCoordinateRegion) async -> SearchResult? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = region
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return SearchResult(name: item.name ?? text,
                     subtitle: item.address?.shortAddress ?? "",
                     coordinate: item.location.coordinate)
    }
}

extension PlaceSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.suggestions = Array(results.prefix(12)) }
    }
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.suggestions = [] }
    }
}
