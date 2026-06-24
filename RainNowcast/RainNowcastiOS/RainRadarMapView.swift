//
//  RainRadarMapView.swift
//  RainNowcastiOS
//
//  「降水」レーダーマップ。Apple Maps を土台に、気象庁 高解像度降水ナウキャスト(hrpns) の
//  タイルをオーバーレイ表示する。タイル URL は basetime/validtime と MapKit が渡す z/x/y から
//  組み立てる（エンジンの URL 形と同じ）。SwiftUI の Map はタイルオーバーレイ非対応のため、
//  UIViewRepresentable で MKMapView をラップする。
//

import SwiftUI
import MapKit
import CoreLocation

struct RainRadarMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let basetime: String
    let validtime: String

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.overrideUserInterfaceStyle = .dark   // SwiftUI の preferredColorScheme は UIKit に伝わらないため明示
        map.setRegion(MKCoordinateRegion(center: coordinate,
                                         latitudinalMeters: 60_000,
                                         longitudinalMeters: 60_000),
                      animated: false)
        context.coordinator.applyOverlay(to: map, basetime: basetime, validtime: validtime)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.applyOverlay(to: map, basetime: basetime, validtime: validtime)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var currentKey: String?

        /// フレーム（basetime+validtime）が変わったときだけタイルオーバーレイを貼り替える。
        func applyOverlay(to map: MKMapView, basetime: String, validtime: String) {
            guard !basetime.isEmpty, !validtime.isEmpty else { return }
            let key = basetime + "/" + validtime
            guard key != currentKey else { return }
            currentKey = key

            map.removeOverlays(map.overlays)
            let overlay = JMATileOverlay(basetime: basetime, validtime: validtime)
            overlay.canReplaceMapContent = false
            overlay.minimumZ = 4
            overlay.maximumZ = 10                 // hrpns の最大ズーム。超えると MapKit が拡大表示。
            map.addOverlay(overlay, level: .aboveRoads)   // 地名ラベルはタイルの上に残す
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                renderer.alpha = 0.6
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

/// 気象庁 hrpns タイル（…/nowc/{basetime}/none/{validtime}/surf/hrpns/{z}/{x}/{y}.png）。
final class JMATileOverlay: MKTileOverlay {
    private let basetime: String
    private let validtime: String

    init(basetime: String, validtime: String) {
        self.basetime = basetime
        self.validtime = validtime
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 256, height: 256)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        URL(string: "https://www.jma.go.jp/bosai/jmatile/data/nowc/\(basetime)/none/\(validtime)/surf/hrpns/\(path.z)/\(path.x)/\(path.y).png")!
    }
}
