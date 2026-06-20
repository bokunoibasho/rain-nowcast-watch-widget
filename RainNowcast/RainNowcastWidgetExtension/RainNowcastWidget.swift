//
//  RainNowcastWidget.swift
//  Apple Watch 用 accessoryCircular ウィジェット（最小実装サンプル）
//
//  現在地 × 気象庁 高解像度降水ナウキャスト(hrpns) を使って
//  「あと何分で雨が降るか / いつやむか」を表示する。
//  watchOS 標準の「雨の時刻」ウィジェットと同じ使い勝手を狙う。
//
//  ── 構成 ────────────────────────────────────────────
//  データ取得エンジン（RainStep / RainSummary / JMANowcast / WidgetLocation）は
//  Shared/RainNowcastEngine.swift に切り出し、iOS ウィジェットと共有している。
//  このファイルは watchOS 専用の Provider / View / Widget 定義のみ。
//
//  ── 事前設定（Widget Extension ターゲット側）──────────────
//  Info.plist:
//    NSWidgetWantsLocation              = YES (Boolean)
//    NSLocationWhenInUseUsageDescription = "現在地の降水予報を表示するために使用します"
//  本体 Watch App 側で「使用中のみ許可」を一度リクエストしておくこと。
//  画面のどこかに出典「気象データ © Japan Meteorological Agency」を明記すること。
//

import WidgetKit
import SwiftUI
import CoreLocation

// MARK: - TimelineProvider

struct RainEntry: TimelineEntry {
    let date: Date
    let summary: RainSummary
}

struct RainProvider: TimelineProvider {
    // getTimeline を抜けてもデリゲートが届くよう参照を保持しておく（重要）
    private let location = WidgetLocation()

    func placeholder(in context: Context) -> RainEntry {
        RainEntry(date: .now, summary: .unknown)
    }

    func getSnapshot(in context: Context, completion: @escaping (RainEntry) -> Void) {
        completion(RainEntry(date: .now, summary: .dryForHour))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RainEntry>) -> Void) {
        Task {
            var summary: RainSummary = .unknown
            if location.isAuthorized {
                do {
                    let loc = try await location.current()
                    let steps = try await JMANowcast.fetchTimeline(
                        lat: loc.coordinate.latitude,
                        lon: loc.coordinate.longitude)
                    summary = JMANowcast.summarize(steps)
                } catch {
                    summary = .unknown
                }
            }
            let entry = RainEntry(date: .now, summary: summary)
            // ナウキャストは5分更新。Watch のバジェットに配慮して10分後に再取得を要求
            let next = Calendar.current.date(byAdding: .minute, value: 10, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// MARK: - accessoryCircular ビュー

struct RainCircularView: View {
    let summary: RainSummary

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            content
        }
        .widgetLabel { Text(label) } // Infograph 等の曲線テキスト表示用
    }

    @ViewBuilder private var content: some View {
        switch summary {
        case .startsIn(let m, _):
            VStack(spacing: -1) {
                Image(systemName: "cloud.rain")
                Text("\(m)分").font(.system(size: 13, weight: .semibold)).minimumScaleFactor(0.7)
            }
        case .rainingStopsIn(let m, _):
            VStack(spacing: -1) {
                Image(systemName: "cloud.rain.fill")
                Text("〜\(m)分").font(.system(size: 13, weight: .semibold)).minimumScaleFactor(0.7)
            }
        case .rainingNoStop:
            Image(systemName: "cloud.heavyrain.fill").font(.title3)
        case .dryForHour:
            Image(systemName: "sun.max").font(.title3)
        case .unknown:
            Image(systemName: "questionmark")
        }
    }

    private var label: String {
        switch summary {
        case .startsIn(let m, _):       return "\(m)分後に雨"
        case .rainingStopsIn(let m, _): return "約\(m)分でやむ"
        case .rainingNoStop:            return "雨が継続"
        case .dryForHour:               return "1時間は降りません"
        case .unknown:                  return "取得できません"
        }
    }
}

// MARK: - Widget 定義

struct RainNowcastWidget: Widget {
    let kind = "RainNowcastWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RainProvider()) { entry in
            RainCircularView(summary: entry.summary)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("雨ナウキャスト")
        .description("現在地の雨を気象庁の高解像度ナウキャストで表示します。")
        .supportedFamilies([.accessoryCircular])
    }
}

@main
struct RainNowcastBundle: WidgetBundle {
    var body: some Widget {
        RainNowcastWidget()
    }
}
