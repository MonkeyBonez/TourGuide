import SwiftUI
import MapKit
import Translation
import TourGuideCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Inner(model: model, translations: model.translations, appleNames: model.appleNames, walkBlurbs: model.walkBlurbs)
    }

    private struct Inner: View {
        @ObservedObject var model: AppModel
        @ObservedObject var translations: TranslationStore
        @ObservedObject var appleNames: AppleNameStore
        @ObservedObject var walkBlurbs: WalkDescriptionStore

        var body: some View {
            ZStack(alignment: .top) {
                TourMapView(model: model).ignoresSafeArea()
                VStack(spacing: 8) {
                    topBar
                    if let b = model.banner { BannerView(banner: b, retry: { model.plan() }) }
                    Spacer()
                    bottomPanel
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .onAppear { if !model.isFixture { model.location.start() } }
            .onReceive(model.location.$coordinate) { c in
                if c != nil, case .waiting = model.phase { model.plan() }
            }
            .translationTask(translations.configuration) { session in await translations.run(session) }
            .sheet(isPresented: $model.showSearch) { SearchSheet(model: model) }
            .sheet(isPresented: $model.showSettings) { SettingsSheet(model: model, translations: translations, appleNames: appleNames, walkBlurbs: walkBlurbs) }
            .sheet(isPresented: $model.showAttribution) { AttributionView() }
            .sheet(isPresented: $model.showCompare) { CompareWalksSheet(model: model, store: walkBlurbs) }
            .sheet(item: $model.placeCard) { card in PlaceCardSheet(card: card, content: model.cardContent[card.id], translations: translations,
                                                                         appleName: appleNames.names[card.id], appleItem: appleNames.items[card.id]) }
            .fullScreenCover(isPresented: $model.showPhoto) { PhotoView(model: model) }
        }

        // MARK: Top: where from, where to

        private var topBar: some View {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Button { model.searchingStart = true; model.showSearch = true } label: {
                        Label(model.origin?.name ?? "My location", systemImage: "figure.walk")
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .accessibilityIdentifier("startButton")
                    Button { model.searchingStart = false; model.showSearch = true } label: {
                        Label(model.destination?.name ?? "Where to?", systemImage: "magnifyingglass")
                            .font(.headline).foregroundStyle(.primary).lineLimit(1)
                    }
                    .accessibilityIdentifier("searchButton")
                }
                Spacer(minLength: 0)
                Button { model.showSettings = true } label: { Image(systemName: "gearshape").font(.title3) }
                    .accessibilityIdentifier("settingsButton")
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassEffect(in: .rect(cornerRadius: 18))
        }

        // MARK: Bottom: readout, slider, cards

        @ViewBuilder private var bottomPanel: some View {
            VStack(alignment: .leading, spacing: 10) {
                if model.info != nil {
                    HStack {
                        Text(model.routeReadout).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .accessibilityIdentifier("routeReadout")
                        Spacer(minLength: 4)
                        if walkBlurbs.walks.count > 1 {
                            Button { model.showCompare = true } label: {
                                Label("\(walkBlurbs.walks.count) walks", systemImage: "arrow.triangle.branch")
                                    .font(.footnote.weight(.semibold)).lineLimit(1)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityIdentifier("compareWalks")
                        }
                        Button { model.fitRequest += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .accessibilityLabel("Show the whole walk")
                    }
                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { model.sliderPosition }, set: { model.setSliderPosition($0) }), in: 0...1, step: 0.05)
                            .accessibilityIdentifier("slackSlider")
                            .accessibilityLabel("Time versus sights")
                            .accessibilityValue(model.routeReadout)
                        HStack {
                            Text("More sights · " + model.maxCaption); Spacer(); Text(model.directCaption)
                        }
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    CardsRow(model: model, translations: translations, appleNames: appleNames)
                    if model.showTimings {
                        Text(model.timingsText).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            .accessibilityIdentifier("timings")
                    }
                } else if model.fastSnapshot != nil {
                    HStack {
                        Text(model.fastReadout).font(.subheadline.weight(.semibold)).monospacedDigit()
                            .accessibilityIdentifier("fastReadout")
                        Spacer()
                        Button { model.fitRequest += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .accessibilityLabel("Show the whole walk")
                    }
                } else if model.destination == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Walk somewhere the interesting way").font(.headline)
                        Text("Search for a destination, or long-press the map. The slider then trades minutes for sights.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Try the Kanazawa demo") { model.loadDemo() }.font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("demoButton")
                    }
                }
                HStack {
                    Button { model.showAttribution = true } label: {
                        Text("© OpenStreetMap contributors · Wikipedia").font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("attributionButton")
                    Spacer()
                    Button { model.showPhoto = true } label: {
                        Label("What's this?", systemImage: "camera.fill").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("cameraButton")
                }
            }
            .padding(14)
            .glassEffect(in: .rect(cornerRadius: 24))
        }
    }
}

struct BannerView: View {
    let banner: AppModel.Banner
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
            Text(text).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            if case .fetchFailed = banner {
                Button("Retry", action: retry).font(.footnote.weight(.semibold)).accessibilityIdentifier("retryButton")
            }
        }
        .padding(12)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var text: String {
        switch banner {
        case .waitingForLocation: return "Waiting for your location. Long-press the map to set a start instead."
        case .fetching(let s): return s
        case .fetchFailed(let s, let keepingFast):
            return keepingFast ? "\(s) Showing the fastest walk; sights couldn't be loaded." : "\(s) No route without the street map."
        case .degraded(let s): return s
        case .noRoute(let s): return s
        }
    }
    private var identifier: String {
        switch banner {
        case .waitingForLocation: return "bannerWaiting"
        case .fetching: return "bannerFetching"
        case .fetchFailed: return "bannerFailed"
        case .degraded: return "bannerDegraded"
        case .noRoute: return "bannerNoRoute"
        }
    }
    private var tint: Color {
        switch banner { case .fetchFailed, .noRoute: return .red; case .degraded, .waitingForLocation: return .orange; case .fetching: return .blue }
    }
    @ViewBuilder private var icon: some View {
        if case .fetching = banner { ProgressView().controlSize(.small) }
        else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tint) }
    }
}
