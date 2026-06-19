# 雨ナウキャスト Watch ウィジェット — 引き継ぎメモ（Claude Code 向け）

## 0. このメモの使い方
このファイルと `RainNowcastWidget.swift` をリポジトリ直下に置いて作業を開始する。
Claude Code は本メモを読んでから、下記「実装タスク」を上から順に進めること。
**既に解決済みのハマりどころ（§6）を再発見しようとしないこと。**

---

## 1. ゴール
Apple Watch の **`accessoryCircular`** ウィジェットで、
**現在地に雨が降るタイミング**を watchOS 標準の「雨の時刻」ウィジェットのように表示する。

- データ源：気象庁 高解像度降水ナウキャスト（hrpns）の地図タイル
- 表示例：「あと15分で雨」「約20分でやむ」「1時間は降りません」
- 対象ファミリー：まず `accessoryCircular` のみ（後で `accessoryRectangular` 追加余地あり）

---

## 2. 現状 / 既存ファイル
- `RainNowcastWidget.swift` … 動く最小実装一式。以下を含む：
  - `JMANowcast`：時刻一覧JSON取得 → タイル取得 → 該当ピクセル抽出 → mm/h 変換 → 1時間タイムライン → 要約
  - `WidgetLocation`：ウィジェット拡張内での位置情報一発取得（`async`）
  - `RainProvider` / `RainEntry`：TimelineProvider（10分リロード）
  - `RainCircularView`：円形ビュー（SF Symbols + `widgetLabel`）
  - `RainNowcastWidget` / `RainNowcastBundle`：Widget 定義
- **未着手**：Xcode プロジェクト本体（Watch App + Widget Extension のターゲット構成）

---

## 3. Xcode プロジェクト構成（作成タスク）
1. watchOS App プロジェクトを新規作成（SwiftUI / 単独 Watch アプリで可。iPhone コンパニオン無しでも動く）。
2. ターゲットを 2 つにする：
   - **Watch App 本体**（位置情報の許可リクエスト＋出典表示を担当）
   - **Widget Extension**（`RainNowcastWidget.swift` を追加する先）
3. `RainNowcastWidget.swift` を Widget Extension ターゲットにのみ追加（Target Membership に注意）。
4. リポジトリ名・Bundle ID は任意。匿名公開する場合は `bokunoibasho` アカウント配下を想定。

---

## 4. 設定（Info.plist / Capabilities）
### Widget Extension の Info.plist
| キー | 値 |
|---|---|
| `NSWidgetWantsLocation` | `YES`（Boolean） |
| `NSLocationWhenInUseUsageDescription` | 「現在地の降水予報を表示するために使用します」 |

### Watch App 本体
- 起動時に **「使用中のみ許可（When In Use）」** を一度リクエストする。
  これを先に通しておかないとウィジェット側の `isAuthorizedForWidgetUpdates` が false のまま。
- 画面のどこかに出典「**気象データ © Japan Meteorological Agency**」を表示する（§9）。

---

## 5. 実装タスク（優先順）
- [ ] §3 のターゲット構成を作り、`RainNowcastWidget.swift` を組み込んでビルドを通す
- [ ] §4 の plist キーと本体の許可リクエストを実装し、実機で位置情報が取れることを確認
- [ ] 実機 or シミュレータで円形ウィジェットを文字盤／Smart Stack に追加して動作確認
- [ ] §8 の色パレットを実タイルで採色して微調整（強度バンドの精度向上）
- [ ] エラー時 UI（`.unknown`）と「位置情報未許可」状態の文言を分けて出す
- [ ] （任意）`accessoryRectangular` を追加し「次の雨ピーク時刻＋強度」を1〜2行で表示
- [ ] （任意・本命）信頼性のため取得を本体／iPhone 側へ移し、watchOS 26 の **ウィジェット APNs プッシュ**で更新（§7）

---

## 6. 既知のハマりどころ（再発見しないこと）
1. **タイル時刻を現在時刻から推測しない。** 必ず時刻一覧JSONを読む。
   推測URLは404を量産し、その404がCDNにキャッシュされて自他ともに不利益。
2. **`CLLocationManager` の参照を `getTimeline` の寿命より長く保つ。**
   ローカル変数にするとデリゲートが呼ばれず location が返らない。サンプルは
   `RainProvider` のプロパティ `WidgetLocation` として保持済み。
3. **plist に `NSWidgetWantsLocation` が無いと**「privacy-sensitive data にアクセス」
   エラーで取得不可。`NSLocationWhenInUseUsageDescription` だけでは足りない。
4. **無降水域は透明 PNG。** 降る/降らないは alpha==0 判定が最も頑健。色解析は強度用。
5. **CoreGraphics は左下原点 / PNG は左上原点。** ピクセル抽出時の y 反転に注意
   （実装済み：`CGRect(x: -x, y: y - h + 1, ...)`）。
6. **watchOS のウィジェット更新はバジェット管理。** 秒単位更新は不可。
   リロードは `.after(+10分)` 程度に。Watch 拡張からの通信は失敗もありうる。
7. **`isAuthorizedForWidgetUpdates` は watchOS では使えない**（iOS/macOS 専用 API）。
   watchOS では `manager.authorizationStatus` を見て
   `.authorizedWhenInUse` / `.authorizedAlways` で判定する（`WidgetLocation.isAuthorized` 実装済み）。
   本体アプリで先に「使用中のみ許可」を通す必要がある点は変わらない（§4）。
8. **`ObservableObject` / `@Published` は Combine 由来。** SwiftUI を import しても
   自動では入らないので、本体アプリ側で `import Combine` が必要（`RainNowcastApp.swift` 対応済み）。

---

## 7. データ仕様（気象庁 高解像度降水ナウキャスト）
- 時刻一覧（必ずこれを読む。時刻は UTC、`yyyyMMddHHmmss`）
  - 実況 N1：`https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N1.json`
  - 予報 N2：`https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N2.json`
    （最新実況にもとづく **今〜+60分 / 5分刻み** の予想）
  - JSON 要素：`{ "basetime", "validtime", "elements": ["hrpns","hrpns_nd"] }`
- タイル URL
  `https://www.jma.go.jp/bosai/jmatile/data/nowc/{basetime}/none/{validtime}/surf/hrpns/{z}/{x}/{y}.png`
  - zoom：3〜10（最大10を使用）／タイル 256px ／無降水域は透明
- 解像度：250m（〜30分先）、1km（35〜60分先）。zoom10 の1ピクセル ≒ 100〜150m
- タイル座標（標準スリッピータイル）
  ```
  n = 2^z
  x = floor((lon + 180) / 360 * n)
  y = floor((1 - asinh(tan(lat_rad)) / π) / 2 * n)
  ```

---

## 8. 調整・キャリブレーション
- 色→mm/h の対応表（`JMANowcast.intensity`）は近似値。
  実タイルを採色してバンド境界を合わせると強度表示の精度が上がる。
- 点の安定化：対象ピクセルの 3×3 近傍を取り最大値を採用すると、
  境界ピクセルでの取りこぼしが減る（任意）。
- `desiredAccuracy` は `kCLLocationAccuracyKilometer` で十分（速い・粗くてOK）。

---

## 9. ビルド & 動作確認
- ターゲット OS：watchOS 10+（プッシュ更新を使う場合は 26+）
- 確認手順：
  1. 本体アプリ起動 → 位置情報「使用中のみ許可」
  2. 文字盤のコンプリケーション、または Smart Stack に円形ウィジェットを追加
  3. 雨天時／晴天時で表示（「◯分後に雨」「約◯分でやむ」「1時間は降りません」）を確認
- ウィジェットの位置情報許可は、ウィジェットギャラリーから追加する際に
  システムが許可プロンプトを出す挙動がある。

---

## 10. ライセンス / 出典
- 自作コードは MIT を想定（既存方針に合わせる）。
- 気象庁タイルは本来サイト表示用。**個人ウィジェットで1点を間欠取得する程度**なら現実的だが、
  配布・再配布時は出典「気象データ © Japan Meteorological Agency」を明記のうえ、
  公式配信（気象業務支援センターの GRIB2）や商用提供（日本気象／ハレックス等）の利用を検討。
- CDN に優しいアクセス（時刻JSON経由・過剰ポーリング回避）を徹底すること。