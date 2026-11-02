import SwiftUI
import MapKit

/// The route, drawn on top with a white casing (LikeWater's `RouteLine`).
final class RouteLine: MKPolyline { var casing = false }
final class EndAnnotation: MKPointAnnotation { var isStart = false }
final class SightAnnotation: MKPointAnnotation {
    var card: SightCard!
    var passed = false
}
/// The tapped sight's grounds (one per OSM outer ring) or, for a point sight, a 60 m halo.
final class HighlightPolygon: MKPolygon { var tier = 1 }
final class HighlightCircle: MKCircle { var tier = 1 }

/// MKMapView wrapped for SwiftUI (LikeWater's `CorridorMapView` pattern: version counters say
/// what to redraw, so a slider move only swaps the route line and the sight pins).
struct TourMapView: UIViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = !model.isFixture
        map.showsCompass = true
        map.accessibilityIdentifier = "map"
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        press.minimumPressDuration = 0.35
        map.addGestureRecognizer(press)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "sight1")
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: "dot")
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "end")
        let start = model.effectiveStart ?? AppModel.fallbackCenter
        map.setRegion(MKCoordinateRegion(center: start, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.model = model
        if c.pins != model.pinsVersion || c.route != model.routeVersion {
            c.pins = model.pinsVersion; c.route = model.routeVersion
            c.render(on: map)
        }
        if c.fitted != model.fitRequest { c.fitted = model.fitRequest; c.fit(map: map) }
        if c.highlighted != model.highlightVersion {
            c.highlighted = model.highlightVersion
            c.applyHighlight(map, focus: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var model: AppModel
        var pins = -1, route = -1, fitted = 0, highlighted = 0
        /// True while `render` swaps annotations, so MapKit's deselects don't clear the selection.
        var rendering = false
        /// Room for the top bar (+ banner) and the bottom panel, which is short until the full
        /// corridor is in (fastest path only) and tall with the slider and cards.
        @MainActor var insets: UIEdgeInsets {
            UIEdgeInsets(top: model.banner == nil ? 130 : 220, left: 40, bottom: model.info == nil ? 200 : 470, right: 40)
        }
        init(model: AppModel) { self.model = model }

        @MainActor @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            model.handleLongPress(at: map.convert(g.location(in: map), toCoordinateFrom: map))
        }

        @MainActor func render(on map: MKMapView) {
            rendering = true
            defer { rendering = false; applyHighlight(map, focus: false) }
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
            var ends: [MKAnnotation] = []
            if let o = model.origin {
                let a = EndAnnotation(); a.isStart = true; a.title = o.name
                a.coordinate = CLLocationCoordinate2D(latitude: o.lat, longitude: o.lon); ends.append(a)
            }
            if let d = model.destination {
                let a = EndAnnotation(); a.title = d.name
                a.coordinate = CLLocationCoordinate2D(latitude: d.lat, longitude: d.lon); ends.append(a)
            }
            map.addAnnotations(ends)
            if let r = model.snapshot ?? model.fastSnapshot, r.coordinates.count > 1 {
                var cs = r.coordinates
                let casing = RouteLine(coordinates: &cs, count: cs.count); casing.casing = true
                map.addOverlay(casing, level: .aboveLabels)
                map.addOverlay(RouteLine(coordinates: &cs, count: cs.count), level: .aboveLabels)
            }
            guard let info = model.info else { return }
            let passed = Set((model.snapshot?.cards ?? []).map(\.id) + (model.snapshot?.named ?? []).map(\.id))
            let byID = Dictionary(((model.snapshot?.cards ?? []) + (model.snapshot?.named ?? [])).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var annotations: [SightAnnotation] = []
            for s in info.sights {
                let a = SightAnnotation()
                a.card = byID[s.id] ?? s
                a.passed = passed.contains(s.id)
                a.coordinate = s.coordinate
                a.title = s.poi.displayName
                a.subtitle = s.poi.kindLabel
                annotations.append(a)
            }
            map.addAnnotations(annotations)
        }

        @MainActor func fit(map: MKMapView) {
            var rect = MKMapRect.null
            func include(_ c: CLLocationCoordinate2D) {
                let p = MKMapPoint(c)
                rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
            }
            (model.snapshot ?? model.fastSnapshot)?.coordinates.forEach(include)
            model.snapshot?.cards.forEach { include($0.coordinate) }
            if let o = model.effectiveStart { include(o) }
            if let d = model.destination { include(CLLocationCoordinate2D(latitude: d.lat, longitude: d.lon)) }
            guard !rect.isNull else { return }
            map.setVisibleMapRect(rect, edgePadding: insets, animated: true)
        }

        /// Draw the selected sight's grounds and grow its pin; with `focus`, zoom to it.
        /// Called on a tap and after every `render` (which removes all overlays).
        @MainActor func applyHighlight(_ map: MKMapView, focus: Bool) {
            map.removeOverlays(map.overlays.filter { $0 is HighlightPolygon || $0 is HighlightCircle })
            let sights = map.annotations.compactMap { $0 as? SightAnnotation }
            let selectedID = model.selectedCard
            for a in sights { if let v = map.view(for: a) { style(v, a) } }
            guard let id = selectedID, let card = model.info?.sights.first(where: { $0.id == id }) else {
                rendering = true
                map.selectedAnnotations.filter { $0 is SightAnnotation }.forEach { map.deselectAnnotation($0, animated: false) }
                rendering = false
                return
            }
            var overlays: [MKOverlay] = []
            for ring in card.poi.rings where ring.count >= 3 {
                var cs = ring.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                let p = HighlightPolygon(coordinates: &cs, count: cs.count); p.tier = card.tier
                overlays.append(p)
            }
            if overlays.isEmpty {
                let c = HighlightCircle(center: card.coordinate, radius: 60); c.tier = card.tier
                overlays.append(c)
            }
            map.addOverlays(overlays, level: .aboveRoads)
            if let a = sights.first(where: { $0.card.id == id }), !map.selectedAnnotations.contains(where: { $0 === a }) {
                rendering = true
                map.selectAnnotation(a, animated: true)
                rendering = false
            }
            guard focus else { return }
            var rect = overlays.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
            rect = rect.union(MKCircle(center: card.coordinate, radius: 150).boundingMapRect)
            map.setVisibleMapRect(rect, edgePadding: insets, animated: true)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let p = overlay as? HighlightPolygon {
                let r = MKPolygonRenderer(polygon: p)
                let c: UIColor = p.tier == 1 ? .systemIndigo : .systemOrange
                r.fillColor = c.withAlphaComponent(0.18); r.strokeColor = c.withAlphaComponent(0.9); r.lineWidth = 2
                return r
            }
            if let h = overlay as? HighlightCircle {
                let r = MKCircleRenderer(circle: h)
                let c: UIColor = h.tier == 1 ? .systemIndigo : .systemOrange
                r.fillColor = c.withAlphaComponent(0.18); r.strokeColor = c.withAlphaComponent(0.9); r.lineWidth = 2
                r.lineDashPattern = [4, 4]
                return r
            }
            guard let line = overlay as? RouteLine else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.strokeColor = line.casing ? .white : .systemIndigo
            r.lineWidth = line.casing ? 11 : 6
            r.lineCap = .round; r.lineJoin = .round
            return r
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            if let end = annotation as? EndAnnotation {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "end", for: annotation) as! MKMarkerAnnotationView
                v.markerTintColor = end.isStart ? .systemGreen : .systemRed
                v.glyphImage = UIImage(systemName: end.isStart ? "figure.walk" : "flag.fill")
                v.displayPriority = .required
                v.zPriority = .max
                return v
            }
            guard let s = annotation as? SightAnnotation else { return nil }
            let id = s.card.tier == 1 && s.passed ? "sight1" : "dot"
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: id, for: annotation)
            MainActor.assumeIsolated { style(v, s) }
            return v
        }

        /// Pin look by tier / passed / selected. The selected pin is bigger and always on top.
        @MainActor func style(_ v: MKAnnotationView, _ s: SightAnnotation) {
            let selected = model.selectedCard == s.card.id
            v.canShowCallout = false
            v.accessibilityValue = selected ? "selected" : nil
            if let m = v as? MKMarkerAnnotationView {
                m.markerTintColor = .systemIndigo
                m.glyphImage = UIImage(systemName: Self.glyph(s.card))
                m.displayPriority = selected ? .required : .defaultHigh
                m.zPriority = selected ? .max : .defaultUnselected
                m.transform = selected ? CGAffineTransform(scaleX: 1.35, y: 1.35) : .identity
                return
            }
            var size: CGFloat = s.passed ? 12 : (s.card.tier == 1 ? 10 : 7)
            if selected { size *= 1.6 }
            let color: UIColor = s.passed || selected ? (s.card.tier == 1 && !s.passed ? .systemIndigo : .systemOrange)
                : (s.card.tier == 1 ? .systemIndigo.withAlphaComponent(0.45) : .systemGray.withAlphaComponent(0.6))
            let ring: CGFloat = selected ? 2 : 1
            v.image = UIGraphicsImageRenderer(size: CGSize(width: size + 2 * ring, height: size + 2 * ring)).image { _ in
                (selected ? color : UIColor.white).withAlphaComponent(1).setFill()
                UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size + 2 * ring, height: size + 2 * ring)).fill()
                UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: ring, y: ring, width: size, height: size)).fill()
                color.setFill(); UIBezierPath(ovalIn: CGRect(x: ring + 1, y: ring + 1, width: size - 2, height: size - 2)).fill()
            }
            v.displayPriority = selected ? .required : (s.passed ? .defaultHigh : .defaultLow)
            v.zPriority = selected ? .max : .defaultUnselected
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let s = view.annotation as? SightAnnotation else { return }
            MainActor.assumeIsolated {
                guard model.selectedCard != s.card.id else { return }
                model.select(s.card)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard view.annotation is SightAnnotation, !rendering else { return }
            // A tap on another pin deselects this one first; wait a beat and clear only if
            // nothing got selected instead.
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView, !self.rendering,
                      !mapView.selectedAnnotations.contains(where: { $0 is SightAnnotation }) else { return }
                MainActor.assumeIsolated { self.model.clearSelection() }
            }
        }

        static func glyph(_ c: SightCard) -> String {
            let t = c.poi.tags
            if t["amenity"] == "place_of_worship" { return t["religion"] == "shinto" ? "building.columns.fill" : "building.fill" }
            if t["leisure"] == "park" || t["leisure"] == "garden" { return "leaf.fill" }
            if t["tourism"] == "museum" || t["tourism"] == "gallery" { return "building.columns" }
            if t["historic"] == "castle" { return "building.2.fill" }
            return "star.fill"
        }
    }
}
