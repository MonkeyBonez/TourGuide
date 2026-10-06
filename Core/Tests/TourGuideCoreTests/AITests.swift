import XCTest
@testable import TourGuideCore

final class OpenAIClientTests: XCTestCase {
    let context = TravelerContext(from: "Kanazawa Station", to: "Murataya Ryokan",
                                  nearbySights: ["Tsuzumi-mon Gate (Attraction, 40 m)"], question: "why is it shaped like that?",
                                  lat: 36.5781, lon: 136.6480)

    func testRequestCarriesPhotoContextAndKeyOnlyInTheHeader() throws {
        let r = try OpenAIClient(apiKey: "test-key-not-real", model: "gpt-5").request(jpeg: Data([0xFF, 0xD8]), context: context)
        XCTAssertEqual(r.url, OpenAIClient.endpoint)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer test-key-not-real")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "gpt-5")
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertTrue((messages[0]["content"] as! String).contains("answer it directly"))
        let parts = messages[1]["content"] as! [[String: Any]]
        let text = parts[0]["text"] as! String
        XCTAssertTrue(text.contains("walking from Kanazawa Station to Murataya Ryokan"))
        XCTAssertTrue(text.contains("Tsuzumi-mon Gate"))
        XCTAssertTrue(text.contains("why is it shaped like that?"))
        XCTAssertTrue(((parts[1]["image_url"] as! [String: Any])["url"] as! String).hasPrefix("data:image/jpeg;base64,"))
        XCTAssertFalse(String(decoding: r.httpBody!, as: UTF8.self).contains("test-key-not-real"))
    }

    func testNoQuestionAsksForWhatItIs() {
        XCTAssertTrue(TourPrompt.system(hasQuestion: false).contains("what it is and why it matters"))
        XCTAssertTrue(TourPrompt.user(TravelerContext()).hasSuffix("Explain what they are looking at."))
    }

    func testAnswerParsingAndErrors() async throws {
        let t = FixtureTransport(directory: URL(fileURLWithPath: "/nonexistent"))
        let reply = #"{"choices":[{"message":{"content":"{\"title\":\"Tsuzumi-mon Gate\",\"text\":\"A wooden gate shaped like a hand drum.\"}"}}]}"#
        t.script(host: "api.openai.com", [(200, Data(reply.utf8)), (401, Data()), (429, Data())])
        let client = OpenAIClient(apiKey: "k", transport: t)
        let a = try await client.describe(jpeg: Data([1]), context: context)
        XCTAssertEqual(a, TourAnswer(title: "Tsuzumi-mon Gate", text: "A wooden gate shaped like a hand drum."))
        do { _ = try await client.describe(jpeg: Data([1]), context: context); XCTFail() } catch { XCTAssertEqual(error as? OpenAIClient.Failure, .badKey) }
        do { _ = try await client.describe(jpeg: Data([1]), context: context); XCTFail() } catch { XCTAssertEqual(error as? OpenAIClient.Failure, .rateLimited) }
        do { _ = try OpenAIClient(apiKey: "").request(jpeg: Data(), context: context); XCTFail() } catch { XCTAssertEqual(error as? OpenAIClient.Failure, .noKey) }
    }

    func testPlainTextAnswerStillReads() throws {
        let raw = #"{"choices":[{"message":{"content":"Just text."}}]}"#
        XCTAssertEqual(try OpenAIClient.parse(Data(raw.utf8)).text, "Just text.")
    }
}

final class SightKindTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(Kanazawa.sight("Oyama-jinja Shrine").poi.kindLabel, "Shinto shrine")
        XCTAssertEqual(Kanazawa.sight("Kenroku-en Park").poi.kindLabel, "Park")
        XCTAssertEqual(Kanazawa.sight("照教寺").poi.kindLabel, "Buddhist temple")
        XCTAssertTrue(POI.isJapanese("光善寺")); XCTAssertFalse(POI.isJapanese("Kozenji"))
    }
}
