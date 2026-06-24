//
//  RainChartView.swift
//  共有プレゼンテーション（iOS アプリ画面 / iOS ウィジェット拡張で使用）
//
//  降水バーグラフの配色・高さ・天気グリフをここに集約し、アプリ画面とウィジェットで
//  同じ見た目を共有する。データ取得は RainNowcastEngine、UI 構成は各ターゲット側。
//

import SwiftUI

/// 降水バーグラフの配色・高さと天気グリフ（純粋関数）。
enum RainStyle {
    /// mm/h → 棒の色。hrpns 凡例に対応。0.1mm/h 未満は無降水ノブ。
    static func barColor(_ mm: Double) -> Color {
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

    /// mm/h → 棒の高さ。sqrt 正規化・30mm/h で頭打ち・無降水も最小 2pt で連続表示。
    static func barHeight(_ mm: Double, max maxBarHeight: CGFloat) -> CGFloat {
        let cap = 30.0
        let frac = min(Swift.max(mm, 0), cap) / cap
        return Swift.max(2, CGFloat(frac.squareRoot()) * maxBarHeight)
    }

    /// 要約＋見通しから SF Symbol 名を返す（雨の強さ・近さで出し分け）。
    static func weatherGlyph(summary: RainSummary, outlook: RainOutlook?) -> String {
        switch summary {
        case .rainingNoStop(let mm), .rainingStopsIn(_, let mm):
            return mm >= 10 ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        case .startsIn:   return "cloud.rain"
        case .dryForHour:
            if case .rainExpected = outlook { return "cloud.sun" }  // 数時間先に雨
            return "sun.max.fill"
        case .unknown:    return "cloud"
        }
    }
}

/// 今後1時間の降水強度バーグラフ（mm/h の配列）。ウィジェットとアプリ画面で共有。
struct RainBarChart: View {
    let values: [Double]
    var maxBarHeight: CGFloat = 38
    var spacing: CGFloat = 1.5

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(values.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(RainStyle.barColor(values[i]))
                    .frame(height: RainStyle.barHeight(values[i], max: maxBarHeight))
            }
        }
        .frame(height: maxBarHeight, alignment: .bottom)
    }
}
