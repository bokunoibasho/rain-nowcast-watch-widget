//
//  RainForecastView.swift
//  RainNowcastiOS
//
//  アプリのメイン画面。Apple 純正「天気」アプリの雨詳細画面に倣い、現在地の
//  ・地名ヘッダ ・「雨の予想です」＋要約文＋今後1時間の降水バーグラフ
//  ・時間別（雨のみ）の見通し ・降水レーダーマップ を縦に並べる。
//  データは RainForecastViewModel（= 共有エンジン RainNowcastEngine）から。
//  気温・天気・降水確率はエンジンに無いため表示しない（降水ナウキャストに特化）。
//

import SwiftUI
import CoreLocation

struct RainForecastView: View {
    @StateObject private var permission = LocationPermission()
    @State private var vm = RainForecastViewModel()

    var body: some View {
        ZStack {
            background
            content
        }
        .preferredColorScheme(.dark)
        .task {
            permission.requestIfNeeded()
            if isAuthorized, vm.state == .idle { await vm.load() }
        }
        .onChange(of: permission.status) { _, newValue in
            if newValue == .authorizedWhenInUse || newValue == .authorizedAlways {
                Task { await vm.load() }
            }
        }
    }

    private var isAuthorized: Bool {
        permission.status == .authorizedWhenInUse || permission.status == .authorizedAlways
    }

    private var background: some View {
        LinearGradient(colors: [Color(red: 0.09, green: 0.13, blue: 0.21),
                                Color(red: 0.17, green: 0.23, blue: 0.34)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    @ViewBuilder private var content: some View {
        switch permission.status {
        case .authorizedWhenInUse, .authorizedAlways:
            forecast
        case .notDetermined:
            permissionPrompt(message: "現在地の降水予報を表示するために、位置情報の利用を許可してください。",
                             showButton: true)
        default:
            permissionPrompt(message: "「設定 > プライバシーとセキュリティ > 位置情報サービス」から、このアプリの位置情報を許可してください。",
                             showButton: false)
        }
    }

    // MARK: - 予報本体

    private var forecast: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                rainCard
                if !vm.hourly.isEmpty { hourlyCard }
                if let coord = vm.coordinate, let frame = vm.frame {
                    radarCard(coord: coord, frame: frame)
                }
                attribution
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .refreshable { await vm.load() }
        .overlay {
            if vm.state == .loading && vm.steps.isEmpty && vm.hourly.isEmpty {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
    }

    // ヘッダ：地名＋方位アイコン（左）／天気アイコン（右）。気温は出さない。
    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 5) {
                Image(systemName: "location.fill").font(.subheadline)
                Text(vm.placeName ?? "現在地")
                    .font(.title.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer()
            Image(systemName: vm.glyph)
                .font(.system(size: 38))
                .symbolRenderingMode(.multicolor)
        }
        .foregroundStyle(.white)
    }

    // 「雨の予想です」＋要約文（＋ 1時間以内に雨があれば棒グラフと軸ラベル）
    private var rainCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(vm.showBars ? "雨の予想です" : "今後の天気",
                  systemImage: vm.showBars ? "cloud.rain" : "calendar")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))

            Text(summarySentence)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if vm.showBars {
                RainBarChart(values: vm.steps.map(\.mmPerHour), maxBarHeight: 60, spacing: 3)
                    .frame(maxWidth: .infinity)
                axisLabels
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var axisLabels: some View {
        HStack(spacing: 0) {
            ForEach(["現在", "10分", "20分", "30分", "40分", "50分"], id: \.self) { label in
                Text(label)
                    .frame(maxWidth: .infinity, alignment: label == "現在" ? .leading : .center)
            }
        }
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.55))
    }

    // 時間別（雨のみ）：rasrf の毎正時の雨/雨なしを横スクロールで。
    private var hourlyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("時間別（雨のみ）", systemImage: "clock")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(vm.hourly.indices, id: \.self) { i in
                        let step = vm.hourly[i]
                        VStack(spacing: 8) {
                            Text(Self.hourLabel(step.date))
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                            Image(systemName: step.isRaining ? "cloud.rain.fill" : "sun.max.fill")
                                .font(.title3)
                                .symbolRenderingMode(.multicolor)
                            Text(step.isRaining ? "雨" : "なし")
                                .font(.caption2).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // 降水レーダーマップ
    private func radarCard(coord: CLLocationCoordinate2D, frame: (basetime: String, validtime: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("降水", systemImage: "map")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            RainRadarMapView(coordinate: coord, basetime: frame.basetime, validtime: frame.validtime)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var attribution: some View {
        Text("気象データ © Japan Meteorological Agency")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 権限プロンプト

    private func permissionPrompt(message: String, showButton: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 52)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
            Text("雨ナウキャスト").font(.title2.bold()).foregroundStyle(.white)
            Text(message)
                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if showButton {
                Button("位置情報を許可") { permission.requestIfNeeded() }
                    .buttonStyle(.borderedProminent)
            }
            attribution.padding(.top, 8)
        }
        .padding(32)
    }

    // MARK: - 文言・整形

    // 要約＋見通し → 1行（句点付き）。分岐はウィジェットの summaryString と同じ。
    private var summarySentence: String {
        switch vm.summary {
        case .startsIn(let m, _):
            return m <= 0 ? "まもなく雨が降りそうです。" : "約\(m)分後に雨が降りそうです。"
        case .rainingStopsIn(let m, _):
            return m <= 0 ? "まもなく雨がやみそうです。" : "今後\(m)分ほどで雨がやみそうです。"
        case .rainingNoStop:
            return "今後1時間、雨が続くでしょう。"
        case .dryForHour:
            switch vm.outlook {
            case .rainExpected(let t):
                return "約\(Self.outlookHours(t))時間後に雨が降りそうです。"
            case .dryThrough:
                return "しばらく雨は降らないでしょう。"
            case .none:
                return "今後1時間、雨は降らないでしょう。"
            }
        case .unknown:
            return vm.state == .failed ? "降水データを取得できませんでした。" : "降水データを取得しています…"
        }
    }

    private static func outlookHours(_ t: Date) -> Int {
        max(1, Int((t.timeIntervalSinceNow / 3600).rounded()))
    }

    private static func hourLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "H時"
        f.locale = Locale(identifier: "ja_JP")
        return f.string(from: d)
    }
}

// 各セクションの角丸フロストカード。
private extension View {
    func cardStyle() -> some View {
        self.padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

#Preview {
    RainForecastView()
}
