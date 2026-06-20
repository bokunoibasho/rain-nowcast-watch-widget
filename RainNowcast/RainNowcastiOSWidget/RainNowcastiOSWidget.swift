//
//  RainNowcastiOSWidget.swift
//  iOS ホーム画面ウィジェット（systemSmall）
//
//  現在地の今後1時間の降水強度を棒グラフで表示する。
//  Apple 純正「天気」アプリの「次の1時間の降水」ウィジェットに近い見た目。
//
//  データ取得エンジン（JMANowcast / RainStep / RainSummary / WidgetLocation）は
//  Shared/RainNowcastEngine.swift を共有利用する。
//
//  ── 事前設定（このターゲット側）──────────────────────────
//  Info.plist:
//    NSWidgetWantsLocation               = YES (Boolean)
//    NSLocationWhenInUseUsageDescription = "現在地の降水予報を表示するために使用します"
//  本体アプリ(RainNowcastiOS)で「使用中のみ許可」を一度通しておくこと。
//

import WidgetKit
import SwiftUI
import CoreLocation

// MARK: - Entry

struct RainEntryiOS: TimelineEntry {
    let date: Date
    let fetchedAt: Date        // データ取得時刻（デバッグ表示用・派生エントリ間で一定）
    let dropped: Int           // このエントリで先頭から落としたバー本数（デバッグ表示用）
    let steps: [RainStep]      // 棒グラフ用の全タイムライン（実況1＋予報12 ≒ 13点）
    let placeName: String?     // 逆ジオコーディング結果（best-effort）
    let summary: RainSummary   // glyph と2行要約に使用
    let notAuthorized: Bool    // 位置情報が未許可なら true
}

// MARK: - Provider

struct RainProvideriOS: TimelineProvider {
    // getTimeline を抜けてもデリゲートが届くよう参照を保持しておく（重要）
    private let location = WidgetLocation()

    func placeholder(in context: Context) -> RainEntryiOS {
        RainEntryiOS(date: .now, fetchedAt: .now, dropped: 0, steps: Self.sampleSteps,
                     placeName: "左京区", summary: .rainingNoStop(mmPerHour: 3),
                     notAuthorized: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (RainEntryiOS) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await fetchEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RainEntryiOS>) -> Void) {
        Task {
            let base = await fetchEntry()
            // 1回の取得から5分刻みの派生エントリを作り、先頭バーを順に落として「現在」を実時間に追従させる。
            // ネットワーク取得は伴わないのでバジェットを消費しない。
            let entries = Self.makeEntries(from: base)
            // 今後1時間 降水なし（.dryForHour）なら再取得を1時間後に延ばして省電力。
            // それ以外（降雨あり/降り出す/取得失敗）は従来どおり20分後。
            let dryForHour: Bool = { if case .dryForHour = base.summary { return true } else { return false } }()
            let minutes = dryForHour ? 60 : 20
            let next = Calendar.current.date(byAdding: .minute, value: minutes, to: base.fetchedAt)!
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }

    /// 1回の取得（base）から5分刻みで派生エントリを作る。各エントリは先頭の実況バーを常に1本落とし
    /// （→ 1本目=+5分）、さらに k 本進めて「現在」を実時間に追従させる。サマリーは実況込みで再計算する。
    private static func makeEntries(from base: RainEntryiOS) -> [RainEntryiOS] {
        guard base.steps.count > 1 else { return [base] }  // 実況のみ/未許可/取得失敗時は1枚のまま
        let count = min(4, base.steps.count - 1)           // 実況を1本捨てるので -1。0,5,10,15分の4枚
        return (0..<count).map { k in
            let entryDate = Calendar.current.date(byAdding: .minute, value: k * 5, to: base.fetchedAt)!
            // 要約は実況込み（dropFirst(k)）で判定 → 「今降っている」を取りこぼさない
            let summary = JMANowcast.summarize(Array(base.steps.dropFirst(k)), now: entryDate)
            // バーは実況を除いた未来のみ（dropFirst(k + 1)）→ 1本目=+5分
            let sliced = Array(base.steps.dropFirst(k + 1))
            return RainEntryiOS(date: entryDate, fetchedAt: base.fetchedAt, dropped: k,
                                steps: sliced, placeName: base.placeName,
                                summary: summary, notAuthorized: base.notAuthorized)
        }
    }

    /// 現在地 → タイムライン → 要約 → 地名 を組み立てて 1 エントリを返す
    private func fetchEntry() async -> RainEntryiOS {
        guard location.isAuthorized else {
            return RainEntryiOS(date: .now, fetchedAt: .now, dropped: 0, steps: [],
                                placeName: nil, summary: .unknown, notAuthorized: true)
        }
        do {
            let loc = try await location.current()
            let steps = try await JMANowcast.fetchTimeline(
                lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
            let summary = JMANowcast.summarize(steps)
            let place = await Self.reverseGeocode(loc)
            return RainEntryiOS(date: .now, fetchedAt: .now, dropped: 0, steps: steps,
                                placeName: place, summary: summary, notAuthorized: false)
        } catch {
            return RainEntryiOS(date: .now, fetchedAt: .now, dropped: 0, steps: [],
                                placeName: Self.cachedPlaceName, summary: .unknown,
                                notAuthorized: false)
        }
    }

    // MARK: 逆ジオコーディング（best-effort）

    private static let placeCacheKey = "lastPlaceName"
    private static var cachedPlaceName: String? {
        UserDefaults.standard.string(forKey: placeCacheKey)
    }

    /// 現在地 → 区・市町村名（例「左京区」）。失敗時は前回値にフォールバック。
    static func reverseGeocode(_ loc: CLLocation) async -> String? {
        if let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            loc, preferredLocale: Locale(identifier: "ja_JP")),
           let p = placemarks.first {
            // 政令市は subLocality=「左京区」、東京23区は locality に区名が出る
            if let name = p.subLocality ?? p.locality ?? p.name ?? p.administrativeArea {
                UserDefaults.standard.set(name, forKey: placeCacheKey)
                return name
            }
        }
        return cachedPlaceName
    }

    // MARK: プレビュー / プレースホルダ用のダミーデータ

    static var sampleSteps: [RainStep] {
        let now = Date()
        let pattern: [Double] = [2, 3, 3, 4, 3, 3, 2, 3, 4, 3, 3, 2, 3]
        return pattern.enumerated().map { i, mm in
            RainStep(date: now.addingTimeInterval(Double(i) * 300), mmPerHour: mm)
        }
    }
}

// MARK: - View

struct RainNowcastiOSWidgetEntryView: View {
    var entry: RainEntryiOS

    private let maxBarHeight: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header
            Text(summaryString)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 2)
            chart
            HStack {
                Text("現在")
                Spacer()
                Text("更新\(updatedString) (\(entry.dropped))")  // デバッグ用：最終取得時刻＋除去本数
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(5 * bars.count)分")   // 右端=今から何分先か。本数×5分（60→55→50→45）
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // ヘッダ：地名＋方位アイコン（左）／天気アイコン（右）
    private var header: some View {
        HStack(alignment: .top, spacing: 4) {
            HStack(spacing: 2) {
                Text(entry.placeName ?? "現在地")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Image(systemName: "location.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Image(systemName: weatherGlyph)
                .font(.system(size: 18))
                .symbolRenderingMode(.multicolor)
        }
    }

    // 棒グラフ：mm/h → 高さ（sqrt 正規化）。無降水も最小ノブで連続表示。
    private var chart: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(bars.indices, id: \.self) { i in
                let mm = bars[i]
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(barColor(mm))
                    .frame(height: barHeight(mm))
            }
        }
        .frame(height: maxBarHeight, alignment: .bottom)
    }

    // MARK: 派生値

    private var bars: [Double] {
        entry.steps.isEmpty ? Array(repeating: 0, count: 12) : entry.steps.map(\.mmPerHour)
    }

    // デバッグ用：最終取得時刻（端末ローカル＝JST、HH:mm）
    private var updatedString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f.string(from: entry.fetchedAt)
    }

    private func barHeight(_ mm: Double) -> CGFloat {
        let cap = 30.0
        let frac = min(max(mm, 0), cap) / cap
        return max(2, CGFloat(frac.squareRoot()) * maxBarHeight)
    }

    private func barColor(_ mm: Double) -> Color {
        switch mm {
        case ..<0.1:  return Color.blue.opacity(0.22)   // 無降水ノブ
        case ..<5:    return Color(red: 0.55, green: 0.82, blue: 1.0)
        case ..<10:   return Color(red: 0.25, green: 0.62, blue: 1.0)
        case ..<20:   return Color(red: 0.05, green: 0.40, blue: 1.0)
        case ..<30:   return Color.yellow
        case ..<50:   return Color.orange
        default:      return Color.red
        }
    }

    private var weatherGlyph: String {
        switch entry.summary {
        case .rainingNoStop(let mm), .rainingStopsIn(_, let mm):
            return mm >= 10 ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        case .startsIn:   return "cloud.rain"
        case .dryForHour: return "sun.max.fill"
        case .unknown:    return "cloud"
        }
    }

    private var summaryString: String {
        if entry.notAuthorized { return "位置情報を\n許可してください" }
        switch entry.summary {
        case .startsIn(let m, _):
            return m <= 0 ? "まもなく雨が\n降りそうです" : "約\(m)分後に\n雨が降りそうです"
        case .rainingStopsIn(let m, _):
            return m <= 0 ? "まもなく雨が\nやみそうです" : "今後\(m)分ほどで\n雨がやみそうです"
        case .rainingNoStop:
            return "今後1時間、\n雨が続くでしょう"
        case .dryForHour:
            return "今後1時間、\n雨は降らないでしょう"
        case .unknown:
            return "降水データを\n取得できません"
        }
    }
}

// MARK: - Widget 定義

struct RainNowcastiOSWidget: Widget {
    let kind = "RainNowcastiOSWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RainProvideriOS()) { entry in
            RainNowcastiOSWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("雨ナウキャスト")
        .description("現在地の今後1時間の雨を、気象庁の高解像度降水ナウキャストで表示します。")
        .supportedFamilies([.systemSmall])
    }
}

#Preview(as: .systemSmall) {
    RainNowcastiOSWidget()
} timeline: {
    // 実況バーを除いた未来のみ（先頭=+5分）。5分刻みで先頭が1本ずつ落ちる様子をスクラブ確認（k=0…3）。
    let now = Date()
    let steps = RainProvideriOS.sampleSteps
    RainEntryiOS(date: now, fetchedAt: now, dropped: 0,
                 steps: Array(steps.dropFirst(1)), placeName: "左京区",
                 summary: .rainingNoStop(mmPerHour: 3), notAuthorized: false)
    RainEntryiOS(date: now.addingTimeInterval(300), fetchedAt: now, dropped: 1,
                 steps: Array(steps.dropFirst(2)), placeName: "左京区",
                 summary: .rainingNoStop(mmPerHour: 3), notAuthorized: false)
    RainEntryiOS(date: now.addingTimeInterval(600), fetchedAt: now, dropped: 2,
                 steps: Array(steps.dropFirst(3)), placeName: "左京区",
                 summary: .rainingNoStop(mmPerHour: 3), notAuthorized: false)
    RainEntryiOS(date: now.addingTimeInterval(900), fetchedAt: now, dropped: 3,
                 steps: Array(steps.dropFirst(4)), placeName: "左京区",
                 summary: .rainingNoStop(mmPerHour: 3), notAuthorized: false)
}
