//
//  RainForecastViewModel.swift
//  RainNowcastiOS
//
//  アプリ画面（RainForecastView）のデータ取得。ウィジェット拡張の RainProvideriOS.fetchEntry と
//  同じ流れで、現在地 → rasrf 先頭ゲート →（必要なら）hrpns 予報 → 要約 を組み立てる。
//  加えて、時間別表示用の rasrf 系列（fetchHourlyRain）とレーダーマップ用のフレーム
//  （currentNowcastFrame）を取得する。エンジンは Shared/RainNowcastEngine.swift を共有利用。
//

import SwiftUI
import CoreLocation

@MainActor
@Observable
final class RainForecastViewModel {
    enum LoadState: Equatable { case idle, loading, loaded, failed }

    var state: LoadState = .idle
    var placeName: String?
    var summary: RainSummary = .unknown
    var outlook: RainOutlook?
    var steps: [RainStep] = []          // 棒グラフ用（hrpns 予報12点。出さない時は空）
    var hourly: [RainStep] = []         // 時間別（雨のみ）用（rasrf 毎正時）
    var coordinate: CLLocationCoordinate2D?
    var frame: (basetime: String, validtime: String)?   // レーダーマップ（hrpns）用

    private let location = WidgetLocation()

    /// 1時間以内に雨がある（=棒グラフを出す）か。ウィジェットの rainWithinHour と同じ判定。
    var showBars: Bool {
        switch summary {
        case .startsIn, .rainingStopsIn, .rainingNoStop: return true
        default: return false
        }
    }

    /// ヘッダ右の天気グリフ。
    var glyph: String { RainStyle.weatherGlyph(summary: summary, outlook: outlook) }

    func load() async {
        state = .loading
        do {
            let loc = try await location.current()
            coordinate = loc.coordinate
            let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
            placeName = await Self.reverseGeocode(loc)

            // ① 棒グラフ：安い rasrf を先に見て、雨が直近に迫る時だけ hrpns 予報を取る。
            switch try await JMANowcast.fetchRainGate(lat: lat, lon: lon) {
            case .later(let t):    setOutlook(.rainExpected(at: t))
            case .dry(let until):  setOutlook(.dryThrough(until: until))
            case .imminent(let t): try await fetchBars(lat: lat, lon: lon, fallback: .rainExpected(at: t))
            case .unknown:         try await fetchBars(lat: lat, lon: lon, fallback: nil)
            }

            // ② 時間別（雨のみ）／③ レーダーフレームは best-effort（失敗してもメイン表示は出す）。
            hourly = (try? await JMANowcast.fetchHourlyRain(lat: lat, lon: lon)) ?? []
            frame = try? await JMANowcast.currentNowcastFrame()
            state = .loaded
        } catch {
            state = .failed
        }
    }

    /// hrpns 予報を取って要約。rasrf は雨判定でも hrpns が今後1時間ドライなら見通し文言へ。
    private func fetchBars(lat: Double, lon: Double, fallback: RainOutlook?) async throws {
        let s = try await JMANowcast.fetchTimeline(lat: lat, lon: lon)
        let sum = JMANowcast.summarize(s)
        if case .dryForHour = sum {
            setOutlook(fallback)
        } else {
            summary = sum; outlook = nil; steps = s
        }
    }

    /// 棒グラフを出さない（今後1時間 雨なし）状態。
    private func setOutlook(_ o: RainOutlook?) {
        summary = .dryForHour; outlook = o; steps = []
    }

    // MARK: 逆ジオコーディング（best-effort・前回値フォールバック）

    private static let placeCacheKey = "lastPlaceNameApp"

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
        return UserDefaults.standard.string(forKey: placeCacheKey)
    }
}
