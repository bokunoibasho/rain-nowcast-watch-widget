//
//  RainNowcastEngine.swift
//  共有エンジン（watchOS / iOS 両ウィジェット拡張で使用）
//
//  現在地 × 気象庁 高解像度降水ナウキャスト(hrpns) を使って、
//  今後1時間ぶんの降水強度タイムラインを構築する。
//  プラットフォーム非依存。UI / TimelineProvider は各ターゲット側に置く。
//
//  ※ このフォルダ（Shared）は watch ウィジェット拡張と iOS ウィジェット拡張の
//    両方の fileSystemSynchronizedGroups に同期されている。
//

import Foundation
import CoreLocation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 1. モデル

struct RainStep {
    let date: Date         // 予報の有効時刻 validtime (UTC)
    let mmPerHour: Double   // 推定降水強度 (mm/h)。0 は無降水
    var isRaining: Bool { mmPerHour >= 0.1 }
}

enum RainSummary {
    case startsIn(minutes: Int, mmPerHour: Double)        // 今は降っていない → 降り出すまで
    case rainingStopsIn(minutes: Int, mmPerHour: Double)  // 今降っている → やむまで
    case rainingNoStop(mmPerHour: Double)                 // 1時間降り続く
    case dryForHour                                        // 1時間降らない
    case unknown
}

/// rasrf 先頭ゲートの判定結果。安い rasrf を常に先に見て、雨が直近に迫っているときだけ
/// 詳細な hrpns 予報を取りに行く——その分岐に使う。
enum RainGate {
    case imminent(firstRain: Date)  // 直近（先頭1〜2枠）に雨 → hrpns 予報を取得して棒グラフ表示
    case later(rainAt: Date)        // 数時間先に雨 → hrpns 不要、見通し文言のみ
    case dry(until: Date)           // 当面 雨なし
    case unknown                    // rasrf 取得失敗 → hrpns フォールバック
}

/// 棒グラフを出さないときの見通し表示（rasrf 由来）。
enum RainOutlook {
    case rainExpected(at: Date)   // 最初に雨が来る validtime（UTC）→「約N時間後に雨」
    case dryThrough(until: Date)  // この時刻まで雨なし →「しばらく雨なし」
}

// MARK: - 2. 気象庁ナウキャスト エンジン

enum JMANowcast {

    // 予報(N2)の時刻一覧。
    // ※ 必ずこの JSON を読んで basetime/validtime を得ること。
    //   現在時刻から URL を推測すると 404 を量産し、その404がCDNに
    //   キャッシュされて自分にも他人にも不利益になる（やらない）。
    private static let targetTimesFcstURL = URL(string: "https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N2.json")!
    // 「今後の雨」(rasrf)。最大15時間先までの「各時刻までの1時間降水量」タイル。
    private static let targetTimesRasrfURL = URL(string: "https://www.jma.go.jp/bosai/jmatile/data/rasrf/targetTimes.json")!

    private static let zoom = 10          // hrpns の最大ズーム
    private static let tileSize = 256.0

    struct TargetTime: Decodable {
        let basetime: String
        let validtime: String
        let elements: [String]?
    }

    /// 現在地の今後1時間の降水タイムライン（予報 N2 を validtime 昇順・5分刻み12枚）を構築。
    /// 先頭フレームの validtime は basetime+5分（≒現在）なので「今降っているか」も判定できる。
    static func fetchTimeline(lat: Double, lon: Double) async throws -> [RainStep] {
        let fcst = try await fetchTargetTimes(targetTimesFcstURL)
        var steps: [RainStep] = []
        for t in fcst.sorted(by: { $0.validtime < $1.validtime }) {
            let mm = await sampleIntensity(basetime: t.basetime, validtime: t.validtime,
                                           lat: lat, lon: lon)
            steps.append(RainStep(date: parse(t.validtime), mmPerHour: mm))
        }
        return steps
    }

    /// 「今後の雨」(rasrf) を先頭ゲートとして使い、hrpns を取りに行くべきかを判定する。
    /// rasrf は毎正時 validtime・1時間刻み・各時刻までの1時間積算。安いので常時これを先に見て、
    /// 雨が直近（先頭1〜2枠）に迫っているときだけ詳細な hrpns 予報を取得する。
    static func fetchRainGate(lat: Double, lon: Double, now: Date = .now) async throws -> RainGate {
        let all = try await fetchTargetTimes(targetTimesRasrfURL)

        // rasrf 要素・未来の validtime のみ。最新 basetime ほど前方が欠けることがあるため、
        // 同一 validtime は basetime が最も新しいタイルを採用して網羅性を確保する。
        var byValid: [String: TargetTime] = [:]
        for t in all where (t.elements ?? []).contains("rasrf") && parse(t.validtime) > now {
            if let existing = byValid[t.validtime], existing.basetime >= t.basetime { continue }
            byValid[t.validtime] = t
        }
        let future = byValid.values.sorted { $0.validtime < $1.validtime }
        guard let last = future.last else { return .unknown }

        // 「直近」= 先頭1〜2枠。rasrf は正時バケツで先頭枠が過去を一部含むため、
        // この2枠で次の約60〜70分の降り出し／降雨中を取りこぼさない。
        let imminentUntil = future[min(1, future.count - 1)].validtime

        for t in future {
            let mm = await sampleIntensity(basetime: t.basetime, validtime: t.validtime,
                                           lat: lat, lon: lon, product: "rasrf", layer: "rasrf")
            // rasrf は1時間積算で凡例色が hrpns と異なるが、mm>0（=不透明ピクセル）で
            // 「その時刻までの1時間に降雨あり」を頑健に判定できる。
            if mm > 0 {
                let at = parse(t.validtime)
                return t.validtime <= imminentUntil ? .imminent(firstRain: at) : .later(rainAt: at)
            }
        }
        return .dry(until: parse(last.validtime))
    }

    private static func fetchTargetTimes(_ url: URL) async throws -> [TargetTime] {
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([TargetTime].self, from: data)
    }

    // MARK: タイル座標 → ピクセル抽出 → 降水強度

    private static func sampleIntensity(basetime: String, validtime: String,
                                        lat: Double, lon: Double,
                                        product: String = "nowc", layer: String = "hrpns") async -> Double {
        let n = pow(2.0, Double(zoom))
        let latRad = lat * .pi / 180
        let xWorld = (lon + 180) / 360 * n
        let yWorld = (1 - asinh(tan(latRad)) / .pi) / 2 * n
        let tileX = Int(floor(xWorld))
        let tileY = Int(floor(yWorld))
        let px = Int((xWorld - Double(tileX)) * tileSize)
        let py = Int((yWorld - Double(tileY)) * tileSize)

        let urlStr = "https://www.jma.go.jp/bosai/jmatile/data/\(product)/\(basetime)/none/\(validtime)/surf/\(layer)/\(zoom)/\(tileX)/\(tileY).png"
        guard let url = URL(string: urlStr) else { return 0 }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return 0 // タイルなし = 無降水域
            }
            guard let rgba = pixelRGBA(pngData: data, x: px, y: py) else { return 0 }
            return intensity(from: rgba)
        } catch {
            return 0
        }
    }

    /// PNG の特定 1 ピクセルの RGBA を取り出す（watchOS でも CoreGraphics で可）
    private static func pixelRGBA(pngData: Data, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
        #if canImport(UIKit)
        guard let cg = UIImage(data: pngData)?.cgImage else { return nil }
        #else
        guard let src = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        #endif
        var pixel: [UInt8] = [0, 0, 0, 0]
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else { return nil }
        // CoreGraphics は左下原点。PNG(x,y) は左上原点なので、対象ピクセルが
        // 1x1 コンテキストの原点に来るよう画像をオフセットして描画する。
        let h = cg.height
        ctx.draw(cg, in: CGRect(x: -x, y: y - h + 1, width: cg.width, height: h))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }

    /// JMA hrpns の凡例カラーに最も近いバンドへ分類して mm/h を返す。
    /// ※ RGB は近似値。実タイルを採色して微調整すると精度が上がる。
    ///   ただし「降っているか否か」は alpha だけで頑健に判定できる。
    private static func intensity(from rgba: (UInt8, UInt8, UInt8, UInt8)) -> Double {
        let (r, g, b, a) = rgba
        if a < 16 { return 0 } // 透明 = 無降水

        // (R, G, B, 代表 mm/h)
        let palette: [(Double, Double, Double, Double)] = [
            (242, 242, 255, 0.5),  // 0.1–1
            (160, 210, 255, 3),    // 1–5
            ( 33, 140, 255, 7),    // 5–10
            (  0,  65, 255, 15),   // 10–20
            (250, 245,   0, 25),   // 20–30
            (255, 153,   0, 40),   // 30–50
            (255,  40,   0, 65),   // 50–80
            (180,   0, 104, 100),  // 80+
        ]
        var best = 0.5
        var bestDist = Double.greatestFiniteMagnitude
        for (pr, pg, pb, mm) in palette {
            let d = pow(pr - Double(r), 2) + pow(pg - Double(g), 2) + pow(pb - Double(b), 2)
            if d < bestDist { bestDist = d; best = mm }
        }
        return best
    }

    private static func parse(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s) ?? .now
    }

    // MARK: タイムライン → 要約

    static func summarize(_ steps: [RainStep], now: Date = .now) -> RainSummary {
        let future = steps.filter { $0.date >= now.addingTimeInterval(-300) }
        guard let head = future.first else { return .unknown }

        if head.isRaining {
            if let stop = future.first(where: { !$0.isRaining }) {
                let m = max(0, Int(stop.date.timeIntervalSince(now) / 60))
                return .rainingStopsIn(minutes: m, mmPerHour: head.mmPerHour)
            }
            return .rainingNoStop(mmPerHour: head.mmPerHour)
        } else {
            if let start = future.first(where: { $0.isRaining }) {
                let m = max(0, Int(start.date.timeIntervalSince(now) / 60))
                return .startsIn(minutes: m, mmPerHour: start.mmPerHour)
            }
            return .dryForHour
        }
    }
}

// MARK: - 3. 位置情報（ウィジェット拡張内での一発取得）

final class WidgetLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var cont: CheckedContinuation<CLLocation, Error>?

    // watchOS では isAuthorizedForWidgetUpdates が使えない（iOS/macOS 専用）。
    // authorizationStatus で許可状態を判定する。本体アプリで「使用中のみ許可」を
    // 通しておけば、ウィジェット拡張からもこの値が authorized になる。
    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        // 数百m 精度。zoom10 のタイル解像度（≒100〜150m/ピクセル）とよく合う。
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func current() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { c in
            self.cont = c
            manager.requestLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        if let loc = locs.last { cont?.resume(returning: loc); cont = nil }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        cont?.resume(throwing: error); cont = nil
    }
}
