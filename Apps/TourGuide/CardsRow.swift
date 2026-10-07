import SwiftUI
import TourGuideCore

/// One card per Tier-1 sight the route passes, in walking order (PRD §5.1); the Tier-2 places
/// the route passes behind a chip — they're what you stop at, but they don't pull the route.
struct CardsRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var translations: TranslationStore
    @ObservedObject var appleNames: AppleNameStore

    var body: some View {
        let cards = model.snapshot?.cards ?? []
        let named = model.snapshot?.named ?? []
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                        SightCardView(card: c, content: model.cardContent[c.id], translations: translations,
                                      appleName: appleNames.names[c.id], selected: model.selectedCard == c.id)
                            .id(c.id)
                            .onTapGesture { model.select(c) }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("card-\(i)")
                            .accessibilityLabel(c.poi.displayName)
                            .accessibilityAddTraits(.isButton)
                    }
                    if !named.isEmpty {
                        Button { withAnimation { model.showNamed.toggle() } } label: {
                            VStack(spacing: 4) {
                                Image(systemName: model.showNamed ? "chevron.left" : "mappin.and.ellipse").font(.title3)
                                Text(model.showNamed ? "Hide" : "+\(named.count) named places").font(.caption).multilineTextAlignment(.center)
                            }
                            .frame(width: 92, height: 120)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("namedToggle")
                        if model.showNamed {
                            ForEach(named) { c in
                                NamedPlaceView(card: c, translations: translations, appleName: appleNames.names[c.id],
                                               selected: model.selectedCard == c.id)
                                    .onTapGesture { model.select(c) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("named-\(c.id)")
                            }
                        }
                    }
                    if cards.isEmpty && named.isEmpty {
                        Text("Nothing mapped along this walk. Move the slider left for more.")
                            .font(.footnote).foregroundStyle(.secondary).frame(width: 260, height: 60)
                    }
                }
            }
            .frame(height: cards.isEmpty && named.isEmpty ? 60 : 196)
            .onChange(of: model.selectedCard) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

struct SightCardView: View {
    let card: SightCard
    let content: CardContent?
    @ObservedObject var translations: TranslationStore
    var appleName: String? = nil
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let s = content?.imageURL, let url = URL(string: s) {
                    AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Image(systemName: TourMapView.Coordinator.glyph(card)).font(.title).foregroundStyle(.secondary)
                }
            }
            .frame(width: 260, height: 74).clipped()
            VStack(alignment: .leading, spacing: 3) {
                NameLine(poi: card.poi, translations: translations, appleName: appleName)
                Text(meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                extract.font(.caption).lineLimit(3)
                if let hours = content?.osm["opening_hours"] {
                    Label(hours, systemImage: "clock").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(width: 260, height: 190, alignment: .top)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.indigo : .clear, lineWidth: 2))
    }

    private var meta: String {
        var parts = [card.poi.kindLabel]
        if let y = content?.inception, !y.isEmpty { parts.append("est. \(y)") }
        if let n = card.poi.sitelinks, n > 0 { parts.append("\(n) language\(n == 1 ? "" : "s")") }
        parts.append(String(format: "%.1f km in", card.alongMetres / 1000))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var extract: some View {
        if let ex = content?.extract {
            if content?.extractLang != "en", let t = translations.translated[ex] {
                Text(Image(systemName: "character.bubble")) + Text(" " + t)
            } else { Text(ex) }
        } else if let d = content?.description ?? card.poi.wdDescription {
            Text(d).foregroundStyle(.secondary)
        } else {
            Text(" ")
        }
    }
}

/// Name precedence (PRD §8.10–11): OSM name:en, else Apple Maps' English name, else the
/// on-device translation (marked), else local.
struct NameLine: View {
    let poi: POI
    @ObservedObject var translations: TranslationStore
    var appleName: String? = nil
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if POI.isJapanese(poi.displayName), let a = appleName {
                Text(a).font(font).lineLimit(1)
                Text(poi.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if POI.isJapanese(poi.displayName), let t = translations.translated[poi.displayName] {
                (Text(t) + Text(" ") + Text(Image(systemName: "character.bubble")).font(.caption2)).font(font).lineLimit(1)
                Text(poi.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(poi.displayName).font(font).lineLimit(1)
                if let local = poi.nameLocal, local != poi.displayName {
                    Text(local).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct NamedPlaceView: View {
    let card: SightCard
    @ObservedObject var translations: TranslationStore
    var appleName: String? = nil
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: TourMapView.Coordinator.glyph(card)).foregroundStyle(.orange)
            NameLine(poi: card.poi, translations: translations, appleName: appleName, font: .footnote.weight(.semibold))
            Text([card.poi.kindLabel, card.poi.denomination].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            Text(String(format: "%.1f km in · tap for Apple's card", card.alongMetres / 1000)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 170, height: 120, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.orange : .clear, lineWidth: 2))
    }
}
