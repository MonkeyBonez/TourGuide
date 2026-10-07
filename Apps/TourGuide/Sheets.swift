import SwiftUI
import MapKit
import TourGuideCore

struct SearchSheet: View {
    @ObservedObject var model: AppModel
    @StateObject private var search = PlaceSearch()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.searchingStart {
                    Button { model.setStart(nil); dismiss() } label: { Label("My location", systemImage: "location.fill") }
                }
                ForEach(search.suggestions, id: \.self) { s in
                    Button {
                        Task { if let p = await search.resolve(s) { choose(p) } }
                    } label: {
                        VStack(alignment: .leading) { Text(s.title); Text(s.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: model.searchingStart ? "Start from" : "Walk to")
            .onSubmit(of: .search) {
                Task { if let p = await search.searchText(search.query, near: region) { choose(p) } }
            }
            .navigationTitle(model.searchingStart ? "Start" : "Destination")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { search.setRegion(region) }
        }
    }

    private var region: MKCoordinateRegion {
        MKCoordinateRegion(center: model.effectiveStart ?? AppModel.fallbackCenter, latitudinalMeters: 8000, longitudinalMeters: 8000)
    }

    private func choose(_ r: SearchResult) {
        let p = Place(name: r.name, lat: r.coordinate.latitude, lon: r.coordinate.longitude)
        model.searchingStart ? model.setStart(p) : model.setDestination(p)
        dismiss()
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var translations: TranslationStore
    @ObservedObject var appleNames: AppleNameStore
    @ObservedObject var walkBlurbs: WalkDescriptionStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var keyStatus = ""
    @AppStorage("openaiModel") private var openaiModel = "gpt-5"

    var body: some View {
        NavigationStack {
            Form {
                Section("Walk") {
                    Picker("Pace", selection: Binding(get: { model.pace }, set: { model.setPace($0) })) {
                        Text("Relaxed").tag(1.1); Text("Normal").tag(1.4); Text("Brisk").tag(1.7)
                    }
                    Picker("Slider's left end", selection: Binding(get: { model.maxSlack }, set: { model.setMaxSlack($0) })) {
                        Text("+25 % distance").tag(0.25); Text("+50 % distance").tag(0.5); Text("+100 % distance").tag(1.0)
                    }
                    Picker("Long-press sets", selection: $model.longPressTarget) {
                        ForEach(AppModel.LongPressTarget.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Button("Load the Kanazawa demo (no network)") { model.loadDemo(); dismiss() }
                        .accessibilityIdentifier("settingsDemo")
                }
                Section {
                    Toggle("Name walks on this iPhone", isOn: $walkBlurbs.enabled)
                    if !walkBlurbs.footer.isEmpty { Text(walkBlurbs.footer).font(.caption).foregroundStyle(.secondary) }
                } header: { Text("Apple Intelligence") } footer: {
                    Text("Titles for \"Compare walks\", written on this iPhone. Nothing is sent anywhere; no key needed.")
                }
                Section {
                    Toggle("Apple Maps' English names", isOn: $appleNames.enabled)
                    Toggle("Translate Japanese text", isOn: $translations.enabled)
                    if !translations.status.isEmpty { Text(translations.status).font(.caption).foregroundStyle(.secondary) }
                } header: { Text("Translation") } footer: {
                    Text("Names: Apple Maps' English name for a place when it clearly is the same place. Other text: on this iPhone, with Apple's Translation; the first time, iOS downloads Japanese (a few minutes). Translated text is marked.")
                }
                Section {
                    SecureField("sk-…", text: $key).textContentType(.password).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("apiKeyField")
                    HStack {
                        Button("Save") { KeychainService.saveAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines)); keyStatus = "Saved to the Keychain."; key = "" }
                            .disabled(key.isEmpty)
                        Spacer()
                        Button("Test") {
                            keyStatus = "Testing…"
                            Task {
                                let k = key.isEmpty ? (KeychainService.apiKey() ?? "") : key
                                keyStatus = await OpenAIClient(apiKey: k).testKey() ? "The key works." : "OpenAI didn't accept that key."
                            }
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { KeychainService.deleteAPIKey(); keyStatus = "Removed." }
                    }
                    .buttonStyle(.borderless)
                    Picker("Model", selection: $openaiModel) { Text("GPT-5").tag("gpt-5"); Text("GPT-5 mini").tag("gpt-5-mini") }
                    Text(keyStatus.isEmpty ? (KeychainService.apiKey() == nil ? "No key saved." : "A key is saved.") : keyStatus)
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Photo answers (OpenAI)") } footer: {
                    Text("Your own API key, kept in this iPhone's Keychain and sent only to OpenAI. Usage is billed to your OpenAI account.")
                }
                Section("Developer") {
                    Toggle("Show timings", isOn: Binding(get: { model.showTimings }, set: { model.setShowTimings($0) }))
                    Button("Data and credits") { model.showAttribution = true; dismiss() }
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct AttributionView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                credit("Streets and places", "© OpenStreetMap contributors, Open Database License (ODbL 1.0). Fetched live through public Overpass servers.", "https://www.openstreetmap.org/copyright")
                credit("Fame and facts", "Wikidata, CC0.", "https://www.wikidata.org")
                credit("Card text", "Wikipedia contributors, CC BY-SA 4.0. Each card links to its article.", "https://en.wikipedia.org/wiki/Wikipedia:Copyrights")
                credit("Card photos", "Wikimedia Commons. Each photo's author and licence are on its Commons page.", "https://commons.wikimedia.org")
                credit("Map, place names and place cards", "Apple Maps.", nil)
                credit("Routing", "Our own corridor router (the Like Water engine), not Apple's or Google's.", "https://github.com/MonkeyBonez/TourGuide")
                credit("Translation", "Apple's on-device Translation. Translated text is marked.", nil)
                credit("Walk titles", "Apple Intelligence, written on this iPhone; nothing is sent anywhere.", nil)
            }
            .navigationTitle("Data and credits").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    func credit(_ title: String, _ body: String, _ link: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).font(.subheadline)
            if let link, let url = URL(string: link) { Link(link, destination: url).font(.caption) }
        }
        .padding(.vertical, 2)
    }
}

/// A sight's detail: Apple's Place Card when Apple knows the place (PRD §8.10), else ours.
struct PlaceCardSheet: View {
    let card: SightCard
    let content: CardContent?
    @ObservedObject var translations: TranslationStore
    var appleName: String? = nil
    var appleItem: MKMapItem? = nil
    @State private var item: MKMapItem?
    @State private var searched = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let item {
                MapItemDetail(item: item).ignoresSafeArea()
            } else {
                NavigationStack {
                    List {
                        Section {
                            NameLine(poi: card.poi, translations: translations, appleName: appleName, font: .title3.weight(.semibold))
                            Text([card.poi.kindLabel, card.poi.denomination].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            if let d = content?.description ?? card.poi.wdDescription { Text(d) }
                            if let ex = content?.extract { Text(translations.translated[ex] ?? ex).font(.callout) }
                        }
                        Section {
                            ForEach((card.poi.allTags ?? [:]).filter { ["opening_hours", "fee", "website", "phone", "inscription", "start_date"].contains($0.key) }.sorted { $0.key < $1.key }, id: \.key) { k, v in
                                LabeledContent(k.replacingOccurrences(of: "_", with: " ").capitalized, value: v)
                            }
                            Link("Open on OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/\(card.poi.id)")!)
                            if let u = content?.wikipediaURL.flatMap(URL.init) { Link("Wikipedia", destination: u) }
                        }
                        if searched { Section { Text("Apple Maps has no card for this place.").font(.caption).foregroundStyle(.secondary) } }
                    }
                    .navigationTitle(card.poi.displayName).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                }
            }
        }
        .task { await findAppleItem() }
        .presentationDetents([.medium, .large])
    }

    /// Apple has no place-of-worship category to filter by, so search by name near the pin and
    /// keep the nearest result within 150 m.
    private func findAppleItem() async {
        defer { searched = true }
        if let appleItem { item = appleItem; return }
        let here = CLLocation(latitude: card.poi.lat, longitude: card.poi.lon)
        for q in [card.poi.nameLocal, card.poi.name].compactMap({ $0 }) {
            let r = MKLocalSearch.Request()
            r.naturalLanguageQuery = q
            r.region = MKCoordinateRegion(center: card.coordinate, latitudinalMeters: 300, longitudinalMeters: 300)
            guard let items = try? await MKLocalSearch(request: r).start().mapItems else { continue }
            if let best = items.min(by: { $0.location.distance(from: here) < $1.location.distance(from: here) }),
               best.location.distance(from: here) <= 150 {
                item = best; return
            }
        }
    }
}

struct MapItemDetail: UIViewControllerRepresentable {
    let item: MKMapItem
    func makeUIViewController(context: Context) -> MKMapItemDetailViewController { MKMapItemDetailViewController(mapItem: item, displaysMap: false) }
    func updateUIViewController(_ vc: MKMapItemDetailViewController, context: Context) {}
}
