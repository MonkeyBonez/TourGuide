import Foundation
import SwiftUI
import Translation
import TourGuideCore

/// Japanese → English on device (Apple's Translation framework). The framework only hands out a
/// session through SwiftUI's `.translationTask`, and its one-time language download is a sheet
/// on that view, so the store is driven from `ContentView`. Off until the user turns it on
/// (Settings), because that download is ~4 minutes the first time (measured 6 Oct 2026).
@MainActor
final class TranslationStore: ObservableObject {
    @Published var translated: [String: String] = [:]
    @Published var configuration: TranslationSession.Configuration?
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "translate"); if enabled { kick() } } }
    @Published var status = ""
    private var pending: [String] = []
    private let cache = DiskCache.named("translations", ttl: .infinity)

    init() {
        enabled = UserDefaults.standard.bool(forKey: "translate")
        if let saved = cache.load([String: String].self, key: "ja-en") { translated = saved }
    }

    /// Queue strings; only Japanese ones not yet translated are kept.
    func request(_ texts: [String]) {
        let new = texts.filter { POI.isJapanese($0) && translated[$0] == nil && !pending.contains($0) }
        guard !new.isEmpty else { return }
        pending += new
        if enabled { kick() }
    }

    private func kick() {
        guard !pending.isEmpty else { return }
        if configuration == nil {
            configuration = .init(source: Locale.Language(identifier: "ja"), target: Locale.Language(identifier: "en"))
        } else {
            configuration?.invalidate()
        }
    }

    func run(_ session: TranslationSession) async {
        guard enabled, !pending.isEmpty else { return }
        let batch = pending; pending = []
        do {
            status = "Preparing Japanese (one-time download)…"
            try await session.prepareTranslation()
            status = "Translating \(batch.count)…"
            let requests = batch.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
            for r in try await session.translations(from: requests) {
                if let id = r.clientIdentifier, let i = Int(id) { translated[batch[i]] = r.targetText }
            }
            cache.store(translated, key: "ja-en")
            status = "Translated \(batch.count) on this iPhone"
        } catch {
            pending = batch + pending
            status = "Translation unavailable: \(error.localizedDescription)"
        }
    }
}
