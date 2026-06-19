# 雨ナウキャスト Watch ウィジェット

Apple Watch の **`accessoryCircular`** ウィジェットで、現在地に雨が降る／やむタイミングを
watchOS 標準の「雨の時刻」ウィジェットのように表示します。

> 例: 「あと15分で雨」「約20分でやむ」「1時間は降りません」

データ源は気象庁の **高解像度降水ナウキャスト (hrpns)** の地図タイルです。

## 特徴

- 文字盤コンプリケーション / Smart Stack 用の円形ウィジェット
- 現在地の 1 時間ぶん（実況 + 5分刻みの予報）をタイルから採取して要約
- 降水の有無はタイルの透明度（alpha）で頑健に判定、強度は凡例カラーから近似
- ウォッチ単体で動作（iPhone コンパニオン不要）

## 構成

| ターゲット | 役割 |
|---|---|
| `RainNowcast Watch App` | 本体。起動時に位置情報「使用中のみ許可」をリクエスト＋出典表示 |
| `RainNowcastWidgetExtension` | ウィジェット本体（`RainNowcastWidget.swift`） |

## ビルド方法

1. **署名設定（Team ID）**
   このリポジトリには Apple Developer Team ID を含めていません。各自のチームを設定してください。

   ```sh
   cd RainNowcast
   cp Local.xcconfig.example Local.xcconfig
   # Local.xcconfig を開き DEVELOPMENT_TEAM を自分のチームIDに変更
   ```

   `Local.xcconfig` は `.gitignore` 済みです。`Config.xcconfig` から optional include
   されるため、ファイルが無くてもビルド構成は壊れません（その場合は Xcode の
   Signing & Capabilities でチームを選択）。

2. **実機で動かす場合**
   Apple Watch 側で **設定 > プライバシーとセキュリティ > デベロッパモード** を有効化し再起動。
   本体アプリを一度起動して位置情報「使用中のみ許可」を通してから、文字盤 / Smart Stack に
   ウィジェットを追加します。

3. 対応 OS: watchOS 10 以上（ウィジェットの APNs プッシュ更新を使う場合は 26 以上）

## データ・出典

**気象データ © Japan Meteorological Agency**

- 気象庁 高解像度降水ナウキャスト: <https://www.jma.go.jp/bosai/nowc/>
- 取得は必ず時刻一覧 JSON（`targetTimes_N1/N2.json`）を経由し、URL を推測しないこと
  （404 を量産し CDN キャッシュを汚染するため）。
- CDN に優しいアクセス（過剰ポーリングの回避）を徹底してください。
- 気象庁タイルは本来サイト表示用です。**個人のウィジェットで 1 点を間欠取得する程度**なら
  現実的ですが、配布・商用利用時は出典明記のうえ、気象業務支援センターの公式配信 (GRIB2) や
  商用提供サービスの利用を検討してください。

## ライセンス

自作コードは [MIT License](LICENSE)。気象データの権利は気象庁に帰属します。
