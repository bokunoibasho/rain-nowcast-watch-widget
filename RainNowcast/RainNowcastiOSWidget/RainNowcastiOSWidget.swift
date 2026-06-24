//
//  RainNowcastiOSWidget.swift
//  iOS ホーム画面ウィジェット（systemSmall）
//
//  現在地の今後1時間の降水強度を棒グラフで表示する（Apple 純正「天気」アプリの
//  「次の1時間の降水」風）。1時間以内に雨が無い時は棒を出さず、「今後の雨」(rasrf) で
//  数時間先までの見通し（約◯時間後／しばらく雨なし）を文言で示す。
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
    let steps: [RainStep]      // 棒グラフ用のタイムライン（予報12点。棒を出さない時は空）
    let placeName: String?     // 逆ジオコーディング結果（best-effort）
    let summary: RainSummary   // glyph と2行要約に使用
    let outlook: RainOutlook?  // rasrf 見通し（棒グラフを出さないときだけ非nil）
    let notAuthorized: Bool    // 位置情報が未許可なら true
}

/// 1時間以内に雨があるか（= 棒グラフを出すか）。startsIn / 降雨中のみ true。
private func rainWithinHour(_ s: RainSummary) -> Bool {
    switch s {
    case .startsIn, .rainingStopsIn, .rainingNoStop: return true
    default: return false
    }
}

// MARK: - Provider

struct RainProvideriOS: TimelineProvider {
    // getTimeline を抜けてもデリゲートが届くよう参照を保持しておく（重要）
    private let location = WidgetLocation()

    func placeholder(in context: Context) -> RainEntryiOS {
        RainEntryiOS(date: .now, fetchedAt: .now, dropped: 0, steps: Self.sampleSteps,
                     placeName: "左京区", summary: .rainingNoStop(mmPerHour: 3),
                     outlook: nil, notAuthorized: false)
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
            // 1回の取得から派生エントリを焼き込む（雨が近い→5分刻み6枚で先頭バーを前進／数時間先→1時間刻み）。
            // ネットワーク取得は伴わないのでバジェットを消費しない。
            let entries = Self.makeEntries(from: base)
            let next = Self.nextRefresh(for: base)
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }

    /// 雨の近さで焼き込み方を変える。
    /// ・1時間以内に雨 → 5分刻み最大6枚。先頭バーを順に落として「現在」を実時間に追従。
    /// ・数時間先に雨（rasrf）→ 1時間刻みのカウントダウン用エントリ（棒グラフは出さない）。
    /// ・しばらく雨なし／取得失敗／未許可 → 1枚のまま。
    private static func makeEntries(from base: RainEntryiOS) -> [RainEntryiOS] {
        let cal = Calendar.current

        // 1時間以内に雨：5分刻み最大6枚。先頭バーを順に落として「現在」を実時間に追従させる。
        if rainWithinHour(base.summary) {
            guard !base.steps.isEmpty else { return [base] }
            let count = min(6, base.steps.count)   // 0,5,…,25分ぶんの派生エントリ
            return (0..<count).map { k in
                let entryDate = cal.date(byAdding: .minute, value: k * 5, to: base.fetchedAt)!
                let sliced = Array(base.steps.dropFirst(k))   // 先頭=現在フレーム。k 本ぶん前進
                let summary = JMANowcast.summarize(sliced, now: entryDate)
                return RainEntryiOS(date: entryDate, fetchedAt: base.fetchedAt, dropped: k,
                                    steps: sliced, placeName: base.placeName,
                                    summary: summary, outlook: base.outlook,
                                    notAuthorized: base.notAuthorized)
            }
        }

        // 数時間先に雨：1時間刻みのカウントダウン（棒グラフなし）。雨の1時間前で再取得するので、
        // その時刻までの各正時にエントリを置く（summaryString が entry.date 基準で「約N時間後」を減らす）。
        if case .rainExpected(let t) = base.outlook {
            let hoursToReload = t.addingTimeInterval(-3600).timeIntervalSince(base.fetchedAt) / 3600
            let count = max(1, min(15, Int(hoursToReload.rounded(.down)) + 1))
            return (0..<count).map { h in
                let entryDate = cal.date(byAdding: .hour, value: h, to: base.fetchedAt)!
                return RainEntryiOS(date: entryDate, fetchedAt: base.fetchedAt, dropped: 0,
                                    steps: [], placeName: base.placeName,
                                    summary: base.summary, outlook: base.outlook,
                                    notAuthorized: base.notAuthorized)
            }
        }

        // しばらく雨なし／取得失敗／未許可 → 1枚
        return [base]
    }

    /// 次回取得時刻を決める。
    /// ・雨が近い/降雨中/不明 → 15 分後（実時間にバーを追従させる粒度）。
    /// ・数時間先に雨（rasrf .rainExpected）→ 「雨の 1 時間前」までの猶予を半分にした時刻
    ///   （予報時刻は前倒しに変わり得るので早めに見直す）。毎リロードで半分ずつ縮み、雨が
    ///   近づくほど頻度が上がる。fetchedAt+15分 〜 +15時間 にクランプ。
    /// ・しばらく雨なし（rasrf .dryThrough）→ 6 時間後（「しばらく」表示後に直近の雨を取りこぼさない）。
    /// ・rasrf 取得失敗 → 60 分後。
    private static func nextRefresh(for base: RainEntryiOS) -> Date {
        let cal = Calendar.current
        let floor = cal.date(byAdding: .minute, value: 15, to: base.fetchedAt)!
        let ceil  = cal.date(byAdding: .hour,   value: 15, to: base.fetchedAt)!

        guard case .dryForHour = base.summary else { return floor }  // 雨が近い/不明 → 15分

        switch base.outlook {
        case .rainExpected(let t):
            // 雨の予報時刻は前倒しに変わり得るので、予定取得（雨の1時間前）までの猶予を
            // 半分にして早めに見直す。例: 5時間後の雨 → 4時間後ではなく 2時間後。
            let oneHourBefore = t.addingTimeInterval(-3600)
            let halved = base.fetchedAt.addingTimeInterval(
                oneHourBefore.timeIntervalSince(base.fetchedAt) / 2)
            return min(max(halved, floor), ceil)
        case .dryThrough:  // しばらく雨なし → 6 時間後
            return cal.date(byAdding: .hour, value: 6, to: base.fetchedAt)!
        case .none:  // rasrf 取得失敗 等 → 60 分
            return cal.date(byAdding: .minute, value: 60, to: base.fetchedAt)!
        }
    }

    /// 現在地 → rasrf 先頭ゲート → 必要なら hrpns 予報 → 要約 → 地名 で 1 エントリを返す。
    /// 安い rasrf を先に見て、雨が直近に迫っているときだけ hrpns（予報12枚）を取りに行く。
    private func fetchEntry() async -> RainEntryiOS {
        guard location.isAuthorized else {
            return RainEntryiOS(date: .now, fetchedAt: .now, dropped: 0, steps: [],
                                placeName: nil, summary: .unknown, outlook: nil,
                                notAuthorized: true)
        }
        do {
            let loc = try await location.current()
            let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
            let place = await Self.reverseGeocode(loc)

            // hrpns を取らずに見通し文言だけ出すケースは、ここで完結させる。
            let fallback: RainOutlook?   // hrpns 空振り時に出す見通し
            switch try await JMANowcast.fetchRainGate(lat: lat, lon: lon) {
            case .later(let t):    return Self.outlookEntry(.rainExpected(at: t), place: place)
            case .dry(let until):  return Self.outlookEntry(.dryThrough(until: until), place: place)
            case .imminent(let t): fallback = .rainExpected(at: t)
            case .unknown:         fallback = nil   // rasrf 失敗 → hrpns 結果に委ねる
            }

            // 直近に雨（or rasrf 失敗）→ hrpns 予報で詳細を取得。
            let steps = try await JMANowcast.fetchTimeline(lat: lat, lon: lon)
            let summary = JMANowcast.summarize(steps)
            if case .dryForHour = summary {
                // rasrf は雨と判定したが hrpns は今後1時間ドライ（先頭枠の過去ぶん 等）。
                // 棒グラフは出さず、分かる範囲で見通しを文言表示する。
                return Self.outlookEntry(fallback, place: place)
            }
            return RainEntryiOS(date: .now, fetchedAt: .now, dropped: 0, steps: steps,
                                placeName: place, summary: summary, outlook: nil,
                                notAuthorized: false)
        } catch {
            return RainEntryiOS(date: .now, fetchedAt: .now, dropped: 0, steps: [],
                                placeName: Self.cachedPlaceName, summary: .unknown,
                                outlook: nil, notAuthorized: false)
        }
    }

    /// 棒グラフを出さない（今後1時間 雨なし）エントリ。outlook が見通し文言を決める。
    private static func outlookEntry(_ outlook: RainOutlook?, place: String?) -> RainEntryiOS {
        RainEntryiOS(date: .now, fetchedAt: .now, dropped: 0, steps: [],
                     placeName: place, summary: .dryForHour, outlook: outlook,
                     notAuthorized: false)
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
            if showBars {
                chart
                HStack {
                    Text("現在")
                    Spacer()
                    Text("更新\(updatedString) (\(entry.dropped))")  // デバッグ用：最終取得時刻＋除去本数
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(5 * bars.count)分")   // 右端=今から何分先か。本数×5分（60→…→35）
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                // 1時間以内に雨が無い時は棒グラフを出さない。デバッグの更新時刻だけ足元に残す。
                HStack {
                    Spacer()
                    Text("更新\(updatedString)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
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

    // 棒グラフ（配色・高さは Shared/RainChartView.swift に集約）
    private var chart: some View {
        RainBarChart(values: bars, maxBarHeight: maxBarHeight)
    }

    // MARK: 派生値

    // 1時間以内に雨がある時だけ棒グラフを出す
    private var showBars: Bool { rainWithinHour(entry.summary) }

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

    private var weatherGlyph: String {
        RainStyle.weatherGlyph(summary: entry.summary, outlook: entry.outlook)
    }

    // 「今後の雨」(rasrf) の時刻 → 今からの概算時間（entry 時刻基準、最低1時間）
    private func outlookHours(_ t: Date) -> Int {
        max(1, Int((t.timeIntervalSince(entry.date) / 3600).rounded()))
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
            // 「今後の雨」で先が読めていればそれを優先表示。読めなければ従来の1時間表現。
            switch entry.outlook {
            case .rainExpected(let t):
                return "約\(outlookHours(t))時間後に\n雨が降りそうです"
            case .dryThrough:
                return "しばらく雨は\n降らないでしょう"
            case .none:
                return "今後1時間、\n雨は降らないでしょう"
            }
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
                 summary: .rainingNoStop(mmPerHour: 3), outlook: nil, notAuthorized: false)
    RainEntryiOS(date: now.addingTimeInterval(300), fetchedAt: now, dropped: 1,
                 steps: Array(steps.dropFirst(2)), placeName: "左京区",
                 summary: .rainingNoStop(mmPerHour: 3), outlook: nil, notAuthorized: false)
    RainEntryiOS(date: now.addingTimeInterval(600), fetchedAt: now, dropped: 2,
                 steps: Array(steps.dropFirst(3)), placeName: "左京区",
                 summary: .rainingNoStop(mmPerHour: 3), outlook: nil, notAuthorized: false)
    RainEntryiOS(date: now.addingTimeInterval(900), fetchedAt: now, dropped: 3,
                 steps: Array(steps.dropFirst(4)), placeName: "左京区",
                 summary: .rainingNoStop(mmPerHour: 3), outlook: nil, notAuthorized: false)
    // 「今後の雨」で当面 雨なし（棒グラフは出さず「しばらく雨は降らないでしょう」）
    RainEntryiOS(date: now, fetchedAt: now, dropped: 0,
                 steps: [], placeName: "左京区", summary: .dryForHour,
                 outlook: .dryThrough(until: now.addingTimeInterval(15 * 3600)),
                 notAuthorized: false)
    // 数時間先に雨（棒グラフは出さず「約◯時間後に雨が降りそうです」）
    RainEntryiOS(date: now, fetchedAt: now, dropped: 0,
                 steps: [], placeName: "左京区", summary: .dryForHour,
                 outlook: .rainExpected(at: now.addingTimeInterval(3 * 3600)),
                 notAuthorized: false)
}
