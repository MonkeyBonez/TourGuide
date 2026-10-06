import Foundation
import XCTest
@testable import TourGuideCore

/// One Kanazawa session per test run: building it scores 328 sights against 16 k edges.
enum Kanazawa {
    static let box: FetchBox = try! BundledFixtures.kanazawa()
    static let session: TourSession = try! TourSession(box: box)
    static let routes: [Double: TourRoute] = {
        var out: [Double: TourRoute] = [:]
        for s in [0.0, 0.1, 0.2, 0.3, 0.5] { out[s] = try! session.route(slack: s) }
        return out
    }()
    static func fixture(_ name: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/kanazawa")!
    }
    static func sight(_ name: String) -> Sight {
        session.scored.sights.first { $0.poi.name == name }!
    }
}
