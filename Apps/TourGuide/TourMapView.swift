import SwiftUI
import MapKit

/// The route, drawn on top with a white casing (LikeWater's `RouteLine`).
final class RouteLine: MKPolyline { var casing = false }
final class EndAnnotation: MKPointAnnotation { var isStart = false }
final class SightAnnotation: MKPointAnnotation {
    var card: SightCard!
    var passed = false
}

/// MKMapView wrapped for SwiftUI (LikeWater's `CorridorMapView` pattern: version counters say
/// what to redraw, so a slider move only swaps the route line and the sight pins).
struct TourMapView: UIViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
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
        if let (n, coord) = model.centerRequest, c.centered != n {
            c.centered = n
            let r = MKCoordinateRegion(center: coord, latitudinalMeters: 350, longitudinalMeters: 350)
            map.setRegion(r, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var model: AppModel
        var pins = -1, route = -1, fitted = 0, centered = 0
        init(model: AppModel) { self.model = model }

        @MainActor @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            model.handleLongPress(at: map.convert(g.location(in: map), toCoordinateFrom: map))
        }

        @MainActor func render(on map: MKMapView) {
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
            if let r = model.snapshot, r.coordinates.count > 1 {
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
            model.snapshot?.coordinates.forEach(include)
            model.snapshot?.cards.forEach { include($0.coordinate) }
            if let o = model.effectiveStart { include(o) }
            if let d = model.destination { include(CLLocationCoordinate2D(latitude: d.lat, longitude: d.lon)) }
            guard !rect.isNull else { return }
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 130, left: 40, bottom: 470, right: 40), animated: true)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
            if s.card.tier == 1 && s.passed {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "sight1", for: annotation) as! MKMarkerAnnotationView
                v.markerTintColor = .systemIndigo
                v.glyphImage = UIImage(systemName: Self.glyph(s.card))
                v.displayPriority = .defaultHigh
                v.canShowCallout = false
                return v
            }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "dot", for: annotation)
            let size: CGFloat = s.passed ? 12 : (s.card.tier == 1 ? 10 : 7)
            let color: UIColor = s.passed ? .systemOrange : (s.card.tier == 1 ? .systemIndigo.withAlphaComponent(0.45) : .systemGray.withAlphaComponent(0.6))
            v.image = UIGraphicsImageRenderer(size: CGSize(width: size + 2, height: size + 2)).image { _ in
                UIColor.white.setFill(); UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: size + 2, height: size + 2)).fill()
                color.setFill(); UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: size, height: size)).fill()
            }
            v.displayPriority = s.passed ? .defaultHigh : .defaultLow
            v.canShowCallout = false
            return v
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let s = view.annotation as? SightAnnotation else { return }
            mapView.deselectAnnotation(s, animated: false)
            Task { @MainActor in self.model.select(s.card) }
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
