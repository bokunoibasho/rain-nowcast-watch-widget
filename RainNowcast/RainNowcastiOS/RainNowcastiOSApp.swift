//
//  RainNowcastiOSApp.swift
//  iOS アプリ本体（位置情報の許可リクエスト＋出典表示を担当）
//
//  役割:
//   - 起動時に「使用中のみ許可（When In Use）」を一度リクエストする。
//     これを先に通しておかないと、ウィジェット拡張が現在地を取得できない。
//   - 出典「気象データ © Japan Meteorological Agency」を画面に表示する。
//
//  ※ このアプリ自身は最小限。降水バーグラフの本体はホーム画面ウィジェット
//    （RainNowcastiOSWidget ターゲット）側に実装している。
//

import SwiftUI
import CoreLocation
import Combine   // ObservableObject / @Published のために必要

@main
struct RainNowcastiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - 位置情報の許可管理

/// 本体アプリで「使用中のみ許可」を一度リクエストするためのヘルパ。
/// ウィジェット側の WidgetLocation とは別物（あちらは取得専用）。
final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    /// 未決定なら「使用中のみ許可」をリクエストする。
    func requestIfNeeded() {
        guard status == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
    }
}
