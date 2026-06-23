//
//  RainNowcastiOSWidgetBundle.swift
//  RainNowcastiOSWidget
//
//  iOS ウィジェット拡張のエントリポイント（@main, WidgetBundle 宣言）。
//

import WidgetKit
import SwiftUI

@main
struct RainNowcastiOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        RainNowcastiOSWidget()
    }
}
