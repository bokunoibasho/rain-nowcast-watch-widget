//
//  ContentView.swift
//  RainNowcastiOS
//
//  位置情報の許可状態に応じた案内と、出典表示を行う最小画面。
//

import SwiftUI
import CoreLocation

struct ContentView: View {
    @StateObject private var permission = LocationPermission()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "cloud.rain.fill")
                    .font(.system(size: 56))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)
                    .padding(.top, 24)

                Text("雨ナウキャスト")
                    .font(.title2.bold())

                Text("気象庁 高解像度降水ナウキャストで、\n現在地の今後1時間の雨をウィジェット表示します。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                statusSection
                    .padding(.top, 4)

                Divider().padding(.vertical, 8)

                // 出典表示（ライセンス・利用規約上の必須事項）
                Text("気象データ © Japan Meteorological Agency")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .onAppear { permission.requestIfNeeded() }
    }

    @ViewBuilder private var statusSection: some View {
        switch permission.status {
        case .notDetermined:
            Button("位置情報を許可") { permission.requestIfNeeded() }
                .buttonStyle(.borderedProminent)

        case .authorizedWhenInUse, .authorizedAlways:
            Label("位置情報 許可済み", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline)
            Text("ホーム画面を長押し →「＋」→「雨ナウキャスト」でウィジェットを追加してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

        case .denied, .restricted:
            Label("位置情報が未許可です", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
            Text("「設定 > プライバシーとセキュリティ > 位置情報サービス」から、このアプリの位置情報を許可してください。")
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
