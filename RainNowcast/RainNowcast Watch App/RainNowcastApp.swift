//
//  RainNowcastApp.swift
//  Watch App 本体（位置情報の許可リクエスト＋出典表示を担当）
//
//  役割:
//   - 起動時に「使用中のみ許可（When In Use）」を一度リクエストする。
//     これを先に通しておかないと、Widget 側の
//     CLLocationManager.isAuthorizedForWidgetUpdates が false のままになる。
//   - 出典「気象データ © Japan Meteorological Agency」を画面に表示する。
//
//  ── 事前設定（この Watch App 本体ターゲット側）──────────────
//  Info.plist:
//    NSLocationWhenInUseUsageDescription = "現在地の降水予報を表示するために使用します"
//
//  ※ このファイルは Watch App 本体ターゲットにのみ追加すること
//    （Widget Extension ターゲットには追加しない）。
//

import SwiftUI
import CoreLocation
import Combine   // ObservableObject / @Published のために必要

// MARK: - アプリ エントリポイント

@main
struct RainNowcastApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - 位置情報の許可管理（本体アプリ用）

/// 本体アプリで「使用中のみ許可」を一度リクエストするためのヘルパ。
/// Widget 側の WidgetLocation とは別物（あちらは取得専用）。
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

// MARK: - メイン画面

struct ContentView: View {
    @StateObject private var permission = LocationPermission()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "cloud.rain.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.hierarchical)

                Text("雨ナウキャスト")
                    .font(.headline)

                statusSection

                Divider().padding(.vertical, 2)

                // 出典表示
                Text("気象データ © Japan Meteorological Agency")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .onAppear {
            permission.requestIfNeeded()
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch permission.status {
        case .notDetermined:
            Button("位置情報を許可") {
                permission.requestIfNeeded()
            }
            .buttonStyle(.borderedProminent)

        case .authorizedWhenInUse, .authorizedAlways:
            Label("位置情報 許可済み", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.footnote)
            Text("文字盤のコンプリケーション、または Smart Stack に円形ウィジェットを追加してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

        case .denied, .restricted:
            Label("位置情報が未許可です", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
            Text("Watch の「設定 > プライバシーとセキュリティ > 位置情報サービス」から許可してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

        @unknown default:
            EmptyView()
        }
    }
}

#Preview {
    ContentView()
}
