## 小會（修正：日記對話頁捲動對話氣泡時照片沒有縮小）— 2026/11/14

### 問題
- 使用者回報：AI 四輪對話頁捲動對話氣泡時，照片沒有縮小。
- 原因：
  1. 方向相反。對話頁每次有新訊息都會自動捲到最底部，長輩是「由下往上」看前面的氣泡（手指往下拉），原本卻寫成手指往上推才縮小。
  2. 網頁版用滑鼠滾輪、觸控板捲動時沒有 `dragDetails`，原本只看 `dragDetails`，所以永遠不會縮小。

### 修正後的行為（照規格 1c）
- 往上看前面的對話 → 照片縮成標題旁的小縮圖。
- 捲回最底部（最新的問題）→ 照片展開；點縮圖也能展開。
- 新訊息出現時程式自動捲到底**不會**展開照片，維持使用者原本的大小（錄音時聚焦模式本來就會放大顯示照片）。
- 聚焦模式（錄音中、暫停）不處理捲動，跟原本一樣。

### 修改檔案
- `diary_chat_page.dart`
  - `_onChatScroll` 改方向。新增 `_isUserScroll`：除了手指拖曳，也接受滑鼠滾輪和放手後的慣性（`userScrollDirection` 不是 idle）；程式的 `animateTo` 不算。
  - iPhone 放手後從邊界彈回來的那段不算（`_ignoringBounce`），避免在最上面往下拉、放手彈回時照片又展開，或捲到底過頭、彈回時照片又縮小；慣性往下衝到底時算回到最新、照片展開。
  - 新增 `_keepDistanceFromBottom`：照片縮放讓對話區變高、變矮時，維持離最底部的距離不變（用 `correctBy`，不會打斷正在拖曳的手指）。不然往上捲一點、照片縮小後，對話區變大會突然「到底」，再往下捲一點照片又展開，一縮一放。

### 測試
- `test/features/diary/pages/diary_chat_page_test.dart`：捲動相關改寫並新增，Android、iPhone 兩種捲動方式各跑一次：
  - 對話短時往下拉縮小、往上推展開、點縮圖展開。
  - 對話長時往上捲縮小，捲一半往下維持縮小，捲回最底部展開。
  - 慣性甩回最底部展開。
  - 網頁版滑鼠滾輪。
- 這支測試檔共 13 個全過。

## 小會（日記對話頁錄音時，整個畫面模糊變暗）— 2026/11/14

### 本次異動目標
- 修正第 1c 項聚焦模式的畫面：原本黑色疊層只蓋對話區，標題列沒蓋到；錄音區的黑底只有按鈕那一塊，寬螢幕（網頁版）兩側還是白的；背景也沒有模糊，後面的照片和問題氣泡跟疊層上的重疊在一起，看起來很亂。
- 改成錄音中（含暫停）整個畫面都蓋上「背景模糊＋黑色 50%」，只留照片、目前的 AI 問題和錄音鈕。

### 修改檔案
- `diary_chat_page.dart`：
  - 新增 `_buildFocusLayer`（`BackdropFilter` 模糊 sigma 8＋黑色 50%，淡入淡出 200ms），標題列和對話區共用。
  - 標題列外包一層 `Stack`，聚焦時一起蓋上疊層；聚焦時返回鍵被擋住，不會錄到一半不小心離開。
  - 錄音區黑底改成撐滿整個寬度（`width: double.infinity`），body 的 `SafeArea` 拿掉底部，改由錄音區自己補手機底部安全距離，黑底一路蓋到螢幕最下面。
  - 原本的 `_buildFocusOverlay` 改名 `_buildFocusContent`，只放照片和問題。

### 測試
- `test/features/diary/pages/diary_chat_page_test.dart` 新增 1 個：寬螢幕 1000px 錄音時標題列與對話區各有一層模糊、錄音區黑底寬度 1000 且到螢幕底、返回鍵被擋住。
- 手動：網頁版建置後用 Chrome 看 390px 與 1000px 寬，錄音中整個畫面模糊變暗。

## 小會（動態牆顯示親友的語音加油，可以播放、轉文字）— 2026/11/14

### 本次異動目標
- 介面調整第 1b 項（App 端）：親友在分享頁錄的「語音加油」（最長 10 秒，照比賽版 futureQ），長輩在動態牆展開貼文就能聽，並可以按「轉文字」看內容。
- 分享頁的錄音畫面與後端 API 由**後端組處理**；這裡先把 App 端做好，後端還沒有 API 前，`voice_reply_count` 是 0，畫面跟原本一樣。
- 原本 `social_service.dart` 的語音加油是「分享組（Wen）處理、請勿修改」的假資料，已確認改由這次一起做。

### 需要後端提供的 API
| API | 用途 | 回應 data |
|---|---|---|
| `GET /api/social/posts/<post_id>/voice-replies/` | 作者本人看某貼文的語音加油（新的在前） | `{"items": [{"voice_reply_id", "nickname", "audio_url"（簽名網址）, "duration_sec", "transcribed_text"（還沒轉是 ""）, "created_at"}]}` |
| `POST /api/social/voice-replies/<id>/transcribe/` | 轉文字（Whisper，轉過就存起來，第二次直接回傳） | `{"voice_reply_id", "transcribed_text"}` |
| `GET /api/social/posts/` 的 `voice_reply_count` | 改成實際數量（目前寫死 0） | — |
| 通知 `notification_type: "voice_reply"` | 收到語音加油，`target_url` 同留言 `/posts/<id>/` | — |
- 錯誤：`TRANSCRIBE_FAILED`（502）的 `message` 會直接顯示給長輩，建議「這段語音暫時轉不出文字，可以先直接播放聽聽看」。

### 修改檔案
- `post_model.dart`：`VoiceReplyModel` 改成上面的欄位（`nickname`、`duration_sec`…），`senderName` 保留給舊欄位名；沒有暱稱時顯示「親友」；新增 `isTranscribed`、`copyWith`。
- `social_service.dart`：`getVoiceReplies`、`transcribeVoiceReply` 改接真 API（轉文字 timeout 放寬到 60 秒）；刪除沒人用的假函式 `shareDiary`、`submitVoiceReply`。
- 新增 `social/widgets/voice_reply_section.dart`：「語音加油（N）」區，每則暱稱、時間、秒數、播放鍵（共用日記的 `AudioPlayerWidget`）、「轉文字」按鈕（轉換中顯示 loading；成功後顯示「…」文字並隱藏按鈕；失敗顯示後端訊息、按鈕保留可以再試）；讀取失敗可以重新載入。
- `post_card.dart`：展開區在留言上方放語音加油區，`voice_reply_count` 大於 0 才顯示。
- `notification_model.dart`：`voice_reply` 通知也能點進貼文。

### 測試
- 新增 `test/features/social/widgets/voice_reply_section_test.dart`（8 個）：model 解析、舊欄位相容、API 網址、列表顯示、轉文字成功、已轉過直接顯示、轉文字失敗、讀取失敗。
- `notification_model_test.dart`：`voice_reply` 也會跳轉。
- `flutter test` 只有 `cooking_prep_playthrough_test.dart` 的 2 個既有 BUG 測試失敗。

### 還沒做／還沒測
- 分享頁（後端網頁）的錄音、送出、建議句提詞卡：後端組處理（規格見 Google Doc《介面調整與功能增修規格》1b）。
- 後端 API 上線後實測：分享頁錄一段 → 動態牆出現「語音加油（1）」→ 播放 → 轉文字 → 再開一次直接顯示文字；通知點進貼文。

## 小會（設定頁新增「每日提醒」，可以選提醒時間）— 2026/11/14

### 本次異動目標
- 介面調整第 3 項：設定頁新增提醒，使用者可以選每天什麼時間提醒進 App。
- 用**手機本地通知**（flutter_local_notifications），不需要後端、不需要網路；設定只存在這支手機（shared_preferences），換手機要重設。網頁版不支援。

### 行為
- 預設關閉；打開時先跟使用者要通知權限，沒給就把開關關回去，提示「需要允許通知才能提醒您，請到手機的「設定」開啟通知」。
- 預設時間晚上 8:00，點「提醒時間」用時間選擇器改；顯示成「晚上 8:00」「上午 9:30」這種長輩好懂的寫法。
- 每天同一時間跳通知：標題「憶智防線」、內文「今天也來動動腦吧！寫一篇聲影日記或玩一場遊戲 🌱」，點了打開 App。
- 關閉時取消排程，時間保留，下次打開沿用。
- App 每次啟動依上次的設定重新排程；Android 重新開機後也會重新排程。
- 網頁版：開關停用，說明「網頁版不支援提醒，請在手機 App 設定」。

### 修改檔案
- `pubspec.yaml`：新增 `flutter_local_notifications ^22.3.3`、`timezone`、`flutter_timezone`。
  - **沒有用最新的 23.x**：23.0 起要求 Android `compileSdk 37`，Flutter 預設是 36，組員環境可能 build 不起來；22.x 用 36，不用改 SDK 版本。
- 新增 `core/services/reminder_service.dart`：
  - `ReminderService`：讀寫設定、`enable`（要權限）／`disable`／`updateTime`、`init`（啟動時重新排程，失敗只記錄不擋啟動）、`formatTime`、`nextInstanceOf`。
  - `LocalNotificationScheduler`：實際排程（`zonedSchedule` + `DateTimeComponents.time` 每天重複；`inexactAllowWhileIdle`，不需要精準鬧鐘權限，誤差幾分鐘可接受）；取不到手機時區時用 `Asia/Taipei`。iOS 初始化時不主動要權限，等使用者打開提醒才問。
- `main.dart`：啟動時呼叫 `ReminderService.init()`（不等它，不影響啟動速度）。
- `settings_screen.dart`：「顯示」與「帳號」之間新增「提醒」區塊（每日提醒開關＋提醒時間）。
  - 順手修正：三張設定卡片的 `ListTile`／`SwitchListTile` 放在有底色的 `Container` 裡，Flutter 會報「水波紋被蓋住」的 debug 警告（原本就有），改成卡片內包一層透明 `Material`。因為多一層縮排，diff 看起來很大，用 `git diff -w` 看實際改動。
- Android：`AndroidManifest.xml` 加 `POST_NOTIFICATIONS`、`RECEIVE_BOOT_COMPLETED` 權限與排程／開機 receiver；`build.gradle.kts` 開啟 core library desugaring（套件要求）。
- iOS：`AppDelegate.swift` 設定 `UNUserNotificationCenter` delegate（App 開著時也能顯示通知）。

### 測試
- 新增 `test/core/services/reminder_service_test.dart`（10 個，假的排程器）：時間顯示、下一次提醒是今天或明天、預設值、打開／沒權限／關閉／改時間、啟動時重新排程、網頁版不支援。
- 新增 `test/screens/settings_reminder_test.dart`（4 個）：打開後排程並提示、沒權限關回去、已打開時關閉、網頁版停用。
- `flutter build web` 成功；`flutter test` 只有 `cooking_prep_playthrough_test.dart` 的 2 個既有 BUG 測試失敗。

### 還沒測（需要實機）
- 這台電腦沒有 Android SDK，**沒有 build 過 Android**：請有 Android 環境的組員 `flutter run` 確認 desugaring、manifest 沒問題。
- iOS 也**沒有 build 成功**：`flutter build ios --simulator` 在「Prepare Flutter Framework」這一步就失敗（Flutter 工具說 Flutter.framework 不含 arm64／x86_64，但 lipo 顯示兩個都有），還沒編到 App 的程式碼，應該是這台電腦 Xcode 27 與 Flutter 工具的問題。`AppDelegate.swift` 的寫法照套件範例（`self as UNUserNotificationCenterDelegate`）。
- 另外：build iOS 時因為 `flutter_tts` 不支援 Swift Package Manager，Flutter 會自動把專案改成 CocoaPods（改 `project.pbxproj`、workspace、產生 `Podfile.lock`），這是原本就會發生的，這次沒有 commit 這些自動產生的變動。
- 手機實測：設 2 分鐘後提醒、App 退到背景，確認收到通知、點了打開 App；Android 重開機後仍會提醒；拒絕權限時開關會關回去。

## 小會（儀表板「小提醒」：某場表現特別低時提醒多注意）— 2026/11/14

### 本次異動目標
- 介面調整第 2 項：某一場遊戲的分數跟平常比起來是極端值時，儀表板要出現提示，建議多注意一下。
- 判斷和文案都由後端做（前端只顯示）：`GET /api/dashboard/` 的 data 新增 `alerts`。規格：近 14 天內，某款遊戲有一場 `z_score ≤ -1.5`（跟自己平常比明顯偏低）就給一筆，每款只取最近一場、最多 5 筆，只提示偏低。**後端由後端組處理**，還沒加 `alerts` 之前，前端畫面跟原本一樣。

```json
"alerts": [
  {"game_id": "market_shopping", "game_title": "市場買菜",
   "dimension": "math", "dimension_label": "數學",
   "played_at": "2026-11-12T15:30:00+08:00", "display_score": 18,
   "message": "11/12 玩「市場買菜」的表現比平常低一些，可能當天比較累，建議多注意一下，休息後再玩一次看看。"}
]
```

### 修改檔案
- `dashboard_models.dart`：新增 `DashboardAlert`；`DashboardOverview` 新增 `alerts`（後端沒給時是空陣列；沒有文案的提醒不顯示）。
- 新增 `dashboard/widgets/dashboard_alert_card.dart`：「小提醒」卡片，逐筆顯示後端文案，每筆附「去玩一次「遊戲名」」。
- `dashboard_palette.dart`：新增 `alertBackground`／`alertForeground`，跟「多練習」同一組柔和暖黃色，不用紅色。
- `dashboard_page.dart`：狀態卡片與雷達圖之間放小提醒（沒有就不顯示）；「去玩一次」用 `openGame` 開遊戲，回來後重新整理儀表板。

### 測試
- 新增 `test/features/dashboard/dashboard_alert_test.dart`（5 個）：解析 alerts、舊版後端沒有欄位、沒有文案不顯示、卡片淺色／深色顯示文案與「去玩一次」。
- `dashboard_diary_a11y_test.dart` 新增「小提醒」淺色／深色／高對比三個畫面，沒有新的無障礙問題。

### 還沒測
- 等後端加上 `alerts` 後，用一場 `z_score` 改成 -1.8 的資料確認卡片出現，按「去玩一次」進對應遊戲，回來後重新整理。

## 小會（動態牆貼文可以分享給親友）— 2026/11/14

### 本次異動目標
- 介面調整第 1a 項：原本只有日記完成頁能分享連結，貼文進了動態牆之後就分享不出去。這次在動態牆的貼文卡片加「分享」按鈕。
- 動態牆上的貼文都是按過「分享到動態牆」才產生的，`share_url` 已經在 `GET /api/social/posts/` 裡（只有作者本人拿得到），所以**分享出去不用再呼叫後端**，也不會再發一次「樂於分享」成就。

### 修改檔案
- 新增 `diary/widgets/share_link_sheet.dart`：
  - `ShareLinks`：分享文字（有邀請文字用邀請文字，沒有就標題＋內文，最後接連結）、LINE／Facebook 網址、複製連結，完成頁與動態牆共用。
  - `showShareLinkSheet`：從下方滑出的面板，三個大按鈕「傳到 LINE」「分享到 Facebook」「複製連結」，提示訊息顯示在原本頁面。
- LINE 網址改用 `https://line.me/R/msg/text/?…`（比賽版 futureQ 實測 `R/share` 會跳到 LINE 首頁），完成頁一起改。
- `diary_finish_page.dart`：LINE、Facebook、複製連結改呼叫 `ShareLinks`，按鈕與提示文字不變；`showNewAchievements` 等其他行為不動。
- `post_card.dart`：留言數標籤左邊加「分享」標籤（同樣式），`is_share_enabled` 為 true 且有 `share_url` 才顯示，點了開分享面板。

### 測試
- 新增 `test/features/diary/widgets/share_link_sheet_test.dart`（5 個）：分享文字三種情況、LINE 用 `R/msg/text`、Facebook 網址編碼。
- 新增 `test/features/social/widgets/post_card_share_test.dart`（4 個）：有連結顯示「分享」並開面板、複製連結進剪貼簿並提示、別人的貼文／分享關閉時不顯示。
- `flutter test` 只有 `cooking_prep_playthrough_test.dart` 的 2 個既有 BUG 測試失敗。

### 還沒測
- 手機實機：動態牆按分享 → 傳到 LINE 會開 LINE 選聊天室、Facebook 分享頁、複製連結後貼上。

## 小會（聲影日記對話頁：往上滑照片縮小、錄音聚焦模式）— 2026/11/14

### 本次異動目標
- 介面調整第 1c 項：AI 四輪對話頁的照片和錄音區佔太多高度，會擋住對話氣泡。
  - 往上滑對話氣泡時，照片縮成標題旁的小縮圖，對話區變大。
  - 開始錄音時進入「聚焦模式」：畫面蓋上黑色 50% 疊層，照片和目前的 AI 問題放在正中央，錄音按鈕在疊層上；結束錄音就回到原本的對話畫面。

### 行為
| 狀態 | 畫面 |
|---|---|
| 一般 | 標題＋說明＋照片（高 140）＋對話氣泡＋錄音區 |
| 手指往上滑對話氣泡 | 照片縮成 56×56 縮圖放在標題左邊，說明文字收起（動畫 200ms） |
| 點縮圖，或在最上面再往下拉 | 照片放回原本大小 |
| 錄音中、暫停中 | 聚焦模式：黑色 50% 疊層，照片完整顯示（不裁切，最高佔對話區 55%）＋目前的 AI 問題置中；計時、提示、波形、完成鍵改成白色 |
| 按完成送出、重新錄製（回到待機） | 疊層淡出，回到原本畫面並捲到最底 |

- 原本規格寫「捲回最底部就展開」，但對話平常就停在最底部，照片會一縮就馬上彈回來，所以改成「點縮圖或在最上面往下拉」才展開。
- 「這題跳過」「生成日記」本來就只在待機時出現，聚焦模式不會看到。

### 修改檔案
- `diary_chat_page.dart`：
  - 對話區改成 `Stack`：底層是原本的標題區＋對話列表，上層是聚焦疊層（只在錄音中建內容，避免問題文字重複）。
  - 錄音區不搬進疊層，維持同一個 `RecordButton`（錄音不會中斷）；聚焦時錄音區底色也變成同樣的黑色 50%，看起來整個畫面一起變暗。
  - 對話列表改成 `AlwaysScrollableScrollPhysics`，對話還很短時也收得到「往上滑」。
  - 縮圖整塊都可以點；照片載入失敗時顯示灰色的照片圖示。
  - 這個檔案順便跑了 `dart format`，所以 diff 裡有少量排版變動。
- `record_button.dart`：新增 `onDarkOverlay`，在疊層上時計時數字、提示文字、波形、完成鍵、「重新錄製」改成白色。

### 測試
- 新增 `test/features/diary/pages/diary_chat_page_test.dart`（7 個，用假的錄音 platform）：一開始沒有疊層、往上滑縮小與點縮圖放大、在最上面往下拉展開、沒有照片時不縮、錄音中與暫停出現疊層並顯示問題、重錄與完成送出後離開聚焦、360×640 小手機聚焦時不溢版。
- `flutter test` 只有 `cooking_prep_playthrough_test.dart` 的 2 個「教學頁橫向溢出」BUG 測試失敗，原本就失敗，與這次無關。

### 還沒處理
- 對話頁在橫向手機（780×360）原本就會溢版約 190px（標題區＋錄音區比畫面高），這次沒有動，之後可以另外處理。
- 實機確認：Android 與 iOS 各錄一次，聚焦時照片與問題清楚、錄音不中斷。

## 小會（大腦訓練遊戲卡片顯示認知維度）— 2026/11/14

### 本次異動目標
- 介面調整第 6 項：首頁與「全部遊戲」頁的每張遊戲卡片，在名稱上方顯示對應的認知維度（注意力、工作記憶、執行功能、視覺空間、數學）。
- 維度由後端 `GET /api/home/games/` 新增的 `dimension`、`dimension_label` 提供（後端分支 `feature/game-dimension-1114`，對應關係跟儀表板雷達圖同一份），前端不寫死。

### 修改檔案
- `home_models.dart`：`HomeGame` 新增 `dimension`、`dimensionLabel`（沒給或空字串時是 null，舊版後端不會壞）。
- `game_card.dart`：
  - 名稱上方新增 `_DimensionBadge`（🧠 圖示＋維度名稱，主色淡底），`dimensionLabel` 是 null 時不顯示；深色、高對比各有配色。
  - 卡片高度改用 `GameCard.cardHeight`：標準字體維持 130，字體放大時跟著加高，標籤＋名稱才放得下。
  - 順手修正原本就有的溢版：字體「特大」「超大」時，360 寬的手機上「本週還沒玩」標籤會超出卡片右邊（6～15px），改成放不下時等比例縮小。
- `all_games_page.dart`：格子高度改用 `GameCard.cardHeight`，並改成也監聽字體大小。
- `home_service.dart`：假資料的遊戲列表補上維度。

### 測試
- `home_models_test.dart` 新增 2 個：讀維度、沒給維度時是 null。
- 新增 `test/features/home/widgets/game_card_test.dart`：顯示名稱與維度、沒有維度不顯示標籤、字體等級 1～5 在 360 寬手機上都不溢版、字體放大時卡片加高。
- `flutter test` 全部 323 個中，只有 `cooking_prep_playthrough_test.dart` 的 2 個「教學頁橫向溢出」BUG 測試失敗，`fix/backend` 上原本就失敗，與這次無關。
## 小會（會員頁連續天數火苗）— 2026/11/14

### 本次異動目標
- 介面調整第 5 項：會員頁顯示「已經連續幾天」的火苗。
- 天數直接用後端 `GET /api/users/me/stats/` 的 `streak_days`（連續有玩遊戲或寫日記的天數；今天還沒活動但昨天有，延續昨天的天數），後端不用改。這支 API 原本就有，前端之前沒接。
- 點數規格的原則是「成就只算累積、不算連續」，所以火苗只是顯示：不綁成就、不發點數，0 天不顯示「0 天」，改成鼓勵句。

### 修改檔案
- 新增 `profile/models/user_stats.dart`：`UserStats.fromJson`（streak_days、active_day_count、session_count、diary_count、joined_at）。
- `profile_service.dart`：新增 `getStats()`，共用原本的 `_parse`（統一格式取 `data`、401 丟 `NotLoggedInException`）。
- `profile_page.dart`：
  - 頭像下方、「我的資料」上方新增 `_StreakCard`。
  - 文案：0 天灰色火苗「今天點燃火苗吧！」；1～6 天橘色「已連續 N 天」；7 天以上火苗加大、橘紅色「已連續 N 天 🎉／太棒了，繼續保持！」；底部小字「累計活動 N 天」（0 天時不顯示）。
  - 統計和會員資料分開讀，統計失敗只是不顯示卡片；下拉重新整理會一起更新。

### 測試
- `profile_page_test.dart` 新增 4 個測試：一般天數、7 天以上、0 天不出現「0 天」、統計讀不到時不顯示火苗且會員資料照常。假後端加上 `/api/users/me/stats/`。
## 小會（首頁點數可以點，進點數商城）— 2026/11/14

### 本次異動目標
- 介面調整第 4 項：首頁右上角的點數標籤原本不能點，改成點了進點數商城，跟「逛商城」浮動按鈕同一個行為。
- 和點數規格的差異：規格「前端 §3 畫面一覽」寫的是「點擊進入成就牆」，這次依需求改成點數商城；成就牆入口維持在會員頁「我的成就與點數」。

### 修改檔案
- `greeting_section.dart`：
  - `GreetingSection` 新增 `onPointsTap`。
  - `_PointsBadge` 外層改成 `Material` + `InkWell`（有水波紋），文字後面加 `›`（`Icons.chevron_right`）提示可以點；讀螢幕念「點數 N 點，前往點數商城」。
  - 沒傳 `onPointsTap` 時跟原本一樣，不能點、沒有 `›`。
- `home_screen.dart`：傳入原本的 `_openShop`（push `ShopPage`，回來時重新整理點數）。

### 測試
- 新增 `test/features/home/widgets/greeting_section_test.dart` 2 個測試：有 callback 時顯示 `›`、點擊會呼叫、語意標籤正確；沒有 callback 時不顯示 `›`。
- `app_shell_a11y_test.dart` 照常通過。

## 小會（日記「跳過本輪」改接真實 API）— 2026/11/14

### 本次異動目標
- 後端 PR #117 新增 `POST /api/diary/{id}/replies/skip/`，取代前端一直回假資料的 `skipReply`。同批 PR #116 把 `memory_recall` 的名稱統一成「料理準備」（只是 `name`／`title` 字串變了，前端沒有邏輯依賴名稱，不用改）、#115 是後端文件修正。

### 修改檔案
- `diary_service.dart`：
  - `skipReply` 改打真實 API（body 只有 `round_index`，不再送 `force`），回應形狀與錄音相同（沒有 `transcript`、`audio_url`）。
  - 錄音與跳過共用 `_parseReplyResponse`：409 `ROUND_ALREADY_ANSWERED`（網路重試）一律改抓日記詳情還原該輪結果。
  - 400 `SKIP_NOT_ALLOWED`（日記完全沒錄過內容卻要跳過最後一輪）等錯誤直接丟 `ApiException`，聊天頁原本的 catch 會顯示後端的中文訊息。
- 聊天頁沒有改：跳過按鈕原本只在「已回覆 ≥ 2 輪」後才出現，所以不會真的觸發 `SKIP_NOT_ALLOWED`（後端是「前三輪都跳過」才擋）；`is_finalizable` 以後端為準（跳過的不算有內容）。

### 測試
- 新增 7 個測試（`flutter test` 306 → 313 個全部通過）：URL 與 body、成功解析（含第 4 輪 `is_done`）、`is_finalizable` 以後端為準、`SKIP_NOT_ALLOWED` 與其他錯誤碼、409 還原、沒 token 在本機就擋下（不再是假資料）。改回假資料時 6 個會失敗。

### 還沒測
- 對真實後端按「這題跳過」：第 3、4 輪各跳一次，確認進入下一題或生成頁，日記詳情的 `replies[]` 有 `is_skipped: true`，生成的日記不含被跳過的那一輪。

## 小會（配合後端 fix/global：登入 429、日記上傳限制）— 2026/11/14

### 本次異動目標
- 後端 `fix/global`（PR #109～#114，已合併）在 F1～F14 之上又做了 G1、G3、G4（精簡版）、G9 與日記上傳限制，逐項對照前端後，只有 G3 登入、日記照片上傳需要改。
- 直接在 `fix/backend` 上做（PR #25 的後續），一項一個 commit。

### 逐項結論
| 後端項目 | 前端 |
|---|---|
| G1 `SECRET_KEY`／`DEBUG`／CORS 改讀環境變數 | 沒有前端程式碼。**Flutter Web 的網址要請後端列進 `DJANGO_CORS_ALLOWED_ORIGINS`**，手機 App 不受影響 |
| G3 登入／註冊／改密碼／刪帳號加次數限制（429） | 登入要改（見下）；註冊原本就走 `_toApiException`，補測試確認；改密碼、刪帳號前端沒有這些功能 |
| G4 改密碼後舊 token 全部作廢 | 不用改：前端沒有改密碼功能；部署後所有人會 401，現有行為（清掉 token、回登入頁）已符合，前端沒用 refresh token 也不會無限重試。之後若做改密碼，成功後要用回應的 `data.access`／`data.refresh` 覆蓋本機 token |
| G9 OpenAI timeout／重試 | 後端內部，不用改 |
| 日記上傳限制（照片 10MB、錄音 25MB） | 照片要改（見下）；錄音原本就帶 `audio/webm`，不動 |
| F14 點數與成就 | 欣紜的 `feature/points-achievements-1111` 已做，這個分支不重做 |

### 修改檔案
- 登入 429（G3）：
  - `auth_service.dart`：`login()` 遇 429 改丟 `ApiException`（帶 `Retry-After`）。原本非 401 的失敗都丟「登入失敗，請稍後再試一次」，使用者不知道被鎖住。
  - `error_message.dart`：新增 `friendlyLoginErrorMessage`，429 顯示「登入次數太多了，請約 N 分鐘後再試。這段時間即使密碼正確也無法登入」（後端被鎖住時密碼正確也回 429，避免長輩以為密碼不對一直重試）；其他錯誤照舊。
  - `login_page.dart`：catch 區塊改用上面的函式，只動這一處（組員分支改的是外層 `SingleChildScrollView`，位置不重疊）。
- 日記照片上傳：
  - `diary_service.dart`：`createDiary` 明確帶 Content-Type（`photoMediaType`：選圖器的 `mimeType`（image/*）→ 副檔名 → 預設 `image/jpeg`）。後端靠副檔名或 Content-Type 判斷是不是圖片，Flutter Web 檔名常沒有副檔名，會被判 `INVALID_IMAGE`。
  - `diary_upload_page.dart`：失敗提示原本寫死「照片儲存失敗」，後端 `IMAGE_TOO_LARGE`、`INVALID_IMAGE` 的中文訊息顯示不出來；改用 `photoUploadErrorMessage`，有錯誤碼的 4xx 直接顯示後端訊息，連不上與 5xx 維持原本文字。

### 測試
- 新增 27 個測試（`flutter test` 279 → 306 個全部通過，`flutter analyze lib` 沒有 error）：
  - `auth_service_test.dart`：登入 429（有／無 `Retry-After`、`loginAndSaveToken` 不存 token）、401 與 500 訊息不變、200 存 token；註冊 429、`USERNAME_TAKEN` 不受影響。
  - `error_message_test.dart`：登入訊息有／無 `Retry-After`、一般錯誤沿用。
  - `diary_service_test.dart`：`photoMediaType`（mimeType、大小寫、副檔名、Web 無副檔名）、`createDiary` 的 multipart 真的帶 `content-type`、400 `IMAGE_TOO_LARGE`、`photoUploadErrorMessage`。
- 每組新測試都確認過「還原修正後會失敗」。

### 注意事項（給合併的人）
- **和 `feature/points-achievements-1111` 會有衝突**（PR #25 與該分支都改到）：`diary_model.dart`（我改 `photo_url` 那行，對方在 `DiaryModel.fromJson` 同一區塊加 `rewards:`）、`change.md` 最上方；`diary_finish_page.dart` 位置不同，應可自動合併。後合併的人先 `merge upstream/dev` 解衝突，解 `diary_model.dart` 時 `photoUrl` 要保留 `as String? ?? ''`。
- **遊戲名稱待確認**：後端把 `memory_recall` 改成「記憶配對」，首頁遊戲卡片直接顯示後端的 `name`，但前端遊戲內與組員 change.md 寫的是「料理準備」，兩邊不一致。前端沒有邏輯依賴名稱字串，要等組員與後端決定正式名稱。

### 沒有動的地方
- 還沒對真實後端實測：同一帳號連續輸錯 10 次密碼，第 11 次應出現等待提示，之後即使輸入正確密碼也一樣被擋；Flutter Web 選一張沒有副檔名的照片建立日記，不應再出現「不是圖片」。
- refresh token 的儲存與自動換發：後端沒有要求，改動大，先不做。
- 點數紀錄頁、儀表板／週報／分享日記跳成就視窗：F14 的選做項目，欣紜註明未做。

---

## 欣紜（點數商城：我的票券、票券 QR code、demo 假扣點、品牌 logo、熱門兌換改版）— 2026/11/14

### 本次異動目標
- 點數商城換完券後沒有地方看，新增「我的票券」（卡夾包）。點票券出示 QR code，螢幕自動調到最亮，方便店員掃描。
- 後端還沒有兌換 API，全部是假資料、僅示意，所有票券共用同一組 QR code。
- demo 要給評審看兌換後點數有減少，先做「假扣點」：只在 App 裡扣，後端點數沒變。

### 新增套件
- `qr_flutter`：畫 QR code。
- `screen_brightness`：調整 App 螢幕亮度（只調這個 App，不改系統設定，不需要權限）。網頁版不支援，自動略過。

### 新增檔案
- `lib/features/rewards/services/mock_redeem_points.dart`：假扣點。記下這次開 App 以來兌換花掉的點數（`spent`，可監聽），`apply()` 把後端總點數扣掉這個數字（最少 0）。
- `lib/features/shop/pages/my_tickets_page.dart`：我的票券。直向票券卡片（品牌圖示、票券名稱、品牌、兌換日期），新兌換的在前；沒有票券時顯示「還沒有兌換的票券，去點數商城看看吧」。點票券進 QR code 頁。
- `lib/features/shop/pages/ticket_qr_page.dart`：票券 QR code 頁。上方票券圖片（商品還沒有圖片，先用品牌圖示）、名稱、品牌，正中央 QR code（固定白底黑碼，深色模式也一樣），下方「請出示此畫面給店員掃描」。進來時螢幕調到最亮，離開時恢復原本亮度。

### 修改檔案
- `lib/features/shop/models/shop_models.dart`：新增 `MyTicket`（換到的商品、兌換時間、QR code 內容）。
- `lib/features/shop/services/shop_service.dart`：新增 `getMyTickets()`、`redeemMock()`、`resetMock()`。預設 2 張假票券（星巴克中杯拿鐵券、全聯 100 元購物金），共用 `mockQrData`。`redeemMock()` 先確認點數夠（不夠丟出「點數還不夠，再玩幾場就能換囉」），再假扣點、加票券。
- `lib/features/shop/pages/shop_page.dart`：綠色點數卡片下方新增白色外框「我的票券」按鈕；監聽假扣點，兌換後重新讀點數。品牌按鈕拿掉白色卡片底，改成圓形品牌 logo（直徑 84，白底、深色模式也一樣）＋品牌名稱，圖片讀不到時顯示原本的圖示。
- `lib/features/shop/widgets/shop_item_grid_card.dart`（新增）：熱門兌換的直向商品卡片。上方正方形圖片（商品沒有圖片時用品牌 logo：全聯填滿，星巴克、農會整張放進去留白），下方商品名稱（最多兩行）、品牌、點數、兌換按鈕；兌換流程同 `ShopItemCard`。
- `lib/features/shop/pages/shop_page.dart`：熱門兌換從一張一列改成一排兩張（`IntrinsicHeight`，同一排一樣高，點數和按鈕貼底），最後一排只有一張時右邊留空。品牌頁維持原本的列表卡片。
- `lib/features/shop/widgets/shop_brand_logo.dart`（新增）：圓形品牌 logo 共用元件（白底，星巴克整張放進去留白邊，全聯、農會裁成圓形，讀不到圖片時顯示品牌圖示）。
- `lib/features/shop/pages/shop_brand_page.dart`、`lib/features/shop/widgets/shop_item_card.dart`：品牌頁版面不變，標題旁的圖示與商品卡片左側圓圈改成品牌 logo（商品有自己的圖片時改顯示商品圖）。
- `assets/images/shop/`（新增）：星巴克、全聯、農會 logo，`pubspec.yaml` 加上這個資料夾。
- `lib/features/shop/models/shop_models.dart`：`ShopItem` 新增 `imageAsset`（商品圖片，目前都是 null）與 `displayImage`（沒有商品圖時用品牌 logo）。`ShopBrand` 新增 `logoAsset`／`logoAssetFor()`、`logoFit`、`logoScale`。星巴克本身是圓形，整張放進去留白邊；全聯（長方形旗幟）、農會（圓角方形）裁成圓形，農會稍微放大避免四角露白。
- `lib/features/shop/pages/shop_brand_page.dart`：點數改存在頁面狀態，監聽假扣點，兌換後重新讀點數，「點數不足」跟著更新。
- `lib/features/shop/widgets/shop_item_card.dart`：確認視窗多一行「兌換後剩下 N 點」；按「確定兌換」後假扣點並把券加進我的票券，SnackBar「兌換成功！扣除 N 點，已放進『我的票券』」，按「查看」直接打開我的票券。熱門兌換與品牌頁都適用。
- `lib/features/rewards/services/rewards_service.dart`：`getSummary()` 的 `total_points` 扣掉假扣點，首頁、成就牆、商城點數一致。
- `lib/features/rewards/models/rewards_models.dart`：結算回傳的 `total_points`（點數卡片「目前共有 N 點」）也扣掉假扣點。
- `lib/features/auth/services/logout_helper.dart`：登出時呼叫 `ShopService.resetMock()`，假扣點歸零、票券回到預設 2 張，換帳號不會看到上一個人的。

### 目前狀態
- `flutter analyze`（shop、rewards、logout_helper、home_screen）：0 issue。
- 尚未在 Chrome、Android 模擬器實際操作確認（亮度只有手機上看得出來）。

### 已知延後項目
- 假扣點、假票券都存在記憶體（static），重開 App 會回到後端的點數與預設 2 張票券；token 過期被導回登入（不是按登出）時不會清掉。
- 後端點數沒有真的扣：點數紀錄不會有兌換那一筆、換手機登入看不到扣點。等後端兌換 API 做好後刪除 `mock_redeem_points.dart`，改用後端回傳的 `total_points`。

---

## 欣紜（點數與成就接後端測試；料理準備教學頁、登入頁溢版修正）— 2026/11/14

### 本次異動目標
- 用筠淇的後端（`rewards_demo` 測試帳號）對接點數與成就的查詢 API。
- 依 11/4 會議「之前自己負責哪部分就自己處理」，用 Pixel 8 模擬器檢查溢版並修正。

### 修改檔案
- `lib/features/rewards/services/rewards_service.dart`：假資料開關 `useMockRewards` 改成 `false`，首頁點數、成就牆、商城點數改讀後端。
- `lib/features/game/cooking_prep/widgets/cooking_prep_tutorial_dialog.dart`：教學頁共用外框 `_TutorialCard` 的示範圖改用 `FittedBox(fit: BoxFit.scaleDown)` 包住，空間不夠時等比例縮小（空間夠維持原本大小）。修正橫向手機第 1 頁「基本玩法」`BOTTOM OVERFLOWED BY 40 PIXELS`，三頁教學一起修好。由我直接幫忙修改，只改示範圖區，沒動文字與按鈕。
- `lib/features/auth/pages/login_page.dart`：外層 `Padding` 改成 `SingleChildScrollView`，修正鍵盤跳出時「登入」按鈕被擠出畫面（`BOTTOM OVERFLOWED BY 11 PIXELS`），內容放不下時可以往上滑。

### 目前狀態
- 用 `rewards_demo`（總點數 165、已解鎖 7 個成就）測試：首頁點數、成就牆（已解鎖數、三類切換、已解鎖日期、未解鎖進度）、商城點數皆正常。
- Pixel 8 模擬器檢查自己負責的頁面（註冊、登入、忘記密碼、歡迎頁、首頁、全部遊戲、動態牆、冰箱清點、商城、成就牆），除上述兩處外沒有溢版。
- **用新註冊帳號玩完五款遊戲**：成就牆「第一次完成○○」進度顯示 1 / 1，但仍是未解鎖、總點數 0，結算畫面也沒有點數卡片。判斷是後端遊戲結算（finish／submit／answers）與日記 finalize 還沒呼叫 `grant()` 回傳 `rewards`，前端在沒有 rewards 時照設計不顯示，已請筠淇確認。

### 已知延後項目
- 等後端遊戲結算接上 `grant()` 後，再實測五款遊戲＋日記完成頁的點數卡片與成就解鎖視窗。

---

## 欣紜（點數與成就系統：成就牆、五款遊戲＋日記獲得點數與成就視窗、首頁與今日任務點數、點數商城）— 2026/11/11

### 本次異動目標
- 依〈點數與成就系統規格〉（含前端分頁、成就表第一版）完成前端：前端只顯示，不自己計算點數，一律以後端回傳的 rewards 為準。
- 依 11/9 技術組會議新增點數商城（星巴克、全聯、農會），本次只做畫面，兌換顯示「即將開放」（規格書：點數先做到只累積、不兌換）。

### 新增檔案
- `lib/features/rewards/models/rewards_models.dart`：`RewardsSummary`（summary）、`Achievement`／`AchievementCategory`（成就牆，排序：已解鎖新到舊在前、未解鎖依進度）、`RewardsResult`／`RewardBreakdownItem`／`NewAchievement`（結算回傳的 data.rewards，沒有就是 `RewardsResult.empty`）。
- `lib/features/rewards/services/rewards_service.dart`：`getSummary()`（`GET /api/rewards/summary/`）、`getAchievements()`（`GET /api/rewards/achievements/`）。**假資料開關 `useMockRewards = true`**（第一版 25 個成就，已解鎖 3 個），對接時改 `false`。
- `lib/features/rewards/widgets/achievement_card.dart`：成就卡片。已解鎖金色勳章 `military_tech`（#FFB300）＋解鎖日期；未解鎖灰色鎖頭 `lock`（#7A7A7A）、整張置灰＋進度條 current / target。
- `lib/features/rewards/widgets/rewards_earned_card.dart`：獲得點數卡片。「本場獲得 +N 點」、breakdown 逐行出現、目前總點數；達上限顯示「今天的點數拿滿了，明天再來」；**0 點不顯示**；明細播完呼叫 `onFinished` 接著跳成就視窗；`forceLight` 給五款遊戲維持淺色。
- `lib/features/rewards/widgets/achievement_unlock.dart`：`showNewAchievements()` 成就解鎖視窗。多個依序顯示（「下一個」→「太棒了！」），點外面不會關，一定要按按鈕。
- `lib/features/rewards/widgets/rewards_dialog.dart`：`showRewardsAndAchievements()` 點數視窗。給結算是小視窗的遊戲用（來去菜市場、料理準備是橫向畫面，`MarketResultDialog` 塞不下），流程：點數視窗（按「繼續」）→ 成就視窗 → 原本的結算視窗。
- `lib/features/rewards/pages/achievements_page.dart`：成就牆。上方已解鎖數／總數、目前點數；探索／訓練／里程碑三個類別按鈕（三個一排，點了切換）。
- `lib/features/shop/`（`models/shop_models.dart`、`services/shop_service.dart`、`widgets/shop_item_card.dart`、`pages/shop_page.dart`、`pages/shop_brand_page.dart`）：點數商城。上方深綠色點數卡片、品牌按鈕（星巴克、全聯、農會）、熱門兌換直向卡片列表；點品牌進品牌頁。商品是前端假資料；點數不足顯示灰色「點數不足」；兌換跳確認視窗後顯示「兌換功能即將開放」。點數改讀 `RewardsService.getSummary()`。

### 修改檔案（自己的頁面）
- `lib/screens/home_screen.dart`：右下角新增「逛商城」懸浮按鈕（照比賽版橘色圓形）；點數改讀 summary 的 `total_points`，回到首頁、下拉重新整理時更新，讀不到不擋首頁。
- `lib/features/home/widgets/greeting_section.dart`：點數圖示改成金幣。
- `lib/features/home/models/home_models.dart`：`DailyTask` 多讀 `points`；`DailyTasks` 多讀 `all_done_bonus`（`allDoneBonusPoints`、`allDoneBonusEarned`）。
- `lib/features/home/widgets/daily_task_card.dart`：每項右邊顯示「+5」（完成的變灰）；最下面「全部完成再 +20 點」，`earned` 為 true 時顯示「已領取全部完成加碼 +20 點」。後端沒給這些欄位時不顯示。

### 修改檔案（其他組員的頁面，只加不刪，後端沒回傳 rewards 時畫面跟原本一樣）
- 冰箱清點：`fridge_game_page.dart`（第 10 題結束的回應存 rewards）、`fridge_result_page.dart`（「再玩一次」上方加點數卡片）。
- 整理菜籃：`market_sort_api_service.dart`（`MarketSortSubmitResult` 多讀 rewards）、`market_sort_result_screen.dart`（分數卡片下方加點數卡片）。
- 市場買菜：`market_shopping_models.dart`（`ChangeAnswerResult` 多讀 rewards）、`market_shopping_game_page.dart`、`market_shopping_result_page.dart`（首次答對率下方加點數卡片）。
- 來去菜市場：`go_to_market_model.dart`（`MarketFinishResult` 多讀 rewards）、`go_to_market_game_page.dart`（開結算視窗前先跳點數視窗）。
- 料理準備：`memory_recall_model.dart`（`MemoryRecallResult` 多讀 rewards）、`cooking_prep_game_page.dart`（熟悉場結束、正式賽結算前都跳點數視窗；規格書：熟悉場也給點）。
- 聲影日記：`diary_model.dart`（多讀 finalize 回應的 rewards）、`diary_finish_page.dart`（朗讀按鈕下方加點數卡片，支援深色模式；已完成的日記再進入時後端回 0 點，自動隱藏）。
- 會員頁：`profile_page.dart`（選單第一項新增「我的成就與點數」入口，進入成就牆）。
- 遊戲名稱照規格書「一律以 App 內顯示的名稱為準」（來去菜市場、料理準備、冰箱清點）。

### 目前狀態
- `flutter analyze lib` 沒有 error；`flutter test` 253 個全部通過。
- 成就牆、會員頁入口、點數商城用假資料在 Chrome 看過。
- 點數卡片、點數視窗、成就解鎖視窗用暫時預覽頁（假資料，看完已刪除、沒有 commit）看過：明細逐行出現、多個成就依序顯示、達上限文案、0 點不顯示，皆正常。
- **還沒接後端實測**：五款遊戲結算、日記完成、首頁點數、今日任務 +5 都要等後端 rewards API。

### 對接時要做的事
- `rewards_service.dart` 的 `useMockRewards` 改成 `false`（首頁、成就牆、商城的點數會一起變成真的）。
- 每款遊戲各玩一次、寫一篇日記，確認點數卡片和成就視窗；料理準備要測熟悉場。

### 已知延後項目
- 點數紀錄頁（`GET /api/rewards/points/history/`）、看週報／開儀表板／分享日記時跳成就視窗：規格書選做，本次未做。
- 首頁點數點擊後要去哪裡（規格書寫成就牆，待組長確認），目前不能點。
- 商城兌換要等後端兌換 API；商品目前是前端假資料。
- 跑版修復：要接後端用手機或模擬器看完整畫面後再修。

---

## 小會（配合後端 F1～F7 安全修正，前端對應調整）— 2026/11/09

### 本次異動目標
- 後端 `fix/features` 這一輪（LightMemory-Backend commit `794bf9d`，PR #87～#93）修了 F1～F7，逐項比對前端後，只有 F4、F5、F7 需要改。
- 分支：`fix/backend`（從 dev 開）；三個小分支 `fix/diary-media-url-nullable`、`fix/diary-reply-conflict`、`fix/password-reset-throttle-ui` 各自 merge 回 `fix/backend`。

### 逐項結論
| 編號 | 後端變更 | 前端 |
|---|---|---|
| F1 | 遊戲未登入 → 404 `USER_NOT_FOUND` | 不用改：所有遊戲 service 都用 `authHeaders()`，沒 token 在本機就擋下 |
| F2 | 作答端點檢查 session 擁有者 → 403 | 不用改：`_sessionId` 只存在 widget state，換帳號不會殘留 |
| F3 | market_sort `session_id` 被他人用過 → 403 | 不用改：已用 `Uuid().v4()` |
| F4 | 忘記密碼限流 → 429 + `Retry-After` | 已改（見下） |
| F5 | 日記照片／錄音改簽名網址，簽名失敗為 `null` | 已改（見下） |
| F6 | 刪帳號清雲端檔案 | 不用改：前端目前沒有刪除帳號功能 |
| F7 | `round_index` 驗證 → 400／重送同輪 → 409 | 已改（見下） |

### 修改檔案
- F5：`diary_model.dart` 的 `DiarySummaryModel`、`DiaryModel` 的 `photo_url` 改成 `as String? ?? ''`（原本遇到 `null` 會 `TypeError`，整個月曆／日記詳情 parse 失敗）；`diary_chat_page.dart`、`diary_finish_page.dart` 的照片補空字串判斷與 `errorBuilder`。
- F7：`diary_service.dart`
  - `_unwrap` 失敗改丟 `ApiException`（保留 HTTP 狀態碼與 `error.code`），畫面照舊用 `friendlyErrorMessage`。
  - 實作 D-4 `getDiaryDetail`（`GET diary/<id>/`，後端已上線）。
  - `submitReply` 遇 409 `ROUND_ALREADY_ANSWERED`（網路重試造成，上一次其實已成功）改抓詳情還原該輪結果，使用者看不到錯誤。`isDone` 用「回覆數 ≥ 4」判斷，不用詳情的 `is_done`（那個代表已 finalize）。
  - 400 `INVALID_ROUND_INDEX`：前端 `_roundIndex` 本來就只會是 1～4，維持由既有 catch 顯示「送出失敗」。
- F4：`api_response.dart` 的 `ApiException` 新增 `retryAfterSeconds`、`isTooManyRequests`；`auth_service.dart` 的 `_toApiException` 讀 `Retry-After`；`error_message.dart` 的 `friendlyErrorMessage` 遇次數限制顯示「操作太頻繁了，請約 N 分鐘後再試」。忘記密碼兩頁原本就用它顯示 snackbar，畫面檔案沒改。

### 測試
- 新增 26 個測試（`flutter test` 253 → 279 個全部通過）：
  - `test/features/diary/models/diary_model_test.dart`：`photo_url: null` 不丟例外。
  - `test/features/diary/services/diary_service_test.dart`：用 `http.runWithClient` + `MockClient`，涵蓋 201 成功、400 `INVALID_ROUND_INDEX`、409 還原（含第 4 輪、找不到該輪）、`{"detail": ...}` 的 401、`getDiaryDetail`、finalize 回 200。
  - `test/features/auth/services/auth_service_test.dart`、`test/core/network/error_message_test.dart`：429 與 `Retry-After`（秒、缺少、非整數）、秒數轉文字。
- 每組新測試都確認過「還原修正後會失敗」。

### 沒有動的地方
- 後端文件寫明屬 `fix/global`、尚未實作的項目沒處理：refresh token 輪替與縮短 access token（`TokenStorage` 目前只存 access token，401 仍是清掉導回登入）、統一 `{success,data,error}` 格式、忘記密碼加生日＋手機。
- 沒做 `cached_network_image`：簽名網址每次不同只會多下載，Flutter 內建圖片快取只在記憶體，影響小。
- 還沒測：對真實後端手動走一遍（日記月曆／聊天室、忘記密碼連按 11 次、五款遊戲各玩一場）。

---

## 欣紜（遊戲「退出」統一回首頁，刪除舊的六大領域遊戲首頁）— 2026/11/04

### 本次異動目標
- 從首頁進遊戲、按「退出遊戲」會跑到舊的六大領域遊戲首頁（`GameHomeScreen`），它左上角的 home icon 失效（堆疊被清空，`Navigator.pop` 沒有上一頁可退），回不了首頁。
- 五款遊戲所有「退出」一律直接回首頁（`MainScreen`），舊頁面整頁刪除。

### 修改檔案
- 退出改成 `Navigator.of(context).popUntil((route) => route.isFirst)`（`MainScreen` 是堆疊最底層，`welcome_page`、`tutorial_intro_page` 進主畫面時已清空前面的頁面）；`openGame()` 回傳的 Future 照常結束，首頁還是會重新整理今日任務。共 11 處：
  - 冰箱清點：`fridge_game_page.dart`（暫停退出）、`fridge_result_page.dart`
  - 市場買菜：`market_shopping_play_page.dart`、`market_shopping_memorize_page.dart`、`market_shopping_checkout_page.dart`、`market_shopping_result_page.dart`
  - 整理菜籃：`market_sort_game_screen.dart`（暫停退出，原本是 `pop()`）、`market_sort_result_screen.dart`
  - 來去菜市場：`go_to_market_game_page.dart`（暫停退出原本是 `pop()`；結算彈窗退出）
  - 料理準備：`cooking_prep_game_page.dart`（`_exitToHome`）
- 刪除 `lib/screens/game_home_screen.dart`，以及只有它在用的 `game_top_bar.dart`、`training_progress_card.dart`、`game_bottom_actions.dart`。`domain_card.dart`、`game_mock_data.dart` 儀表板還在用，保留。
- `game_launcher.dart`、`weekly_report_page.dart` 註解改成指向 `openGame()`。
- `docs/cooking_prep_system.md`、`docs/go_to_market_system.md`：入口與退出流程改成新的寫法。

### 測試
- 新增 `test/features/game/game_exit_to_home_test.dart`：
  - Widget 測試：整理菜籃、市場買菜、冰箱清點的結果頁「退出」，以及整理菜籃、市場買菜三個畫面的暫停選單「退出遊戲」，都退回堆疊最底層、遊戲頁已離開堆疊。
  - 原始碼檢查：10 個遊戲檔案的退出點都用 `popUntil(isFirst)`；`game_home_screen.dart` 不存在且 `lib` 沒有 `GameHomeScreen`；遊戲頁沒有用 `pushAndRemoveUntil` 導去 `AuthGate` 以外的頁面。
  - 用舊程式碼跑，測試會失敗（確認抓得到原本的問題）。
- dev 上的遊玩流程／無障礙測試（`test/playthrough/*`、`test/accessibility/*`）原本用 `GameHomeScreen` 當首頁，一併改掉：
  - 新增 `test/support/test_home_screen.dart`（`TestHomeScreen`）：測試用首頁替身，按鈕文字沿用領域名稱，點下去走真實的 `openGame()`。
  - 退出後的斷言改成各測試堆疊最底層的頁面（`ROOT_HOME`、`MAIN`、`進入市場買菜`…）。
  - 整理菜籃、來去菜市場兩支「BUG重現：退出後 home icon 失效」的測試，改成驗證退出後直接回到最底層主畫面。
  - 刪除 `app_shell_a11y_test.dart` 裡 `GameHomeScreen` 本身的無障礙測試（頁面已刪除）。
  - 市場買菜遊玩測試的找零頁 overflow 斷言原本寫死 `market_shopping_checkout_page.dart:164`，刪 import 後行號位移，改成只比對檔名。
- `flutter test` 253 個全部通過、`flutter analyze` 沒有 error。
- 還沒測：冰箱清點遊戲頁、料理準備、來去菜市場結算彈窗一進場就打後端，沒有 widget 測試，只有上面的原始碼檢查，需要手動從首頁進去按退出確認。

### 沒有動的地方
- `change.md` 11/03 以前的紀錄提到的 `GameHomeScreen` 是歷史，不改。
## 蘇蘇（會員頁、儀表板改成六項能力各自解鎖、能力說明頁截圖、整理菜籃熟悉場）— 2026/11/03

### 本次異動目標
- 底部導覽「會員」分頁原本是空白，做出會員頁：頭像、我的資料、編輯資料、快速入口、登出。
- 儀表板配合後端新版：不再整頁「未解鎖」，六項能力各自判斷解鎖，分數改成 1～100 直接畫在雷達圖上。
- 六大能力說明頁的說明文字改寫，截圖統一裁成 4:3。
- 整理菜籃（market_sort）第一場是熟悉場不計分，後端分數可能是 null，結算頁要能處理。

### 修改檔案（會員頁）
- `lib/features/profile/`（新增）
  - `models/user_profile.dart`：對應 `GET／PATCH /api/users/me/`，性別、地區代碼跟註冊頁一致。
  - `services/profile_service.dart`：讀取／修改會員資料，只送有改的欄位；401 丟 `NotLoggedInException`，400 帶各欄位錯誤訊息。
  - `services/avatar_storage.dart`：後端還沒有頭像 API，頭像先存在手機的 App 文件資料夾，每個帳號一張，換手機或重新安裝會不見。
  - `pages/profile_page.dart`：頭像（點了可以拍照、選相簿或移除）、我的資料卡片（沒填顯示「未填寫」）、快速入口（我的週報表、通知、重看新手導覽、設定）、登出。資料讀不到時，快速入口和登出照常可以用。
  - `pages/edit_profile_page.dart`：編輯暱稱、生日、性別、地區、緊急聯絡人；前端先檢查格式，後端回傳的欄位錯誤顯示在對應欄位下方。
- `lib/features/auth/services/logout_helper.dart`（新增）：設定頁和會員頁共用的登出流程（確認視窗 → 清 token → 回 AuthGate → 登入頁）。
- `lib/screens/settings_screen.dart`：登出改呼叫 `LogoutHelper`。
- `lib/screens/main_screen.dart`：第 5 個分頁換成 `ProfilePage`（第 2 個分頁維持 dev 上的動態牆）。
- `pubspec.yaml`：新增 `path_provider`（存頭像用）。
- `ios/Runner/Info.plist`（**模組外的檔案**）：補相簿、相機的權限說明。

### 修改檔案（儀表板）
- `dashboard/models/dashboard_models.dart`
  - 拿掉 `DashboardUnlockProgress`，改成 `DashboardDimension`：每項能力各自有 `unlocked`、`valid_count`、`sessions_to_unlock`、`score`（1～100）、`personal_weight`。
  - `personal_weight` < 0.5 視為「參考期」（基準還偏向其他使用者）。舊版後端沒有這個欄位時當作 1，不顯示提示。
  - 週報表 `WeeklyAbilityStat` 新增 `unlocked`；整體沒有這個欄位，只要有任何一項解鎖就算解鎖。
- `dashboard/services/dashboard_service.dart`：不再把 `INSUFFICIENT_DATA` 當成正常情況，`success` 不是 true 就顯示錯誤。
- `dashboard/pages/dashboard_page.dart`：拿掉未解鎖進度卡片，一律顯示雷達圖。名稱下方：已解鎖顯示分數；未解鎖顯示「再玩 N 次」／「再寫 N 篇」；已解鎖但最近沒玩顯示「最近還沒玩」／「最近還沒寫」。還在參考期的能力，圖下方會標註「前幾次會參考其他使用者的表現」。
- `dashboard/widgets/ability_radar_chart.dart`：新增 `scoreLabels`、`muted`；灰色顯示的能力名稱變淡、放射線不上色，沒有分數的不畫頂點圓點。
- `dashboard/widgets/weekly_report_sections.dart`：未解鎖的能力用鎖頭圖示加「累積玩滿 3 次後解鎖」（語言是「寫滿 3 篇日記」）取代長條，也不顯示趨勢。
- `dashboard/models/ability_catalog.dart`、`pages/ability_detail_page.dart`、`assets/images/abilities/*.jpg`：六項說明文字改寫；截圖裁成 4:3，固定 4:3 框並用 cover 填滿，加上淡淡的外框，截圖和說明之間的間距加大。

### 修改檔案（整理菜籃）
- `game/market_sort/services/market_sort_api_service.dart`：新增 `is_pretest`；`current_score`、`highest_score`、`encouragement_tier` 改成可以是 null。
- `lib/screens/market_sort_result_screen.dart`：沒有分數時顯示 `_NoScoreCard`（熟悉場顯示「這場不計分，下一場開始算分數喔！」，其他情況顯示「這場的分數還在準備中」），也不畫歷史圖。

### 測試
- `test/features/profile/profile_page_test.dart`（新增）：會員頁、頭像。
- `test/accessibility/dashboard_diary_a11y_test.dart`：配合新的儀表板資料格式更新。

### 合併 dev 後更新的舊測試（只改測試，沒有動 app 程式）
這幾個測試檔原本只在這條分支上、dev 沒有，是照舊畫面寫的，合進 dev 後改成照 dev 現在的畫面：
- `test/accessibility/app_shell_a11y_test.dart`
  - 身分選擇頁已刪除（PR #22）：拿掉它的測試；沒有 token 時改成檢查進登入頁，有 token 時檢查進歡迎頁。
  - 登入頁顯示密碼的圖示改成 `visibility_outlined`；註冊頁改三步驟、沒有興趣選項，拿掉「健康講座」那一步。
  - 底部導覽「資訊站」改成「動態牆」（新手教學第 3 步也是）；PostCard 拿掉按讚相關參數。
- `test/accessibility/dashboard_diary_a11y_test.dart`
  - 動態回顧從底部面板改成獨立頁面，假後端補上 `GET /api/diary/review/`，關閉改按「返回」。
  - 上傳照片頁：Windows 上暫存資料夾刪不掉時不算失敗。
- `test/playthrough/fridge_inventory_playthrough_test.dart`
  - 冰箱清點的退出、結算頁退出，dev 上已改成清空堆疊、回到遊戲首頁；「測試成績頁」按鈕也已移除。原本記錄舊行為的 BUG 測試改成檢查新行為。
- `test/features/profile/profile_page_test.dart`：登出後改成檢查回到登入頁。

### 目前狀態
- `flutter analyze`：沒有 error，剩下的 info／warning 原本就有，這次沒有新增。
- `flutter test`：253 個全部通過。
- `api_constants.dart` 本機用的臨時網址沒有 commit，維持 dev 的網址。

### 待後端處理
- 頭像目前只存在手機，需要後端提供頭像上傳 API。

---

## Wen（刪除親屬端・前端：拿掉身分選擇頁，App 第一頁改成登入頁）— 2026/11/03

### 本次異動目標
- 依 10/27 跟老師開會的決議，計畫書刪掉「親屬端」，只做長者端。
- 身分選擇頁只剩「長者模式」一個有用的按鈕（「家屬模式」只有 TODO），整頁刪掉，打開 App 直接是登入頁。

### 修改檔案
- `lib/features/auth/pages/identity_select_page.dart`（刪除）
- `lib/features/auth/pages/auth_gate.dart`：`_goToIdentitySelect()` 改名 `_goToLogin()`，沒有 token、token 過期兩種情況都導去 `LoginPage`。設定頁登出、動態牆、儀表板、週報表、來去菜市場的登入過期都是 `pushAndRemoveUntil` 回 `AuthGate`，所以只改這裡就全部生效。
- `lib/features/auth/pages/welcome_page.dart`、`lib/screens/settings_screen.dart`：註解裡的「身分選擇頁」改成「登入頁」。
- `README.md`、`docs/go_to_market_system.md`、`docs/frontend_todo.md`：拿掉身分選擇、家屬端的描述；待辦的「刪除親屬端」改正並打勾（前端部分）。

### 沒有動的地方
- 註冊頁：「家屬聯絡人」「新增家屬帳號」欣紜改寫註冊頁時已經拿掉；第 3 步的「緊急聯絡人」是長者自己的資料，保留。
- `social_service.dart` mock 的 `'category': 'family'`：是日記主題分類（food、entertainment、family…），不是家屬模式。
- `notification_model.dart` 的 `family_reply`：後端通知類型，等筠淇後端拿掉後再一起整理。
- 首頁沒有任何親屬相關的入口。

### 測試
- 清掉 token 後開 App，第一頁是登入頁（沒有返回鍵）。
- 登入 → 歡迎頁 → 首頁；設定頁登出回登入頁，按瀏覽器上一頁回不到主畫面。
- 註冊三步驟正常。
- `git grep IdentitySelect -- lib test` 沒有結果（`change.md` 的舊紀錄裡還會出現，正常）。

### 待處理
- 後端（筠淇）：刪 `FamilyContact`、通知類型 `family_reply`。前端從沒呼叫過親屬相關 API，不需要對接測試。

---

## 欣紜（忘記密碼兩頁、登入頁忘記密碼連結；合併小惠 PR #19；接真實後端測試；動態牆新增搜尋）— 2026/11/03

### 本次異動目標
- 依小惠〈首頁改版 API 規格書〉做忘記密碼兩頁（這次只做「輸入帳號 → 設定新密碼」，沒有驗證碼）。
- 合併小惠 PR #19（通知串接後端、首頁接真實 API），並用小惠的後端實際測試註冊、登入、首頁、通知、忘記密碼。
- 動態牆新增搜尋：貼文多的時候，長輩可以用關鍵字或日期找到想看的日記。

### 修改檔案（忘記密碼）
- `lib/features/auth/services/auth_service.dart`
  - 新增 `checkPasswordResetAccount()`（`POST /api/users/password-reset/check/`）：確認帳號存在，404 時丟出 `ACCOUNT_NOT_FOUND`「找不到這個帳號，請再確認一次」。
  - 新增 `resetPassword()`（`POST /api/users/password-reset/`）：送 `username`、`new_password`、`new_password_confirm`。
  - 假資料開關 `useMockPasswordReset`（預設 `false`）：改成 `true` 時，帳號輸入 `notfound` 模擬找不到帳號、兩次密碼不一樣模擬錯誤。
- `lib/features/auth/pages/forgot_password_page.dart`（新增）：忘記密碼第 1 頁。Logo、標題「忘記密碼」、帳號欄、「送出」；有輸入帳號才能按；找不到帳號時訊息顯示在帳號下方（橘褐色）；成功後帶著帳號跳到第 2 頁（不用再輸入一次）。左上角文字「返回」。
- `lib/features/auth/pages/reset_password_page.dart`（新增）：忘記密碼第 2 頁。新密碼、確認密碼（都有顯示／隱藏密碼的眼睛）、「送出」；兩格都填了才能按；前端先檢查兩次密碼一不一樣；後端回傳的欄位錯誤（例如密碼太簡單）顯示在對應欄位下方。成功後跳出「密碼已更新」，按「回到登入頁」回登入頁。左上角文字「返回」。
- `lib/features/auth/pages/login_page.dart`：密碼欄右下方加「忘記密碼」連結。

### 修改檔案（動態牆搜尋）
- `lib/features/social/pages/social_wall_page.dart`
  - 標題下方新增搜尋框：搜**標題、內容、標籤（hashtags）**，不分大小寫，打字就即時篩選；右邊 ✕ 一鍵清除。
  - 新增日期下拉選單：只列出**有貼文的日期**（新的在前，顯示成「2026年10月20日」），選「全部日期」不篩選；不用日曆，避免翻很多頁、也不會出現英文日期。
  - 關鍵字和日期可以一起用；搜尋中顯示「找到 N 篇日記」；找不到時顯示「找不到符合的日記」＋「清除搜尋」按鈕。
  - 沒有貼文時不顯示搜尋區；選到的日期如果貼文被刪光，自動當成「全部日期」。
  - 搜尋框、日期選單支援深色模式、高對比、字體縮放。

### 合併小惠 PR #19
- 小惠的 PR 直接合進 `feature/home-page-1031`（通知頁串接後端、點留言通知跳到貼文、首頁三支 API 接真實後端、首頁與通知的測試）。
- 本機同一天也對齊了 Notion 首頁 API（鼓勵語改呼叫 `/api/home/greet/`、遊戲名稱相容 `name`／`title`），跟小惠改的是同一件事，`git pull` 時 `home_models.dart`、`home_service.dart` 衝突，**兩個檔案都採用小惠的版本**（已包含相同修改，測試也是照她的版本寫的）。本機版本多的「`is_developed: false` 不顯示」沒有保留，小惠 PR 說明後端目前只回傳已開發的遊戲。
- 小惠的 PR 把 Cloudflare 臨時網址 commit 進 `api_constants.dart`，開 PR 前已改回 dev 的 `serverUrl`，臨時網址沒有帶進 dev。
- 合併後 `flutter analyze lib` 沒有 error；`flutter test` 48 個全部通過。

### 目前狀態
- `flutter analyze lib/features/auth`：沒有新的 error 或 warning（`tutorial_overlay.dart` 的 4 個是原本就有的）；`flutter analyze lib/features/social`：No issues found。
- 忘記密碼先用假資料（`useMockPasswordReset` 暫時改 `true`，測完已還原）測過：登入頁連結、找不到帳號、兩次密碼不一樣、成功後「密碼已更新」並回到登入頁。
- 接小惠的後端（Cloudflare 臨時網址）在 Chrome 實測：註冊三步驟、啟動頁與登入後顯示暱稱、首頁招呼語／今日任務／遊戲卡片、通知頁、忘記密碼，皆正常。
- 動態牆搜尋用假資料在 Chrome 測過（`useMockWall` 暫時改 `true`，並暫時拿掉假資料「只回自己貼文」的篩選，讓 3 篇假貼文都顯示；測完已用 `git restore` 還原）：關鍵字搜標題、搜標籤、清除、選日期、關鍵字＋日期找不到、「清除搜尋」，皆正常。
- 動態牆搜尋**還沒有接後端實測**，之後拉最新的 dev 再跟筠淇一起用真實貼文測試。
- `api_constants.dart` 的 `serverUrl` 測試時換成小惠的新網址，沒有 commit。

### 已知延後項目
- 規格書註明忘記密碼沒有驗證碼，任何人知道帳號就能改密碼；正式上線要加簡訊或 Email 驗證。
- 動態牆搜尋目前是**前端搜尋**，只會搜已經載入的貼文（S-2 一次 20 則），比較舊的貼文搜不到。之後如果需要，請筠淇在 S-2 加搜尋參數（例如 `keyword`、`date`），前端改成把條件傳給後端即可，畫面不用改。
- 所在地區：小惠已同意後端改收縣市名稱，改好後要拿掉 `register_page.dart` 的 `_regionCodeForBackend()` 換算，直接送縣市。
- 遊戲名稱：已請小惠把後端回傳的名稱改成跟 App 一致（冰箱清點、料理準備、來去菜市場）。
- 遊戲首頁左上角🏠在遊戲結束退出後跳轉不正確（小惠提到的 logo 跳轉 bug），還沒修。

---

## 欣紜（註冊改三步驟／啟動頁顯示暱稱／首頁改版：今日任務、遊戲卡片、全部遊戲頁）— 2026/10/31

### 本次異動目標
- 依小惠〈首頁改版 API 規格書〉（10/28）與組內首頁改版設計，改註冊、登入、啟動頁、首頁。
- 註冊時就填暱稱，首頁和歡迎頁的招呼語改用暱稱（不再寫死「玉蘭」或顯示帳號）。
- 小惠的後端 API 還沒做好，首頁先用假資料完成畫面，對接時只要切開關。

### 修改檔案（註冊、登入、啟動頁）
- `lib/features/auth/pages/register_page.dart`（改寫）
  - 一頁拆成三步驟，上方顯示「第 1 步，共 3 步」與進度條：
    - 第 1 步：帳號、密碼（必填，沒填完「下一步」不能按）；左上角文字「返回」離開註冊頁。
    - 第 2 步：暱稱（新增，最多 20 字）、生日、性別（必填）；下方「上一步」「下一步」。
    - 第 3 步：所在地區、緊急聯絡人姓名＋電話（選填）；都沒填按鈕顯示「略過」，有填任何一欄顯示「完成註冊」。
  - 生日從英文日期選擇器改成「年／月／日」三個中文下拉選單（1920 年到今年），換月份時日超過天數會自動清掉。
  - 性別不預設，要自己選。
  - 所在地區改成 22 縣市（依北、中、南、東、離島分組）。小惠規格書只收 `north`／`central`／`south`／`east`，目前先換算成這四個代碼送出，離島不送（見待處理）。
  - 拿掉興趣喜好、家屬聯絡人（配合 10/21「刪掉親屬端」）。
  - 密碼欄右邊加眼睛，可以顯示／隱藏密碼。
  - 送出順序照規格書：註冊（只送必填）→ 自動登入存 token →（有填選填才）`PATCH /api/users/me/`。選填資料存失敗不擋使用者，提示之後到會員中心補填。
  - 後端回傳欄位錯誤（`error.fields`）時，訊息顯示在該欄位下方，並自動跳回那一步；顏色用橘褐色 `0xFFB45309`（規格書：不要用紅色）。
  - 手機返回鍵在第 2、3 步是回上一步，不會直接離開註冊頁。
  - 歡迎頁改顯示暱稱「歡迎加入，玉蘭！」。
- `lib/features/auth/services/auth_service.dart`
  - `register()`：多送 `nickname`；拿掉規格書刪除的 `phone`、`address`、`first_name`、`last_name`、`region`。
  - 新增 `updateMe()`（`PATCH /api/users/me/`）、`getMe()`（`GET /api/users/me/`）。
  - 新增 `_toApiException()`：看得懂規格書的錯誤格式 `{"error": {code, message, fields}}`，`fields` 放進 `ApiException.details`；也相容 Django 預設的 `{"username": [...]}`。帳號重複統一成 `USERNAME_TAKEN`。
  - `getMe()` 有假資料開關 `useMockMe`（預設 `false`），後端沒開時想看啟動頁可以暫時改成 `true`。
- `lib/features/auth/pages/auth_gate.dart`：有 token 時先呼叫 `getMe()` 拿暱稱，再進歡迎頁「歡迎回來，玉蘭！」；token 過期（401 或 `NotLoggedInException`）清掉 token 回身分選擇頁；網路不穩等其他錯誤不擋使用者，歡迎頁照樣出現、只是不顯示名字。
- `lib/features/auth/pages/welcome_page.dart`：拿掉標題列與「進入首頁」按鈕，改成粗體文字「輕觸螢幕進入首頁」，點整個畫面任何地方都能進入（長輩手指比較不準）；沒有暱稱時顯示「歡迎回來！」。
- `lib/features/auth/pages/login_page.dart`：登入後呼叫 `getMe()`，歡迎頁顯示暱稱（原本顯示帳號）；密碼眼睛圖示跟註冊頁統一。

### 修改檔案（首頁）
- `lib/features/home/models/home_models.dart`（新增）：`HomeUser`、`HomeGame`、`DailyTask`、`DailyTasks`，對應 `GET /api/home/user/`、`/games/`、`/daily-tasks/`。
- `lib/features/home/services/home_service.dart`（新增）：三支 API；回應相容有沒有包 `{"data": ...}`；錯誤沿用 `parseApiError`。**假資料開關 `useMockHome` 目前是 `true`**。
- `lib/features/home/services/game_launcher.dart`（新增）：`openGame(context, gameId)`，依遊戲代碼開遊戲，入口跟六大領域遊戲首頁一致（冰箱清點、來去菜市場先進教學頁；市場買菜、料理準備、整理菜籃直接進遊戲）。首頁卡片、今日任務、全部遊戲頁共用。
- `lib/features/home/widgets/greeting_section.dart`：加日期「10 月 31 日　星期六」；招呼語依時間變化（05:00～10:59 早安、11:00～17:59 午安、其他晚安）；右上角「🌱 120 點」（點數下一個 issue 才做，先寫死）；鼓勵語前面加機器人（沿用蘇蘇的 `RobotAvatar`，`DashboardMood.good`）。
- `lib/features/home/widgets/daily_task_card.dart`（新增）：今日任務卡片，標題「完成 x / y」、進度條、任務清單。照規格書每個遊戲是獨立任務（每天 4～5 項）。完成的打勾＋刪除線；沒完成的有箭頭，點了開遊戲／上傳照片頁／週報表。
- `lib/features/home/widgets/game_card.dart`（改寫）：從橫條改成方形卡片，左上圖示、左下名稱，本週沒玩過右上角顯示橘色「本週還沒玩」；點了直接開那款遊戲。
- `lib/features/home/pages/all_games_page.dart`（新增）：首頁「查看全部」進來，5 款遊戲兩欄排列，卡片跟首頁同一個元件；玩完回來重新整理標籤。
- `lib/screens/home_screen.dart`（改寫）：招呼語 → 今日任務 → 大腦訓練遊戲（2 張卡片＋查看全部）。三支 API 用 `Future.wait` 同時呼叫；從遊戲、日記、週報回來會重新整理今日任務與遊戲標籤；可以下拉重新整理；未讀通知數同步到 `AppSettings.unreadNotificationCount`。遊戲卡片「本週還沒玩」的排前面再取 2 張（前端自己排序）。

### 修改檔案（通知）
- `lib/screens/notification_screen.dart`、`lib/features/home/models/notification_model.dart`：假資料拿掉「貼心小提醒」和「收到按讚」（動態牆已經沒有按讚）。

### 目前狀態
- `flutter analyze lib/features/auth lib/features/home lib/screens/home_screen.dart`：沒有新的 error 或 warning（`tutorial_overlay.dart` 的 4 個是原本就有的）。
- 後端未開，用假資料在 Chrome 預覽：註冊三步驟（按鈕擋住、上一步、略過／完成註冊切換）、啟動頁（`useMockMe` 暫時改 `true`，測完已還原）、首頁（招呼語、今日任務、遊戲卡片、全部遊戲頁、深色模式、字體最大）、通知頁。
- 註冊實際送出、登入取得暱稱、首頁三支 API、點任務開遊戲，都要等小惠的後端做好再測。

### 待處理
- **對接時把 `home_service.dart` 的 `useMockHome` 改成 `false`**。
- 要跟小惠確認：
  - 所在地區：前端用 22 縣市，請後端改收縣市名稱（收到後拿掉 `_regionCodeForBackend()` 的換算，直接送縣市）。
  - 遊戲名稱跟 App 統一：冰箱檢查→冰箱清點、記憶配對→料理準備、今天去菜市場→來去菜市場。
  - 首頁遊戲卡片前端會把「本週還沒玩」排前面，後端照規格書回傳全部遊戲即可。
  - 首頁鼓勵語的欄位名稱（規格書沒寫，前端先讀 `daily_tip`，也相容 `greeting_subtitle`）。
- 忘記密碼（登入頁連結＋2 頁）還沒做。
- `lib/features/home/models/home_data.dart`、`lib/features/home/widgets/daily_suggestion_card.dart` 新首頁已經沒用到，確認其他地方也沒用後可以刪掉。

### 給接手組員的提醒（需要全組討論的）
- 規格書提到 token 過期時用 refresh token 自動換新，目前 App 只存 access token，過期就請使用者重新登入。這是全 App 共用的機制，建議全組討論誰做。
- 規格書建議鈴鐺徽章不要用紅色，但鈴鐺在共用的 `TopBar`，改了會影響每一頁，這次沒動。
- 遊戲結算頁的「退出」是 `pushAndRemoveUntil(GameHomeScreen)`，從首頁點進遊戲、玩完退出會到六大領域遊戲首頁，不是回首頁；要不要改成回首頁待全組討論。

---

## Wen（親友分享頁／完成頁分享連結／月曆日記小視窗）— 2026/10/27

### 本次異動目標
- 10/21 會議決議，10/27 跟老師開會前修好分享：親友點分享連結 → 填暱稱 → 看日記 → 留言，長輩在動態牆看到留言。
- 點月曆上有日記的日期，彈出小視窗顯示那天的日記。

### 修改檔案
- `diary/services/diary_service.dart`：`shareToWall()` 改回傳 `ShareToWallResult`（`postId`、`shareUrl`、`inviteText`）。
- `diary/pages/diary_finish_page.dart`：分享到動態牆後記下 `share_url`，LINE、Facebook、複製連結都改用它；還沒分享時提示「請先按「分享到動態牆」」。順便清掉 `_buildShareText()` 的 null 判斷警告。
- 新增 `diary/widgets/diary_day_dialog.dart`：日期標題、照片（16:9）、標題、內文、「關閉」；整個視窗可捲動，支援深色模式、高對比、字體縮放。資料直接用 D-1，不另外打 API。
- `diary/pages/diary_home_page.dart`：`_onDiaryTap` 改成開小視窗。
- 後端 repo（另開 PR `feat/share-page-ui` → `feat/wall-post-integration`）：`public_share/templates/`、`public_share/static/` 的分享頁與失效頁 HTML/CSS/JS，view 與留言 API 是詩雅的 PR #72。

### 測試（詩雅的後端＋Cloudflare）
- `fvm flutter analyze lib/features/diary`：沒有 error。
- 完成頁：分享前按複製連結有提示；分享後複製連結，用手機打開分享頁 → 填暱稱 → 留言，動態牆貼文下看得到留言和暱稱。
- 亂打 token 顯示「這則分享已失效」。
- 月曆小視窗：淺色、深色、最大字級都正常，點外面或「關閉」都能關。

### 延後項目
- 小視窗還沒有語音播放和 hashtag。
- 分享頁顯示的長輩名字，在還沒填姓名前會是帳號（11/04 姓名頁做好後解決）。

---

## 欣紜（動態牆：帳戶隔離／拿掉按讚／未登入導向登入／錯誤訊息統一）— 2026/10/26

### 本次異動目標
- 依 10/21 會議決定：動態牆做帳戶隔離（只看得到自己的貼文）、拿掉按讚，保留留言與刪除。
- 處理世文 10/20 交代的延後項目：動態牆未登入時，改成顯示「前往登入」。
- 錯誤訊息改用世文 10/16 的共用 `friendlyErrorMessage()`，跟全 App 一致。

### 修改檔案
- `lib/features/social/services/social_service.dart`
  - S-2 動態牆列表多帶 `author=me`，只拿自己的貼文；假資料模式也只回自己的貼文。
  - S-8 按讚的呼叫先保留，畫面上已不使用（後端已移除按讚 API）。
- `lib/features/social/pages/social_wall_page.dart`
  - 拿掉按讚相關程式；說明文字改為「你分享的日記都在這裡，點開可以看看收到的留言」。
  - 未登入（`NotLoggedInException`）或登入過期（後端回 401）時，顯示鎖頭圖示、「請重新登入後再查看動態牆」與「前往登入」按鈕。按下後跟設定頁的登出一樣：`TokenStorage.clear()` 再回到 `AuthGate`。
  - 其他錯誤（例如網路斷線）改用 `friendlyErrorMessage()`，維持「重新載入」按鈕。
- `lib/features/social/widgets/post_card.dart`
  - 拿掉 `onLikeTap` 參數與愛心按讚標籤，右下角只留留言數。
  - 拿掉作者那一行（只看得到自己的貼文，每篇都會是「我」）。
  - 錯誤訊息改用 `friendlyErrorMessage()`；後端回 401 時（訊息是英文 `Given token not valid for any token type`）改成顯示「登入狀態已失效，請重新登入」。
  - 文字調整：刪除貼文確認視窗拿掉「按讚」；沒留言時顯示「目前還沒有收到留言」；輸入框提示改為「寫下想說的話...」。

### 配合後端（筠淇 10/25）
- 後端動態牆 API 全部做帳戶隔離，操作別人的貼文會回 404。
- 按讚 API 移除，貼文物件的 `like_count`、`is_liked` 也移除；前端 `PostModel` 讀不到時預設 0／false，不會報錯。
- 留言的 `sender_name`：親友有填暱稱回暱稱，沒填回「匿名」；`author` 移除，`is_mine` 保留。
- 前端顯示規則：`is_mine` 為 true 顯示「我」＋綠色外框，其他顯示 `sender_name`，程式不用另外改。

### 目前狀態
- `flutter analyze lib/features/social`：No issues found。
- 10/25 接筠淇的後端在 Chrome 測試，三個測試帳號分別登入：只看得到自己的貼文、沒有按讚、留言顯示「匿名」／「我」、新增與刪除留言正常；刪除貼文只測到確認視窗「取消」。
- 測試中遇到一次登入過期，重新登入後正常，錯誤訊息已改成中文。
- 親友從分享頁留言後在動態牆顯示：世文、詩雅已實測可以看到；我的測試帳號貼文底下沒有親友留言，沒有另外測。

### 已知延後項目
- `PostModel` 的 `likeCount`、`isLiked` 與 `SocialService.toggleLike()` 先保留，確定不再使用後可以清掉。
- 新手教學第 3 步（`tutorial_mock_data.dart`，世文的檔案）還寫「看看大家分享的日記，按讚、留言互相打氣！」，需要改成符合帳戶隔離、沒有按讚的說法。
- 長輩把分享連結傳給親友的入口（`share_url` 放在完成頁，或動態牆加「傳給親友」按鈕）待討論。
- 往下滑載入更多（目前一次 20 則）、點通知跳到貼文（S-11）。

### 給接手組員的提醒
- 判斷要不要導去登入：沒有 token 會丟 `NotLoggedInException`；token 過期是 `ApiException`（`statusCode == 401`），兩種都要處理。
- 之後如果做 AI 小助手的鼓勵留言，後端把 `sender_name` 回成「AI 小助手」，動態牆不用改就能顯示。

---

## Vevila（儀表板狀態卡片改讀後端 encouragement／語言軸與解鎖進度配合聲影日記）— 2026/10/26

### 本次異動目標
- 對照 10/26 更新版〈儀表板與週報表 API 規格書〉，後端已上線：儀表板首頁上方的狀態卡片不再用前端寫死的「請保持!」，改依後端回傳的 `encouragement.trend` 顯示。

### 修改檔案
- `dashboard/models/dashboard_models.dart`
  - `DashboardStatus` 改成 `DashboardStatus.fromTrend(trend)`，文字照規格 4-2 對照：`up` 進步了！／`steady` 請保持！／`practice` 多練習！／`null`、未解鎖或沒有這個欄位 歡迎開始！。機器人表情依序 good／keep／encourage／keep。
  - `DashboardOverview.fromApi` 讀 `data.encouragement.trend`；移除 `peerAverage`（同齡平均，新版只跟自己比，畫面本來就沒用到）和 `dashboardMoodFromString`。
- `dashboard/services/dashboard_service.dart`：刪掉 `_mockStatus`、`_mockPeerAverage` 假資料。
- `dashboard/pages/dashboard_page.dart`
  - 雷達圖語言軸近 7 天沒寫日記（`z_score: null`）時，名稱下方小字顯示「近期未寫日記」，其他五軸維持「近期未遊玩」。
  - 未解鎖畫面多了聲影日記一項：說明文字改成「遊戲玩滿 3 場、聲影日記寫滿 3 篇」，日記那一列顯示「還差 N 篇」（遊戲仍是「場」）。

### 目前狀態
- `flutter analyze lib/features/dashboard`：0 issue。尚未在 app 上用實際帳號確認三種趨勢的畫面。
- 週報表模型原本就能處理 `played`、分數 null，這次沒有改。

### 待確認
- 規格 §8 提到整理菜籃 `cognitive_flexibility_score`、冰箱檢查與市場買菜 `standard_score` 改成 1～100 且可能是 null，要顯示「資料不足」。前端目前結算頁沒有讀這幾個欄位（市場買菜讀 `raw_score`），需要跟後端確認結算 API 實際回傳的欄位後再決定要不要改。

---

## Wen（整合蘇蘇健康儀表板與組長登出功能，準備合進 dev）— 2026/10/21

### 本次異動目標
- 在 `integrate/frontend-1019` 合併蘇蘇的 `feature/dashboard-ability-guide`（裡面也有組長 PR #14 的登出功能），整合完開 PR 進 `dev`。

### 整合
- `git merge origin/feature/dashboard-ability-guide`（merge commit `40d2264`），衝突只有 `change.md`，兩邊紀錄都保留，依日期排列。
- `main_screen.dart` 自動合併：第 2 格 `SocialWallPage`（導覽列文字「動態牆」）、第 4 格 `DashboardPage`。
- `api_constants.dart`：蘇蘇分支換過 `serverUrl`，合併時保留整合分支原本的值，臨時網址不進 `dev`。
- `pubspec.yaml` 新增 `flutter_animate`、`visibility_detector` 和 `assets/images/abilities/`，`pubspec.lock` 跟著合併進來，`pub get` 後沒有差異。

### 測試（後端沒開，先做離線的部分）
- `fvm flutter analyze`：沒有新的 error，`lib/features/dashboard/` 0 issue；`fvm flutter test`：11 個測試通過。
- 用假 token 進主畫面：導覽列 5 格正確；儀表板、週報表連不上時顯示「資料暫時讀不到」，按「再試一次」不會當掉，也不會被導回登入。
- 六大能力說明（用 `home:` 預覽）：文字、截圖正常，深色模式和超大字級（145%）都有套用。
- 登出：取消沒反應、確認後回到身分選擇頁，上一頁回不到主畫面，`flutter.access_token` 變成 `null`。
- 待後端開啟後補測：換帳號資料不殘留、語言軸 `z_score: null`、整理菜籃／市場買菜／料理準備結算頁（見 `docs/frontend_todo.md` 四）。

### 小技巧
- 後端沒開也要進主畫面時：F12 → Console 執行 `localStorage.setItem('flutter.access_token', '"fake-token"')`，再重新整理。測完登出即可清掉。
- 字體、深色模式只存在記憶體，按 F5 或 hot restart 會重置；要預覽沒有入口的頁面時，暫時改 `app_settings.dart` 的預設值，測完 `git restore`。

### 延後項目
- 設定頁 `ListTile` 包在有背景色的 `Container` 裡，debug 模式每次開設定頁都會印出「ListTile background color or ink splashes may be invisible」，原本就有，登出卡片也一樣，之後一起修。

---

## 蘇蘇（料理準備結算視窗標題／按鈕斷行、六大能力說明文字與截圖）— 2026/10/21

### 本次異動目標
- 料理準備的結算視窗標題寫成「來去菜市場」，「退出」「再玩一次」在手機直向時斷成兩行。
- 六大能力說明頁的說明文字和遊戲截圖還是預留的，補上正式內容。

### 修改檔案
- `go_to_market/widgets/market_result_dialog.dart`（**模組外的檔案**，來去菜市場和料理準備共用）：
  - 多一個 `title` 參數，預設還是「來去菜市場」，來去菜市場那邊不用改。
  - 「退出」「再玩一次」外面包 `FittedBox`，按鈕太窄時字等比例縮小，不會斷行；按鈕左右內距改成 8。
- `cooking_prep/pages/cooking_prep_game_page.dart`：開結算視窗時傳 `title: '料理準備'`。
- `dashboard/models/ability_catalog.dart`：六項能力的 `description` 填入說明文字（定義／例如／在哪個遊戲練習，各一行），`screenshotPath` 指到新的截圖。
- 新增 `assets/images/abilities/`：language／working_memory／attention／executive_function／visual_spatial／math 六張 `.jpg` 截圖（用網頁版實際跑 app 截的）。
- `pubspec.yaml`（**模組外的檔案**）：assets 多一行 `- assets/images/abilities/`，只加這一行。
- `dashboard/pages/ability_detail_page.dart`：說明文字從置中改成靠左（置中時最後一行常只剩一兩個字）。
- 注意力是橫向遊戲，截圖放進直向的框太小，改成只裁中間有魚的部分。

### 目前狀態
- 結算視窗：網頁版實際玩一場料理準備確認過，標題顯示「料理準備」，按鈕在同一行。
- 六大能力說明：`flutter analyze lib/features/dashboard` 0 issue；後端網址連不上，用暫時的預覽入口直接開說明頁看過六頁的畫面（預覽入口已刪掉）。
- 待處理：工作記憶（料理準備）也是橫向遊戲，現在的截圖是直向畫面，要等後端連得上再用橫向重截、裁法跟注意力一樣。
- 待處理：靠左後執行功能、視覺空間、數學最後還是會剩「力。」「確。」一個字一行，要再決定是加寬文字區還是縮短字句。
- 另外看到：結算視窗左邊歷史成績圖下面的「前2」「前1」「本次」在手機直向時會疊在一起，還沒修。

---

## 蘇蘇（換後端網址／數學結算分數顯示 0／週報表語言改成日記用語）— 2026/10/20

### 本次異動目標
- 市場買菜（數學）結算頁「本次分數」一直顯示 0 分，但下面歷史成績圖的「本次」分數是對的。
- 語言（聲影日記）不是遊戲，週報表不要寫「還沒玩」「前往遊玩」，改成跟日記有關的說法。

### 修改檔案
- `lib/core/constants/api_constants.dart`（**模組外的檔案**）：`serverUrl` 換成 `https://innovations-ads-series-government.trycloudflare.com`，只改這一行。
- `market_shopping/models/market_shopping_models.dart`：`ChangeAnswerResult.fromJson` 的 `score` 改成 `data['score'] ?? data['raw_score']`。
  - 原因：後端完成整場（`is_completed: true`）時不再回傳 `score`，改成 `raw_score`／`standard_score`／`z_score`。前端讀不到 `score`，結算頁就用 `?? 0` 顯示成 0 分。
  - `raw_score` 跟 `/history/` 回傳的 `score` 是同一個數字，所以改完後上面的分數會跟歷史圖的「本次」一致。
- `dashboard/widgets/weekly_report_sections.dart`：「本週 vs 上週」的單項能力這週沒資料時，語言顯示「這週還沒寫日記，寫一篇看看」，其他五項維持「還沒玩，玩一場看看」（`_ComparisonRow` 多一個 `notPlayedText` 參數）。
- `dashboard/widgets/ability_action_dialog.dart`：週報表點「語言」跳出的視窗，按鈕從「前往遊玩」改成「去寫日記」，按下去一樣開聲影日記首頁。

### 實測紀錄（用新網址，帳號 `cc_test_1018`）
- 聲影日記 D-1／D-3／D-5／D-7 都正常：建立日記 → 送 3 輪語音（都有轉文字、AI 回覆）→ 生成日記 → 月曆看得到。
- 儀表板語言軸：寫日記前 `z_score: null, session_count: 0`，寫完 1 篇變成 `z_score: 0.792, session_count: 1`。前端沒有把語言固定成 0，照後端給的值畫，後端改 null／有分數前端都不用改。
- 市場買菜困難題（`hard`）選菜後沒有 `spent_amount`，已跟後端確認是刻意的（長輩要自己算）。結帳畫面困難題本來就改列每樣菜的價格，不會顯示「花了 0 元」，不用改。

### 待後端處理
- 週報表「下週小目標」是後端 `next_week_goal` 直接給的，目前會寫「這週還沒玩語言，下週試試看」，請後端改成日記的說法（AI 總結也一起確認）。
- 想確認：遊戲要玩滿 3 場才開始算分，語言寫 1 篇就有分數，是不是刻意的？只有 1 篇時 z 分數是跟什麼比的？

### 目前狀態
- `flutter analyze lib/features/dashboard`：0 issue；`lib/features/game/market_shopping`：沒有新增問題（剩下的是原本就有的）。
- 週報表只算上一個完整的週，10/20 寫的日記要到 10/26（一）才會出現在週報表，語言的長條、趨勢、AI 建議到時候再驗證。
- 數學結算分數的修正還沒在 app 上實際玩一場確認。

---

## Wen（整合欣紜動態牆；底部導覽列第 2 格改為「動態牆」；整理菜籃甜椒不出種類題；後端整合測試修正）— 2026/10/19～10/20

### 本次異動目標
- 開整合分支 `integrate/frontend-1019`，把欣紜的 `feature/social-wall` 合進 Wen 的 `feature/wen-diary-review-share`，讓分享到動態牆（S-1）和動態牆列表可以一起測。
- 動態牆組決定第 2 格的名稱用「動態牆」，按鈕文字和圖示跟著改。
- 組內決定資訊加油站這次不做（時間不夠），第 2 格直接給動態牆，不另外找位置。
- 整理菜籃的紅、黃甜椒不出種類題。

### 整合（10/19）
- 分支：`integrate/frontend-1019`（從 `feature/wen-diary-review-share` 開出，merge `origin/feature/social-wall`，merge commit `c726450`）。
- 衝突只有 `change.md`，兩邊紀錄都保留（欣紜 10/19 在最上面）；程式碼沒有衝突。
- `fvm flutter analyze`：0 個 error，沒有新增 warning。
- `post_model.dart` 已是欣紜的新版（含 `AuthorModel`／`PostAuthor`），Wen 的 S-1 呼叫的是 `diary_service.dart` 的 `shareToWall()`，不受影響。

### 修改檔案（10/20，commit `184f20c`）
- `lib/screens/main_screen.dart`
  - 底部導覽列第 2 格：文字「資訊站」→「動態牆」，圖示 `Icons.info_outline` → `Icons.groups_outlined`（兩個人，跟完成頁「分享到動態牆」意思一致）。
  - `_pages` 註解拿掉「分頁名稱待定」。
- `lib/features/auth/models/tutorial_mock_data.dart`
  - 新手教學第 3 步原本指向第 2 格、內容是資訊站，改成同一個圖示，標題「動態牆」，說明「看看大家分享的日記，按讚、留言互相打氣！」。
  - 檔案開頭 pageIndex 對照註解同步改成「1 = 動態牆」。
- `lib/features/social/pages/social_wall_page.dart`：開頭註解拿掉「名稱待定」。

### 修改檔案（10/20，整理菜籃，commit `0aff272`）
- 分類標準：以「一般人買菜時會不會猶豫」為準，不用植物學分類。甜椒吃起來甜、常生吃，植物學上又是果實，容易猶豫是蔬菜還是水果，所以排除；小黃瓜、南瓜雖然植物學上也是果實，但一般不會當成水果，維持蔬菜。
- `lib/features/game/market_sort/models/market_sort_item.dart`：`species` 改成可為 null（跟 `color`、`freshness` 一樣，null 代表有爭議、該題型不抽這個商品）。抽題用的 `isExcludedFor()` 本來就會過濾 null，抽題與判題邏輯不用改。
- `lib/features/game/market_sort/models/market_sort_item_pool.dart`：紅甜椒、黃甜椒的 `species` 改成 `null`，顏色題照常出；`countAvailableItemsByRule()` 的種類數改成只算非 null。
- `lib/features/game/market_sort/models/market_sort_item_attributes.dart`：註解「種類一定有值」改成「可能是 null」。
- `test/features/game/market_sort/models/market_sort_item_pool_test.dart`（新增）：確認兩種甜椒不出種類題、顏色題照常出；種類題可用商品數為 26。
- 各題可出題商品數：種類 26（蔬菜 8／水果 11／肉蛋 7）、顏色 22（紅 8／綠 7／黃 7）、生熟 22（生食 10／熟食 12）。
- `fvm flutter test test/features/game/market_sort`：11 個測試全部通過。

### 後端整合測試與修正（10/20 晚上，後端整合版 Cloudflare 網址）
測試結果：
- 聲影日記完整流程（上傳、錄音、AI 回覆、生成）、分享到動態牆、動態牆列表、自己的貼文顯示「我」：正常。
- 遊戲頂部列「☰ 選單」、右上角鈴鐺、整理菜籃種類題不出現甜椒：正常。
- 遊戲：料理準備回 404，工作記憶、冰箱清點打不開。後端 GitHub `main` 還沒合遊戲的分支，已請後端處理。

修正（commit `e6389e3`）：
- `lib/features/auth/pages/welcome_page.dart`
  - 新增 `isNewUser` 參數：註冊進來顯示「歡迎加入」，按鈕接新手教學引導頁（`TutorialIntroPage`）；一般登入維持「歡迎回來」，直接進主畫面。原本新手教學引導頁沒有任何地方會導過去，註冊後不會進新手教學。
  - 進主畫面改用 `pushAndRemoveUntil`，清掉身分選擇、登入頁。原本最底層還是身分選擇頁，聲影日記完成頁按「回首頁」（`popUntil isFirst`）會一路退回身分選擇頁（10/15 測試時 App 一開就已登入，主畫面在最底層，所以沒遇到）。
- `lib/features/auth/pages/register_page.dart`：導到歡迎頁時帶 `isNewUser: true`。
- `lib/features/auth/pages/tutorial_intro_page.dart`：進主畫面同樣改用 `pushAndRemoveUntil`。

修正（commit `a5913d1`）：
- `lib/core/navigation/app_route_observer.dart`（新增）：全 App 共用的 `RouteObserver`，掛在 `main.dart` 的 `navigatorObservers`。
- `lib/features/diary/pages/diary_home_page.dart`
  - 加上 `RouteAware`，主畫面重新顯示時（`didPopNext`）重新讀取這個月的資料。原本只在第一次進頁面時讀取，寫完日記回首頁不會顯示「已完成今天的紀錄」和月曆照片，要切分頁或重新整理才會更新。
  - 不能用「await 進入上傳頁」：上傳、聊天、生成頁都用 `pushReplacementNamed` 換頁，上傳頁一被聊天頁取代 await 就結束了（第一版這樣寫，測試沒效才改）。
  - 「今天」「動態回顧」兩張卡片的文字用 `Expanded` 包住、跟圖示之間加 12 間距，畫面窄或字體最大時文字換行，不會把圖示擠出卡片（Console 原本有 `RenderFlex overflowed`，拖動 DevTools 寬度時出現）。
- `lib/main.dart`：加上 `navigatorObservers: [appRouteObserver]`。
- 測試：寫完日記在完成頁按「回首頁」，不刷新就顯示「已完成今天的紀錄」和月曆照片；新註冊帳號會進新手教學引導頁。

### 測試（10/20，Chrome，後端沒開）
- 暫時把 `main.dart` 的 `home` 改成 `MainScreen`、`useMockWall` 改成 `true` 測試，測完已用 `git restore` 還原，沒有 commit。
- 第 2 格圖示、文字正常；選中時綠色圓圈＋白色圖示，沒選中時灰色小圖示。
- 深色模式、字體最大時文字沒有被截斷；動態牆列表在深色模式、字體放大下也正常。
- 新手教學第 3 步要從登入流程進入，這次沒測，後端開了再看。

### 已知延後項目
- 動態牆未登入時（例如 token 過期），錯誤畫面標題是「尚未登入，請重新登入」，但說明寫「請確認網路後再試一次」、圖示是斷網的雲、按鈕是「重新載入」，按了不會有變化。建議未登入時改成「前往登入」按鈕（`social_wall_page.dart` 第 212 行起，交給欣紜）。
- 使用者名稱、點月曆日記照片要開什麼，待 10/21 開會討論，見 `docs/frontend_todo.md` L。
- PR 到 `dev` 要等後端 `feat/wall-post-integration` 合併。
- 整理菜籃依同一標準還有幾項可以再確認（火腿的生熟、蝦子與豬肉的顏色），見 `docs/frontend_todo.md` K。

---

## 欣紜（動態牆：計劃書版列表／按讚／留言／刪除，串接後端 API；冰箱清點：移除測試模式／退出導航統一）— 2026/10/19

### 本次異動目標
- 完成動態牆前端，並串接筠淇的後端 API（S-2、S-8、S-12、S-13、S-14、S-15）。
- 依 Wen 10/14〈分享到動態牆：對接說明〉3.2 統一更新 `PostModel`（兩組共用），讓 Wen 可以接 S-1。
- 冰箱清點：移除開發期間的測試按鈕與假資料，退出導航與其他遊戲統一。

### 動態牆組決定（欣紜、筠淇）
- 採計劃書版：所有登入使用者都看得到彼此的貼文，可以按讚、留言（待確認事項 #1）。
- 這次只做文字留言，語音加油延到 11 月（#2、#3）。
- 版面參考比賽版「社群動態」：小圖在左、文字在右，點卡片展開留言。
- 放在底部導覽列第 2 格（原「資訊站」），分頁名稱待定。

### 修改檔案（動態牆）
- `lib/features/social/models/post_model.dart`
  - 新增 `AuthorModel`（`user_id`、`display_name`、`avatar_url`），另加別名 `typedef PostAuthor = AuthorModel`，對齊 Wen 的對接說明。
  - `PostModel` 依需求表 7.2 補上 `post_type`、`author`、`is_mine`、`comment_count`、`is_share_enabled`；`share_url`、`is_share_enabled` 改成可為 null（別人的貼文後端回 null，原本 `as String` 會直接報錯）；`diary_id` 改成可為 null。
  - 數字欄位改用共用轉型函式，後端回 double 也不會出錯；新增 `copyWith()`，按讚、留言後只更新部分欄位。
  - `CommentModel` 依需求表 7.3 補上 `author`、`is_mine`（`sender_name` 保留）。
  - 新欄位都有預設值，`VoiceReplyModel` 沒動，不影響 Wen 的 S-1 mock。
- `lib/features/social/services/social_service.dart`
  - 動態牆改呼叫真實後端：S-2 列表、S-11 詳情、S-8 按讚／取消、S-13 留言列表、S-14 新增留言、S-12 刪除貼文、S-15 刪除留言。
  - 網址用 `ApiConstants.serverUrl`，header 用 `authHeaders()`。
  - 動態牆 API 成功時回 `{"data": ...}`，**沒有 `success` 欄位**，所以不能用遊戲用的 `parseEnvelope`；改看 HTTP 狀態碼判斷成功，失敗時用 `api_response.dart` 的 `parseApiError` 解析錯誤。回應用 `bodyBytes` 解碼，避免中文亂碼。
  - 保留假資料，檔案上方 `useMockWall` 改成 `true` 就能在後端沒開時看畫面。
  - S-1、S-5、S-6、S-7（Wen 那組）的 mock 原封不動，移到檔案下半部並註明。
- `lib/features/social/widgets/post_card.dart`（改寫）
  - 收合時：小圖在左；作者、標題、兩行內文、日期在右；右下角按讚數與留言數。點卡片、留言數或箭頭展開。
  - 展開後：留言列表（由舊到新）＋留言輸入框（1～200 字）。第一次展開才讀取留言。
  - 自己的貼文、留言一律顯示「我」，不顯示本名；自己的留言加綠色外框，別人的頭像統一灰綠色（避免留言多時畫面太花）。
  - 刪除：自己的貼文展開後最下方有「刪除這則貼文」；自己的留言、或自己貼文下的留言旁有垃圾桶。刪除前一律跳確認視窗。
  - 錯誤時顯示後端的中文訊息（例如未登入、留言字數不符）。
  - 支援深色模式、高對比、字體縮放。
- `lib/features/social/pages/social_wall_page.dart`（新增）
  - 動態牆列表頁：共用 `TopBar`、標題（暫定「動態牆」）、下拉重新整理，以及載入中／沒有貼文／載入失敗三種畫面。
  - 背景用米白色 `0xFFF5F4EE`（參考比賽版），讓白色卡片跟背景區分得出來；直接指定顏色，不依賴外層主題。
- `lib/screens/main_screen.dart`：第 2 個分頁從空白頁換成 `SocialWallPage`，按鈕名稱暫時維持「資訊站」。

### 修改檔案（冰箱清點）
- `lib/features/game/fridge_inventory/pages/fridge_tutorial_page.dart`：教學頁「青椒」改為「甜椒」。
- `lib/features/game/fridge_inventory/pages/fridge_game_page.dart`
  - 移除錯誤畫面的三顆「測試成績頁（100／80／45 分）」按鈕與 `_openTestResultPage()`，連線失敗時只剩「重新連線」。
  - 暫停選單「退出遊戲」從 `popUntil(isFirst)` 改為 `pushAndRemoveUntil(GameHomeScreen)`。
- `lib/features/game/fridge_inventory/pages/fridge_result_page.dart`
  - 移除 `isTestMode` 參數與測試用歷史資料（35→60→70→85），只讀後端真實歷史成績。
  - 「退出」從 `pop()` 改為 `pushAndRemoveUntil(GameHomeScreen)`。

### 目前狀態
- 動態牆已用筠淇的測試環境在 Chrome 實測，三個測試帳號交叉確認：列表、按讚／取消、留言列表、新增留言、刪除留言、自己／別人的貼文與留言區分、刪除按鈕只出現在有權限的地方，皆正常。刪除貼文只測到確認視窗「取消」，沒有刪除示範資料。
- 冰箱清點的修改**尚未連後端實測**（暫停選單與結算頁的退出、Wen 10/09 改的頂部列）。

### 已知延後項目
- 分頁名稱（「資訊站」要改成什麼）待組內決定，改 `main_screen.dart` 的 label 一行即可。
- 動態牆目前只讀第一頁（每次 20 則），貼文多了之後要補「往下滑載入更多」。
- S-11 貼文詳情的呼叫已寫好，但畫面上還沒用到；之後做「點通知跳到貼文」時使用，並要處理貼文已被刪除（404）的情況。
- 語音加油 11 月再做；`share_url` 依 Wen 10/14 說明這次不顯示。
- 冰箱清點：已請後端把題目敘述改成「請點選○○左邊的食材」句型，遊戲畫面食材名稱（後端回傳的 `food_name`）pepper 改為甜椒；結算頁折線圖改用共用元件、送答案錯誤訊息改用 `parseApiError`、清除 `print` 尚未處理。

### 給接手組員的提醒
- `post_model.dart` 是動態牆與分享（S-1）共用，要加欄位請先跟對方說一聲。
- 動態牆 API 回傳**沒有 `success` 欄位**，新增社群相關 API 請沿用 `social_service.dart` 的 `_handleResponse()`，不要用 `parseEnvelope`。
- 想在後端沒開時看動態牆畫面：把 `social_service.dart` 的 `useMockWall` 暫時改成 `true`，記得改回 `false` 再 commit。
- `api_constants.dart` 的 `serverUrl` 只在自己電腦改，不要 commit。

---

## 蘇蘇（換後端網址／菜市場購物送出作答時間 reaction_time_ms）— 2026/10/19

### 本次異動目標
- 後端要求菜市場購物的選菜（`item-answers`）、找零（`change-answers`）送出時多帶 `reaction_time_ms`。

### 修改檔案
- `lib/core/constants/api_constants.dart`（**模組外的檔案**）：`serverUrl` 換成 `https://clusters-readings-assignments-tracking.trycloudflare.com`，只改這一行。
- `market_shopping/services/market_shopping_service.dart`：`submitItemAnswer`、`submitChangeAnswer` 多一個必填參數 `reactionTimeMs`，放進 body 的 `reaction_time_ms`。
- `market_shopping/pages/market_shopping_game_page.dart`：`_submitItemAnswer`、`_submitChangeAnswer` 多收 `reactionTimeMs` 往 service 傳。
- `market_shopping/pages/market_shopping_play_page.dart`、`market_shopping_checkout_page.dart`：各加一個 `Stopwatch`。
  - 進到選菜／結帳畫面開始算，按下確認（選菜）或選了金額（找零）時停錶並送出。
  - 答錯重答時歸零，重新從 0 算（只算這一次作答）。
  - 按「選單」暫停時停錶，按繼續或看完教學回來才接著算；點鈴鐺進通知頁時也停錶，回來才接著算；送出失敗時繼續累計。

### 後端說明（前端不用改）
- 有一款遊戲的 API 是一次回傳全部結果，後端改成用 28 題的 `reaction_time_ms` 加總來算時長，前端不用新增欄位。
- 菜市場找路、煮菜過程送的是 `response_time_ms`，另外三款是 `reaction_time_ms`，前端目前送的名稱跟後端一致。如果後端之後統一名稱，要改 `go_to_market_service.dart`、`memory_recall_service.dart`。

### 目前狀態
- `flutter analyze lib/features/game/market_shopping lib/core/constants`：沒有新增問題（剩下的 5 個是原本就有的）。
- 還沒在實機上連新網址實際玩過。

---

## Wen（月曆改顯示日記照片／註冊後自動登入／錯誤提示改為中文）— 2026/10/16

### 本次異動目標
- 10/16 凌晨接詩雅的後端繼續測試時，發現三個問題，一併修正：
  - 月曆有日記的日期只有星星，點下去會變成深綠圓圈、蓋掉標記
  - 註冊成功後沒有存 token，進到 App 後所有需要登入的功能都讀取失敗
  - 錯誤提示直接顯示原始錯誤（`ClientFailed to fetch, uri=https://...`、`Exception: ...`），長輩看不懂，還會露出後端網址

### 新增檔案
- `lib/core/network/error_message.dart`：共用函式 `friendlyErrorMessage(error, fallback:)`，把例外轉成中文提示
  - 連不上後端（`http.ClientException`）、逾時（`TimeoutException`）：統一顯示「連線失敗，請檢查網路後再試一次」
  - 沒有 token（`NotLoggedInException`）、後端統一格式錯誤（`ApiException`）：顯示裡面的中文訊息
  - 各 service 自己丟的 `Exception('中文訊息')`：去掉前面的「Exception: 」
  - 其他沒預期到的錯誤：顯示 `fallback`

### 修改檔案
- `lib/features/diary/widgets/diary_calendar.dart`：
  - 有日記的日期改成用那天的日記照片填滿圓形、外圈金色（對照比賽版 `index.css` 的 `.dot-photo`）；沒有照片或載入失敗時，退回淡金底＋日期數字
  - 拿掉「選取」狀態：點日記是打開那篇日記，不需要記住選了哪天，原本點過會變成深綠圓圈、蓋掉日記標記
  - 改用 `prioritizedBuilder`，今天剛好有日記時也會顯示照片，不會被「今天」的樣式蓋掉
- `lib/features/auth/services/auth_service.dart`：
  - 新增 `loginAndSaveToken()`：登入並存 access token，登入頁、註冊頁共用，存 token 的寫法只有這一份；拿不到 token 時丟出錯誤，不再照樣進 App
  - 錯誤訊息改成中文：帳號重複（400）→「這個帳號已經有人使用，請換一個帳號」、帳號密碼錯誤（401）→「帳號或密碼錯誤，請再確認一次」；原始回應只用 `debugPrint` 印在終端機（原本 4 處 `print` 改為 `debugPrint`）
- `lib/features/auth/pages/register_page.dart`：註冊成功後自動登入並存 token，再進歡迎頁；自動登入失敗時提示「註冊成功！請用剛才的帳號密碼登入」並帶到登入頁
- `lib/features/auth/pages/login_page.dart`：改用 `loginAndSaveToken()`；錯誤提示改用 `friendlyErrorMessage()`
- `lib/features/diary/pages/diary_chat_page.dart`：送出錄音、跳過本題失敗的提示改用 `friendlyErrorMessage()`（原本是「送出失敗，請再試一次（Exception: …）」）
- `lib/features/diary/pages/diary_finish_page.dart`：分享到動態牆失敗的提示改用 `friendlyErrorMessage()`
- `lib/features/diary/widgets/record_button.dart`：錄音啟動失敗、處理失敗的提示拿掉原始錯誤
- `docs/frontend_todo.md`：勾選上述項目，更新待測試清單

### 目前狀態
- `fvm flutter analyze lib/features/auth lib/features/diary lib/core` 沒有 error；這次新增、修改的程式沒有新的 warning（清單裡 `auth_service.dart` 的 `use_null_aware_elements`、`tutorial_overlay.dart` 的 warning 都是原本就有的，已記在 todo F 段）
- 10/16 接詩雅的後端在 Chrome 測試：
  - 動態回顧：新註冊的帳號沒有日記，兩個分頁都正確顯示空狀態；深色模式、字級超大時的空狀態正常
  - 月曆：`testuser` 10/14 的日記顯示照片，點擊後不會變成深綠圓圈
  - 註冊：註冊後直接進聲影日記，月曆、動態回顧都能讀取；同一帳號再註冊顯示「這個帳號已經有人使用」
  - 登入：打錯密碼顯示「帳號或密碼錯誤」
  - 連線失敗：故意把 `serverUrl` 改錯，註冊頁、登入頁都顯示「連線失敗，請檢查網路後再試一次」，不再出現網址
- 完整寫日記沒有測成：錄音送出一直回 `TRANSCRIPTION_FAILED`，是詩雅電腦上的 Whisper 出錯（可能是 ffmpeg），已請她查後端終端機

### 已知延後項目
- 聲影日記上傳提示、聊天泡泡播放停止（10/7 修正）、月曆「今天有日記時顯示照片」、新日記分享回 201：等詩雅那邊 Whisper 修好再測
- 有日記卡片時的動態回顧深色模式、字級超大：要先請後端跑 `seed_review_diaries`
- 月曆照片會蓋住日期數字，先照比賽版維持，組員覺得不清楚再考慮在照片角落加小數字
- 冰箱清點的錯誤畫面還是直接顯示 `$e`，之後改用 `friendlyErrorMessage()`

### 給接手組員的提醒
- 畫面上顯示錯誤一律用 `friendlyErrorMessage(e, fallback: '…')`（`lib/core/network/error_message.dart`），不要直接顯示 `$e` 或 `e.toString()`；原始錯誤用 `debugPrint` 印在終端機
- 登入、註冊後要存 token 一律用 `AuthService.loginAndSaveToken()`，不要自己讀 `result['access']` 存
- 測註冊流程時注意：每次 `flutter run -d chrome` 的瀏覽器資料可能保留上一個帳號的 token，要確認是不是新帳號的狀態，可以先 F12 → Application → Storage →「Clear site data」

---

## Wen（聲影日記：完成頁「分享到動態牆」按鈕／動態回顧改為獨立頁面／接上真實後端 D-2、S-1）— 2026/10/14–10/15

### 本次異動目標
- 依 10/7 會議與《聲影日記組 API 需求表》，開始下一階段「動態回顧＋分享」的前端。
- 筠淇 10/14 把「日記生成後自動建立動態牆貼文」拿掉，改成使用者在完成頁按「分享到動態牆」才呼叫 S-1 建立貼文。
- 動態回顧原本是首頁的底部彈窗，改成獨立頁面，版面對照比賽版 `review.html`。
- 10/15 接上詩雅的後端（`feat/wall-post-integration`），D-2、S-1 改打真實 API。

### 新增檔案
- `lib/features/diary/pages/diary_review_page.dart`：動態回顧頁
  - 上方「昨天／去年的今天」切換；下方日期標籤顯示「2026年10月13日 星期二」，切換鈕已經寫了「昨天」，標籤只放日期
  - 日記卡片：照片（16:9）、標題、完整內文、「播放語音」按鈕；卡片裡不再重複日期
  - 語音直接在卡片上播放，不另外彈出視窗（比賽版是點開彈窗才播放，但我們的卡片已經顯示完整內容，彈窗只多一個播放器）。按下變成「暫停」並顯示播放時間，暫停後再按從原處繼續，播完再按從頭播
  - 整頁共用一個 `AudioPlayer`，同一時間只播一篇；切換分頁、離開頁面時停止
  - 播放最多等 15 秒，逾時或音檔讀不出來時顯示「語音播放失敗」並恢復按鈕；切換分頁時會讓還在載入的播放請求失效，切回來不會卡在轉圈
  - 讀取失敗顯示訊息與「重新載入」；沒有日記時顯示空狀態（「這天還沒有日記」）
  - 淺色、深色、高對比配色集中在檔案最下面的 `_ReviewColors`，深色沿用完成頁的配色

### 修改檔案
- `lib/features/diary/services/diary_service.dart`：
  - 新增 `shareToWall(diaryId)`：S-1 `POST /api/diary/{id}/share/`，新建立（201）或已分享過（200）都視為成功，只讀回傳的 `post_id`，不解析整個貼文物件（`PostModel` 由動態牆組維護，兩邊不用改同一個檔案）
  - `getDiaryReview()` 改成 D-2 `GET /api/diary/review/`，`DiaryReviewResult` 從「單篇或 null」改成 `yesterday`、`lastYear` 兩個陣列（同一天可能不只一篇，需求表改為陣列）
  - 新增兩個假資料開關 `_useMockShareToWall`、`_useMockReview`，開發時先用 `true`，10/15 接上後端後改為 `false`；之後後端沒開、只想看畫面時可以暫時改回 `true`
- `lib/features/diary/models/diary_model.dart`：`DiaryReviewItem` 對照需求表 9.1 補上 `isShared`、`postId`、`createdAt`；`audioUrl` 改成可為 null，後端回空字串也當成沒有錄音（不顯示播放鍵）
- `lib/features/diary/pages/diary_finish_page.dart`：
  - 新增「分享到動態牆」按鈕，三種狀態：可以按（深綠）→ 分享中（轉圈）→ 已分享到動態牆（淺綠打勾、不能再按）；初始狀態看 `diary.isShared`，失敗時顯示後端的錯誤訊息、按鈕恢復可按
  - 按鈕跟 LINE、Facebook、儲存圖片、複製連結排成同一組，間距統一 12、圓角統一 16；拿掉「分享這則日記」標題；「Facebook」改為「Facebook 分享」
  - S-1 回傳的 `share_url` 這次刻意不接到 LINE／Facebook／複製連結（親友分享頁 11 月才做，現在點開會是 404）
- `lib/features/diary/pages/diary_home_page.dart`：「動態回顧」按鈕改成打開新頁面，刪除原本的底部彈窗
- `lib/core/constants/route_constants.dart`、`lib/main.dart`：新增路由 `voiceDiaryReview`
- `docs/frontend_todo.md`：新增 I（動態回顧＋分享）、待測試清單補上這次的項目

### 目前狀態
- `fvm flutter analyze lib/features/diary lib/main.dart` 沒有新的 error 或 warning；新頁面只多一則 `intl` 的 info，原因跟完成頁原本那則相同（`pubspec.yaml` 沒有直接列 `intl`）
- 10/14 Chrome 預覽（假資料、後端未開）：完成頁按鈕三種狀態與版面；動態回顧分頁切換、日期標籤、卡片版面、空狀態、播放逾時與切換分頁後的復原
- 10/15 接詩雅的後端（`feat/wall-post-integration`，測試帳號由 `seed_review_diaries` 建立）在 Chrome 測試：
  - D-2：昨天、去年的今天都讀得到，照片、日期、標題、內文正常；去年那篇可以播放、暫停、繼續，播放中切換分頁聲音會停
  - D-2：昨天那篇的測試錄音網址（`park_fountain.ogg`）已失效（404），前端正確顯示「語音播放失敗」並恢復按鈕，已請詩雅換測試資料
  - S-1：第一次分享回 201、再分享一次回 200（同一則貼文，不重複建立），按鈕都正確切換成「已分享到動態牆」

### 已知延後項目
- 這次 PR 需要後端 `feat/wall-post-integration`（D-2、S-1）合併後才能使用；後端還沒合併前，連到其他後端時動態回顧會顯示「讀取失敗」
- 完成頁的 `share_url`：11 月親友分享頁（P-1）完成後，再接到 LINE／Facebook／複製連結
- D-4 單篇詳情：後端已完成，首頁月曆點日期目前還是跳提示（`_onDiaryTap`），之後再接
- 這兩頁的深色模式、字級最大時的版面還沒測（測試時是用暫時改 `home:` 的方式直接進頁面，沒有經過設定頁）
- 一天一篇或多篇日記待組長決定（目前前端會擋、後端 D-3 沒擋）；動態回顧用陣列，兩種都能顯示

### 給接手組員的提醒
- 動態牆組改 `PostModel` 不會影響完成頁：S-1 在 `DiaryService` 只讀 `post_id`
- D-2 回傳的 `yesterday`、`last_year` 是陣列，沒有日記時是空陣列，不是 null
- 動態回顧的播放器整頁共用，`ReleaseMode.stop` 讓播完的音檔保留，再按可以從頭播；之後在這頁加其他會發出聲音的元件，記得先停掉這個播放器
- 測試動態回顧要有「昨天」和「去年的今天」的日記：請後端執行 `python manage.py seed_review_diaries`（帳號 `testuser`／`Test123456!`）。「昨天」是以執行指令那天計算，隔天測要重新執行
- 測試時暫時把 `main.dart` 的 `home:` 換成要看的頁面很方便，測完要改回 `const AuthGate()`，再用 `git diff lib/main.dart` 確認沒有殘留
- 每台後端的資料庫各自獨立，換後端網址後舊的 token 不能用；Chrome 直接進主畫面卻讀取失敗時，F12 → Application → Storage →「Clear site data」後重新登入

---

## 蘇蘇（健康儀表板首頁／六大能力說明／週報表，先用假資料）— 2026/10/12

### 本次異動目標
- 完成健康儀表板三個畫面：儀表板首頁（狀態卡片＋雷達圖）、六大能力說明（六宮格＋說明頁）、週報表。
- 後端 API 還沒完成，資料先用假資料，資料格式已定好，之後接 API 只要改 service。

### 修改檔案
- `lib/screens/main_screen.dart`（**模組外的檔案**）：底部導覽「儀表板」那一格原本是空白頁 `Scaffold(body: Center(child: Text('儀表板')))`，換成 `DashboardPage()`，並加上 import。只改這兩行。
- `pubspec.yaml`：新增 `flutter_animate`（週報表進場、打卡圓點動畫）、`visibility_detector`（區塊捲到畫面上才播動畫）。
- 新增 `lib/features/dashboard/`：
  - `models/ability_catalog.dart`：六大能力的代號、名稱、圖示、說明文字、截圖路徑。代號跟遊戲首頁一致（`language`、`working_memory`…）。雷達圖順序另外定義在 `kRadarAbilityOrder`（照設計稿）。
  - `models/dashboard_models.dart`：儀表板、週報表的資料格式和 `fromJson`。
  - `services/dashboard_service.dart`：`getOverview()`、`getWeeklyReport()`，目前回傳假資料（寫成 JSON 再走 `fromJson`）。`_mockFirstWeek` 改成 `true` 可以看「第一週」的畫面。
  - `pages/dashboard_page.dart`：儀表板首頁，頂部列用共用的 `TopBar`。
  - `pages/ability_menu_page.dart`：六宮格，直接用遊戲首頁的 `DomainCard` 和同一套排版。
  - `pages/ability_detail_page.dart`：說明頁，左右大箭頭或手指滑動切換，循環切換（數學 → 語言）。從週報表進來時最下面按鈕是「回到週報表」，從選單進來是「六大能力選單」。
  - `pages/weekly_report_page.dart`：週報表，往下滑、一個區塊講一件事，區塊捲到畫面上才進場。
  - `widgets/ability_radar_chart.dart`：雷達圖（CustomPainter）。進場時同齡平均先淡入，長者數值從中心長出來；資料更新時從舊形狀平滑變成新形狀；系統開啟「減少動態」時不播動畫。
  - `widgets/robot_avatar.dart`：暫時用程式畫的機器人，3 種表情（good／keep／encourage），之後有正式圖片再換。
  - 其他：`dashboard_palette.dart`（深色模式、高對比配色）、`dashboard_status_card.dart`、`dashboard_load_state.dart`（讀取中／讀不到資料）、`reveal_on_scroll.dart`、`weekly_report_sections.dart`（週報表 7 個區塊）、`diary_preview_dialog.dart`（日記彈窗）。

### 目前狀態
- `flutter analyze lib/features/dashboard lib/screens/main_screen.dart`：0 issue。
- 用 widget test 跑過（測完已移除）：手機寬 360／412、字級標準／超大（145%）、淺色／深色，三個畫面都沒有溢出；選單 → 說明頁 → 左右箭頭切換、從週報表進入顯示「回到週報表」都正常。
- 還沒在實機或 Chrome 上看過動畫實際效果。

### 待補（等資料或後端）
- 六大能力說明的說明文字、遊戲截圖（`ability_catalog.dart` 的 `description`、`screenshotPath`）。
- 正式的機器人圖片。
- 後端 API：資料格式見 `dashboard_models.dart`；一句話總結、下週小目標也由後端產生。待確認的問題：分數的計算期間、「持平」的範圍、連續天數的定義、換日時區、對話時長怎麼算等。

### 給接手組員的提醒
- 接 API 時只改 `dashboard_service.dart`，記得用 `authHeaders()`；欄位名稱如果跟後端不同，改 `dashboard_models.dart` 的 `fromJson`。
- 週報表不使用紅色和「退步」等負面字眼，「多練習」用暖黃色。

---

## Wen（遊戲頂部列統一＋「選單」按鈕／合併讀 token 的寫法／整理菜籃籃子溢出）— 2026/10/09

### 本次異動目標
- 完成 `docs/frontend_todo.md`「新功能開工前（必做）」的兩項：C 頂部列統一（含老師 10/8 建議的「選單」按鈕）、H 合併讀 token 的寫法。下一階段的聲影日記分享、動態回顧、動態牆、儀表板可以直接沿用。
- 測試時發現整理菜籃的籃子在一般手機寬度下溢出，一併修正。

### 修改檔案
- 頂部列統一＋「選單」按鈕：
  - `lib/features/game/widgets/game_in_progress_top_bar.dart`（新增，從 `market_shopping/widgets/` 移過來改寫）：參數改為 `title`、`onMenuTap`、`onNotificationTap`。左上角是「選單」按鈕，標題置中，右上角鈴鐺監聽 `AppSettings.unreadNotificationCount` 顯示紅點；`onNotificationTap` 不傳時不顯示鈴鐺。
  - `lib/features/game/widgets/game_menu_button.dart`（新增）：深綠色「☰ 選單」按鈕，點擊後由各遊戲打開 `GamePause`。`compact: true` 是橫向畫面用的小尺寸。
  - 刪除 `lib/features/game/market_shopping/widgets/game_in_progress_top_bar.dart`、`lib/features/game/market_sort/widgets/market_sort_top_bar.dart`。
  - 市場買菜（`market_shopping_memorize_page.dart`、`market_shopping_play_page.dart`、`market_shopping_checkout_page.dart`）、料理準備（`cooking_prep_game_page.dart`）：改 import 路徑，`onPauseTap` 改名為 `onMenuTap`。
  - 整理菜籃（`lib/screens/market_sort_game_screen.dart`）：改用共用頂部列，鈴鐺補上跳轉通知頁（原本是 TODO）。
  - 冰箱清點（`fridge_game_page.dart`）：原本自己刻的 `AppBar` 換成共用頂部列，放在 `appBar` 的位置，下面的版面不用動；新增鈴鐺跳轉通知頁。
  - 來去菜市場（`go_to_market_game_page.dart`）：橫向畫面頂部空間小，只把返回箭頭換成 `GameMenuButton(compact: true)`，其他不動。
  - `lib/screens/_widget_gallery_screen.dart`：跟著改成新的頂部列。
- `android/.gitignore`：加入 `/build/`，Android 建置暫存資料夾不再出現在 `git status`。
- 合併讀 token 的寫法：
  - `lib/core/network/auth_headers.dart`（新增）：共用函式 `authHeaders()`，從 `TokenStorage` 讀 token 組出 `Content-Type` 和 `Authorization`；沒有 token 時丟出 `NotLoggedInException`（訊息「尚未登入，請重新登入」），不送出請求。上傳檔案等不是送 JSON 的請求用 `authHeaders(json: false)`，只帶 `Authorization`。
  - 原本各自讀 token 的地方全部改用 `authHeaders()`：
    - 料理準備 `memory_recall_service.dart`：刪除 `_authHeaders()`
    - 市場買菜 `market_shopping_service.dart`：刪除 `_getHeaders()`，`getHistory()` 也改用
    - 整理菜籃 `market_sort_api_service.dart`：`submit()` 改用
    - 冰箱清點 `fridge_inventory_service.dart`：刪除 `getToken()`、`_getHeaders()`
    - 來去菜市場 `go_to_market_service.dart`：刪除 `_getHeaders()`
    - 聲影日記 `diary_service.dart`：刪除 `_authHeaders()`，改用 `authHeaders(json: false)`，送出的 header 跟原本一樣
  - `go_to_market_service.dart` 的 `_logFailure()`：沒有 token（`NotLoggedInException`）也設 `unauthorized = true`。原本沒 token 會照樣送出、被後端回 401 才跳重新登入對話框；現在前端先擋下來，少了這行就不會跳對話框。
  - `lib/screens/market_sort_game_screen.dart`：刪除沒有地方呼叫的 `_seedFakeTokenForTesting()`（測試時留下、會寫入假 token）和用不到的 `token_storage.dart` import。
  - 行為差異：有登入時送出的內容跟原本完全一樣，後端不用改。沒有 token 時，原本市場買菜、冰箱清點、來去菜市場、聲影日記會照樣送出然後收到 401，現在統一在前端擋下並提示重新登入。
- `lib/features/game/market_sort/widgets/basket_row.dart`：三個籃子原本寬度固定，加總約 440，超過一般手機寬度（約 360～412），右邊的籃子會被切掉（`RenderFlex overflowed`）。每個籃子改用 `Flexible` 平分寬度，外面包 `FittedBox(fit: BoxFit.scaleDown)`，放不下時整個籃子等比例縮小，螢幕夠寬時維持原尺寸。

### 目前狀態
- 每項修改都跑過 `fvm flutter analyze`（只 analyze 改到的檔案），0 error；剩下的 info 都是原本就有的（冰箱清點的 `print`、來去菜市場的 `+` 接字串）。
- Chrome（iPhone 尺寸、放假 token、後端未開）測過：
  - 整理菜籃：「選單」按鈕、置中標題、鈴鐺紅點與通知頁、暫停選單正常；籃子不再溢出，拖放正常；送出成績失敗時顯示「成績送出失敗」提示，終端機是連線失敗，代表 token 有正常帶出去。
  - 來去菜市場：小尺寸「選單」按鈕正常；後端連不上時進入本地模式，可以玩到結算。
- 市場買菜、料理準備、冰箱清點的頂部列需要後端才能進到遊戲中畫面，還沒測。
- 「沒有 token 時提示重新登入」在 Chrome 上無法單獨測（沒有 token 會被擋在身分選擇頁），待有後端或登出功能時確認。

### 已知延後項目
- 教學頁左上角的箭頭各遊戲行為不一致（有的打開暫停選單、有的直接返回、有的是教學彈窗的上一頁），整理菜籃的教學也跟其他遊戲不太一樣，要先跟組員討論統一規則，下次整合再做。
- 401 重新登入提示目前只有來去菜市場有，其他遊戲和聲影日記待補（建議做成共用元件，可以直接接 `NotLoggedInException`）。
- 其餘見 `docs/frontend_todo.md`。

### 給接手組員的提醒
- **遊戲中的頂部列一律用 `GameInProgressTopBar`**（`lib/features/game/widgets/`），左上角是「選單」，點擊打開 `GamePause`。橫向或空間不夠時，可以只用 `GameMenuButton(compact: true)`。
- **需要登入的 API 一律用 `authHeaders()`**（`lib/core/network/auth_headers.dart`），不要自己讀 `TokenStorage` 組 header。上傳檔案（`MultipartRequest`）用 `request.headers.addAll(await authHeaders(json: false))`。
- 沒有 token 時 `authHeaders()` 會丟出 `NotLoggedInException`，頁面原本的 `catch` 會接到；如果要分開處理「沒登入」，可以寫 `on NotLoggedInException`。
- `api_constants.dart` 的 `serverUrl` 是 Cloudflare 臨時網址，換網址只在自己電腦改，不要 commit。

---

## Wen（會議前後修正：來去菜市場教學頁方向／菜市場購物 session_id 檢查／整理菜籃改用共用暫停選單／舊色碼／遊戲首頁深色模式）— 2026/10/06–10/07

### 本次異動目標
- 以欣紜的 `fix/session-id-uuid`（JWT token、`session_id` 改 UUID 字串）為基礎，開 `fix/pre-meeting-1006` 處理整合後的待辦（見 `docs/frontend_todo.md`）。
- 修正來去菜市場教學頁用 Android 系統返回鍵離開時，遊戲首頁停在橫向的 bug。
- 暫停選單統一、舊色碼改用主題色，遊戲首頁補上深色模式（9/30 開會發現遊戲首頁完全沒套用深色模式和字級）。

### 修改檔案
- `lib/features/game/go_to_market/pages/go_to_market_tutorial_page.dart`
  - 新增 `openedFromGame` 參數，區分教學頁是從遊戲首頁還是從遊戲中（暫停選單、說明按鈕）打開。
  - 設回直向的動作移到 `dispose()`，系統返回鍵和手勢離開也會執行；從遊戲中打開、或正要換成遊戲頁時不設回直向。原本放在 `dispose()` 會出錯的原因：`pushReplacement` 換成遊戲頁時，教學頁的 `dispose()` 比遊戲頁的 `initState()` 晚執行，會把遊戲剛鎖好的橫向改回直向。
  - 「開始挑戰」「略過教學」共用 `_startGame()`：從遊戲中打開時改成返回並通知遊戲重新開始，修正原本會在遊戲頁上面再疊一個遊戲頁的問題。
  - `State` 補上型別 `State<GoToMarketTutorialPage>`。
- `lib/features/game/go_to_market/pages/go_to_market_game_page.dart`：暫停選單和說明按鈕打開教學時帶 `openedFromGame: true`；教學頁回傳 `true` 時呼叫 `_resetGame()`。
- `lib/features/game/market_shopping/models/market_shopping_models.dart`：`GameSession.fromJson` 拿不到 `session_id` 時直接丟出例外，不再用空字串繼續（原本下一步會打到 `/sessions//item-answers/`，只得到看不懂的 404）。錯誤畫面與「重試」按鈕沿用遊戲頁原本的 `catch`。
- `lib/screens/market_sort_game_screen.dart`：暫停選單從 `PauseModal`（畫面覆蓋層）改成共用的 `GamePause.show()`（對話框），移除 `_showPause`。四個按鈕的行為不變。用 Android 返回鍵關掉對話框時沒有按到任何按鈕，當作「繼續遊戲」，避免遊戲停在暫停狀態。
- `lib/features/game/market_sort/widgets/pause_modal.dart`：刪除，五款遊戲的暫停選單都改用 `GamePause`。
- `lib/features/game/market_sort/widgets/result_score_card.dart`、`result_history_chart.dart`：暫時測試色 `_testPrimaryColor`（`0xFF2E5940`）改用 `AppTheme.primaryColor`。
- 遊戲首頁深色模式、高對比、字級（配色沿用首頁 `home_screen.dart`、`game_card.dart` 的寫法）：
  - `lib/screens/game_home_screen.dart`：外層用 `ValueListenableBuilder` 監聽 `isDarkMode`，深色背景 `0xFF121212`。
  - `lib/features/game/widgets/game_top_bar.dart`：圖示深色改 `0xFF4CAF50`，高對比改純黑／純白。
  - `lib/features/game/widgets/domain_card.dart`：卡片深色底 `0xFF25382E`（按下 `0xFF32503F`）、文字 `0xFFB8E6D0`；高對比加外框；標題用 `FittedBox` 避免字放大時溢出。
  - `lib/features/game/widgets/training_progress_card.dart`：進度條舊主色 `0xFF5B9E87` 改用 `AppTheme.primaryColor`（深色模式用 `0xFF4CAF50`）；卡片套用深色與高對比；「今日已完成」那行改用 `Expanded`，字放大時自動換行。
  - `lib/features/game/widgets/game_bottom_actions.dart`：「我的成就」外框按鈕深色底改 `0xFF1E1E1E`、框線與字改亮綠；文字加 `Flexible` 避免溢出。
  - 4 個元件各自用 `ListenableBuilder` 監聽 `fontSizeLevel`、`isDarkMode`、`isHighContrast`，文字改用 `AppSettings.scaleFont()`。
- `docs/frontend_todo.md`：新增 G（聲影日記）、H（API 串接）兩段，勾選已完成項目，補上 `flutter analyze` 發現的 warning。

### 目前狀態
- 每項修改都跑過 `fvm flutter analyze`，0 error；剩下的 info／warning 都是原本就有的。
- 整理菜籃暫停選單、遊戲首頁深色模式已在 Chrome 測過。
- **來去菜市場教學頁的螢幕方向尚未實機測試**：Chrome 上螢幕方向不會變；這次 Android 模擬器因電腦記憶體不足沒跑起來。

### 已知延後項目
- 來去菜市場教學頁方向修正，待 Android 實機或模擬器測試以下四種情況：從遊戲首頁進入後用系統返回鍵離開、略過教學進入遊戲、遊戲中開說明再返回、遊戲中開說明再按開始挑戰。
- 遊戲首頁深色模式的字級目前用 `AppSettings.scaleFont()`，之後做字體縮放全域化時要一起改。
- 其餘待辦（登入／註冊／教學頁深色模式、聲影日記播放暫停與上傳提示、字體縮放全域化、頂部列統一、401 提示共用化等）見 `docs/frontend_todo.md`。

### 給接手組員的提醒
- 以後從遊戲中打開來去菜市場教學頁，要帶 `GoToMarketTutorialPage(openedFromGame: true)`，不然離開時會被設回直向。
- 暫停選單一律用 `GamePause.show()`，不要再各自刻。`GamePause` 是對話框，按鈕會先關掉對話框再執行 callback；用 Android 返回鍵關掉時四個 callback 都不會被呼叫，記得處理（可參考 `market_sort_game_screen.dart` 的 `_openPause()`）。
- 深色配色請沿用 `home_screen.dart`、`game_card.dart`：背景 `0xFF121212`、卡片 `0xFF25382E`、文字 `0xFFB8E6D0`、圖示 `0xFF4CAF50`。
- `api_constants.dart` 的 `serverUrl` 是 Cloudflare 臨時網址，每次後端重開都會變，換網址只在自己電腦改，不要 commit。

---

## Vevila（料理準備：對齊後端前測判斷／單題作答時限／錯誤碼，前測結束直接進正式賽）— 2026/10/05

### 本次異動目標
- 修正「前測（練習題）結束後直接跳出結算與歷史紀錄」：前測是給第一次玩的使用者練習，結束後應直接進正式賽。
- 後端組員對照 `games/memory_recall/views.py` 指出前端有幾個假設跟後端不一致，一併修正：前測由後端判斷、正式賽每題有作答時限、時間到是錯誤碼不是 `action`。

### 修改檔案
- `lib/features/game/cooking_prep/pages/cooking_prep_game_page.dart`
  - 移除本機旗標 `memory_recall_has_played`：後端不讀 `start/` 的 `is_pretest`，前測與否完全依資料庫判斷，改用 `start/` 回應的 `is_pretest`。
  - 前測結束：呼叫 `finish/` 後直接 `_startGame(showTutorial: false)` 開正式賽，不顯示結算、不寫進歷史成績、不再顯示一次教學。
  - 新增正式賽單題倒數條（`kRoundTimeoutSeconds = 10`，對應後端 `ROUND_TIMEOUT_SECONDS`）。從呼叫 `round/` 開始算、暫停不補償，跟後端計時一致；歸零時主動結算。
  - 依錯誤碼顯示結束原因：`ROUND_TIME_UP` →「本題超過作答時間」、`GAME_TIME_UP` 與本地整場倒數歸零 →「時間到！」，顯示 1.5 秒後才進結算，不會「突然結束」。
- `lib/features/game/cooking_prep/services/memory_recall_service.dart`：`startGame` 註解改為說明後端不讀 `isPretest`。
- `docs/cooking_prep_system.md`（新增）：料理準備前端完整系統說明（流程、狀態、計時、結算、錯誤處理、已知問題）。
- `docs/cooking_prep_frontend_spec.md`：更正 `session_id`（UUID 字串）、`action` 只有三種、完整錯誤碼、`finish/`／`result/` 回傳格式、`is_correct` 判定已確認正確、移除過時的 ver5 展示邏輯。

### 目前狀態
- `flutter analyze lib/features/game/cooking_prep` 0 error（只剩 service 原本就有的 1 個 info）。
- **尚未實機測試**：前測→正式賽銜接、單題超時、暫停後超時、整場時間到都還要跑一次確認。

### 已知延後項目
- 單題時限從 `round/` 開始算（物品展示時間也算在內）、暫停無效：需要後端調整（選項揭曉後才計時，或支援暫停），並建議在 `config/` 提供時限秒數。
- 中途離開（退出、重新開始）沒有呼叫 `finish/`。

### 給接手組員的提醒
- 後端正式上線把 `ROUND_TIMEOUT_SECONDS` 改成 20 時，前端 `kRoundTimeoutSeconds` 要一起改。
- 想重新測前測，清 App 資料沒用，要換一個後端沒有結束紀錄的帳號。

---

## Wen（前端整合：合併冰箱清點、料理準備／後端網址集中到 ApiConstants／修正冰箱清點 token 讀取）— 2026/10/05

### 本次異動目標
- 把三組分支整合到 `integrate/frontend-1004`：Wen 的 `feature/wen-diary-setup`（聲影日記、整理菜籃）為基底，合併欣紜的 `game-fridge-inventory`（冰箱清點）、蘇蘇的 `feature/cooking-prep`（料理準備）。
- 後端網址原本散在 7 支 service、混用 3 個不同的 trycloudflare 網址，集中到一個地方管理。

### 合併時的處理方式
- `lib/main.dart`：保留 `AuthGate`（登入檢查）與 `onGenerateRoute` 路由。欣紜版本的開機畫面 `GameHomeScreen`、蘇蘇版本的 `IdentitySelectPage` 都沒有採用，未登入時 `AuthGate` 本來就會導到身分選擇頁。保留蘇蘇加的「開機強制直向」，避免 hot restart 後殘留橫向設定。
- `pubspec.yaml`：套件以 Wen 的版本為主，assets 補上 `fridge_inventory/`、`cooking_prep/`、`assets/audio/game/`。
- `lib/screens/game_home_screen.dart`：兩邊的 import 都保留。目前五個領域都已接上：視覺空間→冰箱清點、數學→市場買菜、執行功能→整理菜籃、注意力→來去菜市場、工作記憶→料理準備（只剩語言是敬請期待）。
- 刪除 `changes.diff`（`git diff` 的輸出檔，誤 commit 進來的，不影響程式）。

### 修改檔案
- `lib/core/constants/api_constants.dart`：新增 `serverUrl`，後端網址只寫在這裡。
- 7 支 service 改用 `${ApiConstants.serverUrl}` 組網址，路徑後半段不變：`auth_service.dart`、`diary_service.dart`、`go_to_market_service.dart`、`market_shopping_service.dart`、`market_sort_api_service.dart`、`fridge_inventory_service.dart`、`memory_recall_service.dart`
- `lib/features/game/fridge_inventory/services/fridge_inventory_service.dart`：讀 token 原本用 `auth_token`，但登入時存的是 `access_token`（`TokenStorage`），所以一直拿不到 token。改成跟其他遊戲一樣用 `TokenStorage.getAccessToken()`。

### 目前狀態
- `flutter analyze` 全專案 0 error（只剩原本就有的 info 提示）。
- 整合後的後端還沒完成，尚未連線實測。10/5 由欣紜、小惠對接測試。

### 已知延後項目
- 共用元件統一、字體縮放全域化、深色模式補齊、橫向鎖定共用化，整理在 `docs/frontend_todo.md`。

### 給接手組員的提醒
- 後端換網址，只要改 `api_constants.dart` 的 `serverUrl` 一行，存檔後重新 `flutter run`。只有後端改了某個功能的路徑（例如 `/api/diary/`），才需要回去改那支 service。
- 之後新增的 service 一律用 `ApiConstants.serverUrl` 組網址、用 `TokenStorage` 讀 token，不要再寫死網址或自己存取 SharedPreferences。
- commit 前先 `git status` 看清單，不要用 `git add .`。plugin 那幾個檔案和 `pubspec.lock` 常被自動改動，用 `git restore linux macos windows pubspec.lock` 還原。

---

## 蘇蘇（料理準備：修正 1-back 預覽時機 bug／拿掉多餘的橋接輪邏輯／新增前端規格文件）— 2026/10/04

### 本次異動目標
- 後端團隊看過實測 log 後回報：`cooking_prep`（記憶配對／memory_recall 美術包裝）原本的展示時機搞錯了——每輪選項卡出現前，畫面展示的是「上一輪」的 `new_item`，而那個值剛好就是這一輪的正解，等於出題前就先把答案秀給玩家看，整個遊戲變成「看了就選」，不是真正的 1-back 記憶測驗。照後端給的正確約定重寫展示邏輯。
- 後端同時更新：`round/answer/` 不再回傳 `seed_item`（升階不換種子，鏈不中斷）、升階門檻 `promote_streak` 從 3 改成 6、高階卡片的干擾物可能來自任何階段（不再保證同組）。
- 補一份 `cooking_prep` 的前端規格文件，把 API 契約、核心邏輯、已知問題整理成文件，方便之後跟後端對接或交接。

### 修正 `_fetchNextRoundAndPreview`（`cooking_prep_game_page.dart`）
- 改成每一輪都只展示「這一輪自己」`round/` 回應裡的 `new_item`（不是上一輪的），這個值保證不會出現在這一輪自己的 `option_items` 裡，純粹是為了讓玩家記住、留到下一輪才用得到；這一輪選項卡的正解是「上一輪」已經展示過的 `new_item`，不重複提示。
- 整場遊戲只有第 1 輪例外：依序展示 `seed_item`（start/ 給的）再展示第 1 輪自己的 `new_item`，之後每一輪都只展示 1 個物品。
- 拿掉 ver5 版本「比較這輪跟上一輪 stage 是否不同、換階段要展示兩個物品」的 `isStageOpening` 邏輯——後端證實不需要，鏈不會因為升階而中斷，換階段跟平常任何一輪一樣只展示 1 個物品。原本發現的「橋接輪」現象（升階後下一次 `round/` 的 `stage` 還停在舊階段）依然存在，但已經確認不影響展示個數，只是畫面主題切換會晚一輪的已知小瑕疵。
- 拿掉舊版「anchor 要驗證是否在這輪 optionItems 裡、對不上就整輪展示」的防呆分支——新邏輯下 `new_item` 本來就不該出現在自己這輪的選項裡，不需要這個檢查。

### 更新過時／錯誤的註解
- `memory_recall_model.dart`：`MemoryRecallRound.newItem` 的註解更新成正確語意（這一輪自己要新引入的物品，不是「下一輪會出現」的舊說法），並移除對已不存在的 `_advanceToNextRound` 方法的引用。
- `cooking_prep_asset_map.dart`：移除「進階階段干擾物永遠同組抽取、不會跨組」的錯誤假設（後端證實跨階段也會出現，實測也抓到 `鮮奶油`／`洋蔥` 這種其他階段字串混進 advanced 選項），補上提醒不要再假設同組。

### 新增 `docs/cooking_prep_frontend_spec.md`
- 玩法總覽、6 支 API 的實際 request/response 格式與已知欄位行為（`new_item`、橋接輪、`is_correct` 判定）、核心預覽邏輯、已修復的歷史 bug（供日後排查參考）、前端自訂的部分、目前已知未解決的問題（`is_correct` 判定反轉，已回報後端）。

### 驗證
- 用 Python 直打 API 驗證（不是用猜的）：`new_item` 對下一輪的預測在 100+ 輪測試中（含故意答錯穿插、含升階橋接輪）0 次錯輪；`is_correct` 判定目前仍是反的（已回報後端，前端刻意不做任何補償）。
- `flutter analyze` 全專案乾淨，只剩改動前就存在的既有 lint 提示。
- 真機實測（emulator）：前測 4 輪全部用新邏輯逐輪核對 debugPrint 輸出，展示內容與判定結果跟預期完全一致；結算流程（`finish/` → 結算對話框）在「正常破關」與「session 意外逾時」兩種情況下都正常顯示、沒有卡死或崩潰。

### 已知延後項目
- advanced 階段干擾物池的實際分佈規則（跨階段混入的機率、是否還有其他規律）還沒有長時間統計，只確認了「不保證同組」這個事實。
- 後端 `is_correct` 判定反轉的問題仍待後端修復，前端目前的行為是正確的（忠實呈現後端判定），不需要配合現況調整。

---

## 欣紜（冰箱清點：玩法教學／遊戲主畫面／結算頁／串接後端 API）— 2026/10/04

### 本次異動目標
- 新增「冰箱清點」遊戲（視覺空間領域），包含三種難度的玩法教學、遊戲主畫面、結算頁，並串接後端 `fridge-check` API。
- 六大認知領域中的「視覺空間」卡片接上冰箱清點，點擊後進入教學頁。
- 修正 Session ID 型別錯誤：後端回傳的 `session_id` 是 UUID 字串，原本前端用 `int` 解析導致變成 `0`，送答案時打到 `/sessions/0/answers/` 一直回 404 `SESSION_NOT_FOUND`。

### 新增檔案
- `lib/features/game/fridge_inventory/models/fridge_inventory_model.dart`：資料結構（`FridgeItem` 九宮格格子、`SourceFood` 困難模式待放入食材、`FridgeQuestion` 題目、`FridgeGameSession` 遊戲場次）。`sessionId` 為 `String`（UUID）
- `lib/features/game/fridge_inventory/services/fridge_inventory_service.dart`：串接後端 3 支 API
  - `POST /api/games/fridge-check/sessions/`：建立場次、取得第一題
  - `POST /api/games/fridge-check/sessions/{session_id}/answers/`：送出答案，body 為 `{"answer": {...}, "reaction_time_ms": ...}`（不傳 `question_id`）。easy 傳 `food_code`、medium 傳 `position`、hard 兩者都傳
  - `GET /api/games/fridge-check/history/`：歷史成績，相容 `history`／`data.history`／`result.history`／純陣列四種回傳格式
  - 回應解析會自動取出 `data` 或 `result` 內層，對應後端統一的 `{success, data, error}` 格式；有 token 時帶 `Authorization: Bearer token`
- `lib/features/game/fridge_inventory/pages/fridge_tutorial_page.dart`：玩法教學頁（6 頁，簡單／中等／困難各 2 頁）
  - 每頁先展示題目，下一頁用外框＋手指圖示標出正確答案
  - 切換到中等、困難難度時跳出 1.4 秒的難度提示彈窗
  - 右上「略過教學」可直接開始遊戲，最後一頁跳出「所有難度教學已完成」彈窗（開始遊戲／再看一次教學）
- `lib/features/game/fridge_inventory/pages/fridge_game_page.dart`：遊戲主畫面
  - 冰箱造型九宮格（冷藏室標頭、玻璃層板、最下排為蔬果保鮮抽屜），上方顯示難度標籤與題號進度條
  - 三種作答方式：easy 點食材、medium 點位置、hard 先點下方「待放入食材」再點目標格子
  - 答對：綠框＋打勾＋答對音效；答錯：橘框＋答錯音效，每題最多 3 次，次數用完自動進下一題
  - 難度、題號、剩餘次數以後端回傳為準（`difficulty`／`current_question`／`remaining_attempts`），後端沒給時才用本地值推算
  - 共用暫停選單 `lib/features/game/widgets/game_pause.dart`，App 切到背景時自動暫停
  - 連線失敗時顯示錯誤畫面與「重新連線」按鈕
- `lib/features/game/fridge_inventory/pages/fridge_result_page.dart`：結算頁（標題與遊戲頁、教學頁統一為「冰箱清點」）
  - 評語依分數分三級：90 分以上「非常棒！」（星星）、60～89「很好！」（打勾）、60 以下「沒關係，再加油！」（旗子，橘色）
  - 本次分數／最高分數（最高分取全部歷史紀錄最大值）
  - 最近五次成績折線圖（`CustomPainter` 自繪），本次成績固定放在最右邊
  - 歷史成績載入失敗時顯示「目前無法取得歷史成績」與「重新載入」按鈕，本次成績照常顯示
  - 「再玩一次」重新開局、「退出」返回上一頁
- `assets/images/game/fridge_inventory/`：9 種食材圖片（apple／banana／cabbage／carrot／egg／milk／pepper／tofu／tomato）＋教學用手指圖示 `finger.png`。檔名對應後端 `food_code`，畫面用 `$foodCode.png` 組路徑
  - 原本的 `red bell pepper.png` 已刪除，改為 `pepper.png`（檔名有空格容易在 Android 建置出問題，也要跟後端 `food_code: pepper` 對上）

### 修改檔案
- `lib/screens/game_home_screen.dart`：`DomainCard` 的 `onTap` 新增 `domain.id == 'visual_spatial'` 分支，導向 `FridgeTutorialPage`；其他領域導向不變
- `pubspec.yaml`：assets 新增 `assets/images/game/fridge_inventory/`（Flutter 的資料夾宣告不會自動包含子資料夾，必須另外宣告），並移除預設的英文註解
- `lib/features/game/go_to_market/services/audio_service.dart`（來去菜市場團隊的檔案）：
  - 移除 `PlayerMode.lowLatency` 與 `AudioContext` 設定，改用 audioplayers 預設值，原因是這段設定在 Android 模擬器上會造成音效播放異常
  - 修正錯誤訊息字串寫壞的問題（`'❌ 播放音效失敗 (\(fileName):\)e'` → `'❌ 播放音效失敗 ($fileName): $e'`）
- `lib/main.dart`：⚠️ 開機首頁暫時從 `IdentitySelectPage` 改成 `GameHomeScreen`，方便測試時直接進遊戲大廳（見下方「已知延後項目」）

### 目前狀態
- 已完成真實後端 API 串接測試，能建立場次、完整玩完 10 題（含答對／答錯／錯滿 3 次自動跳題）、送出成績並進入結算頁
- 結算頁的歷史成績 API 已接通，最高分數與最近五次折線圖皆正常顯示
- 已測試：Android 模擬器正常運作，九宮格與食材圖片、音效、暫停選單皆正常；尚未在 Chrome 測試
- Session ID 修正後，送答案的網址已改為 `/sessions/{UUID}/answers/`，不再出現 404 `SESSION_NOT_FOUND`

### 已知延後項目
- ⚠️ `lib/main.dart` 的開機首頁是測試用暫時改法，**會跳過登入流程**，沒有登入就不會有 token，需要驗證的 API（例如歷史成績）可能會失敗。正式推上 GitHub 前要改回 `IdentitySelectPage`
- 遊戲畫面的錯誤頁有三顆「測試成績頁（100／80／45 分）」按鈕（`isTestMode: true`，使用固定的假歷史資料 35→60→70→85），是後端沒開時測試結算頁用的，正式版要移除
- 退出導航尚未統一：遊戲頁與教學頁的暫停選單「退出遊戲」仍是 `popUntil(isFirst)`，結算頁「退出」是 `pop()`。蘇蘇 9/18 已把其他三款遊戲統一成 `pushAndRemoveUntil(GameHomeScreen)`，冰箱清點之後要跟著改
- 結算頁的折線圖是自己用 `CustomPainter` 畫的，還沒改用整理菜籃的共用元件 `ResultScoreCard`／`ResultHistoryChart`（fl_chart）
- 送答案失敗時只顯示「後端判題失敗 (404)」，還沒改用 `lib/core/network/api_response.dart` 的 `parseEnvelope`，所以看不到後端給的中文錯誤訊息（例如「查無此遊戲場次」）

### 給接手組員的提醒
- **後端的 `session_id` 是 UUID 字串，不是數字**，model、service、遊戲頁三個地方都要用 `String` 保存。如果用 `int.tryParse(...) ?? 0` 會靜默變成 0，畫面不會報錯，但每次送答案都會 404
- `fridge_inventory_service.dart` 的後端網址目前寫死為 `drawing-gap-jpeg-work.trycloudflare.com`，跟其他三款遊戲用的網址不同，也還沒改用 `ApiConstants`。`trycloudflare.com` 臨時網址會過期，網址換掉時這個檔案也要一起更新
- `audio_service.dart` 是來去菜市場的檔案，這次的修改會影響所有共用它的遊戲（來去菜市場、冰箱清點、六大領域首頁點擊音效）。如果來去菜市場那邊發現音效延遲變明顯，可能跟移除 `lowLatency` 有關
- 冰箱清點的圖片路徑使用完整的 `assets/images/game/fridge_inventory/xxx.png` 寫法，已在 Android 模擬器確認可以正常顯示
- 新增食材時，圖片檔名必須跟後端的 `food_code` 完全一致（全小寫、不要有空格），找不到圖片時會顯示預設的餐具圖示
- 每次從首頁進入都會先顯示教學頁，目前沒有「只有第一次顯示」的判斷

---

## Wen（整理菜籃：豬肉圖改為豬排／移除去背工具資料夾）— 2026/10/04

### 修改檔案
- `assets/images/game/market_sort/pork.png`：原圖看起來像層狀五花肉，容易跟培根混淆，改畫成帶骨豬排
- `.gitignore`：移除 `_raw_market_sort/`（去背原圖與 `prepare_images.py` 已移出專案，之後去背在專案外處理）

### 已知延後項目
- 牛肉圖偏褐色（顏色題答案是紅），之後可能重畫

## Wen（聲影日記：比賽版畫面比對／主色改深綠／錄音區提示文字／完成頁分享按鈕）— 2026/09/30

### 本次異動目標
- 在本機架起比賽版聲影日記（futureQ，Django），跟專題版 Flutter 逐頁比對首頁、月曆、動態回顧、上傳照片、錄音流程、等待頁、完成頁、分享頁共 8 組畫面，整理出差異清單並依優先度修正。
- 優先處理影響長輩使用的部分：顏色對比不足、缺少操作說明、最新訊息被遮擋。

### 修改檔案
- `lib/theme/app_theme.dart`：`primaryColor` 從 `0xFF5B9E87` 改為比賽版的深綠 `0xFF36684C`，白字對比度從約 3:1 提高到約 6:1（無障礙標準為 4.5:1）；`ColorScheme.fromSeed` 額外指定 `primary: primaryColor`，確保透過主題取色的 Material 元件跟 `primaryColor` 完全一致
- `lib/features/diary/widgets/record_button.dart`：
  - 新增 `isFirstRound` 參數
  - 按鈕下方新增依狀態變化的提示文字（新增 `_hintForState()`）：待機時第一輪顯示「請盡量詳細描述照片裡的人、地點、發生的事（至少講 15 秒喔）。點擊開始錄音」，之後顯示「點擊開始錄音」；錄音中「點擊暫停，或按完成送出」；暫停時「點擊繼續錄音，或按完成送出」；送出中「語音辨識與思考中…」
  - 計時器改用 `Text.rich` 顯示為 `00:48 / 03:00`，上限時間用較小的字，避免大字級時過寬
  - `ListenableBuilder` 改為同時監聽字級、深色模式、高對比，提示文字顏色跟著設定切換
- `lib/features/diary/pages/diary_chat_page.dart`：
  - 逐字稿先 `trim()`，`null` 或空字串都顯示「（沒有聽清楚）」（後端沒聽到聲音時回傳的是空字串，原本的 `?? '（沒有聽清楚）'` 判斷不到，會出現只有播放鍵的空白氣泡）
  - `RecordButton` 傳入 `isFirstRound: _roundIndex == 1`
  - `onStateChanged` 裡多呼叫一次 `_scrollToBottom()`：原本捲到底之後，下方才冒出「這題跳過」「生成日記」按鈕，對話區變矮，導致最新的 AI 問題被錄音區擋住
- `lib/features/diary/pages/diary_loading_page.dart`：文字「語言認知計算中請稍後」改為「正在整理您的日記，請稍候」（修正「稍後」錯字，並避免長輩覺得自己在被測驗）；外層加 `Flexible`，大字級時自動換行不溢出
- `lib/features/diary/pages/diary_finish_page.dart`：
  - 分享卡片外層包 `RepaintBoundary`，供「儲存圖片」轉成 PNG
  - 原本單一的「分享日記」按鈕（系統分享選單）改為比賽版的 2 × 2 按鈕：LINE 分享、Facebook、儲存圖片、複製連結，上方加「分享這則日記」標題
  - LINE 分享使用官方分享網址 `https://line.me/R/share?text=...`，透過 `url_launcher` 開啟
  - Facebook、複製連結會判斷 `diary.shareUrl`：目前後端沒有回傳，按下時顯示「分享連結準備中，之後就能使用」；後端開始回傳 `share_url` 後自動生效，不用再改程式
  - 組分享文字的邏輯從 `_onShareTap()` 抽成 `_buildShareText()`
  - 外框按鈕在深色模式改用 `0xFF4CAF50`，避免深綠在深色背景上太暗

### 目前狀態
- 已在 Chrome 手動測試：錄音各狀態提示文字、計時器上限顯示、第一輪 15 秒門檻、空白逐字稿提示、最新訊息不被遮擋、等待頁文字、完成頁四顆分享按鈕（LINE 開啟分享頁、Facebook／複製連結顯示提示、儲存圖片下載 PNG）
- 繁體字檢查通過：AI 提問、Whisper 逐字稿、生成的日記標題與內文、標籤皆為繁體

### 已知延後項目
- 首頁月曆：點擊月份標題彈出年月快速選擇框（比賽版為 4 × 3 月份按鈕）
- 首頁月曆：尚未用有日記的帳號確認日期格子是否顯示照片標記
- 動態回顧：比賽版為獨立頁面（昨天／去年的今天分頁、日記卡片含照片與逐字稿、點擊彈出詳細內容與播放語音、空狀態），排入下一輪；需先確認後端 D-2 回傳單篇或列表，以及是否有逐字稿欄位（目前 `DiaryReviewItem` 為單篇且只有 `postText`）
- 儲存圖片目前只在網頁上測試（Chrome 會直接下載），手機上存進相簿需另外處理
- Facebook、複製連結待後端提供 `share_url`
- 低優先度視覺細節：首頁卡片高度與圖示（比賽版用 `history_edu`）、上傳照片外框、錄音完成鈕下方「完成」文字、暫停時「重新錄製」造成版面跳動、第 2 輪後縮小照片高度
- 尚未全面確認是否有檔案直接寫死舊主色 `0xFF5B9E87`（沒有透過 `AppTheme.primaryColor`）

### 給接手組員的提醒
- `AppTheme.primaryColor` 被全專案約 26 個檔案使用（包含遊戲頁面），這次改色會連帶讓遊戲頁面變深，是否全 App 統一待組內確認；整理菜籃的暫時測試色 `_testPrimaryColor`（`0xFF2E5940`）若決定統一，可一併改用 `AppTheme.primaryColor`
- 改了 `const` 常數（例如主色）之後，hot reload 不一定會更新，要用大寫 `R` 做 hot restart
- 聊天頁的下方區塊會依錄音狀態增減按鈕，之後在錄音區新增任何元件，都要確認最新訊息仍會被捲到可見範圍
- 比賽版 futureQ 在本機執行需要 Python 3.10 以上、`requirements.txt`（含 Whisper，安裝時間較長）、ffmpeg（加入 PATH），以及 `.env` 的 OpenAI 金鑰；只看畫面的話可以不填金鑰，直接用網址進各頁（例如 `/finish/?diary_id=167`）

---

## Wen（整理菜籃：配合後端計分修正／商品改用去背圖片；底部導覽列與首頁卡片套用字體縮放、深色模式、高對比）— 2026/09/30

### 本次異動目標
- 9/23 會議發現整理菜籃計分異常（實測答對 27/28 得 79 分、答對 4/28 得 77 分），分析後由後端筠淇在 `feat/game/market-sort-scoring-fix` 分支做「短期、不改玩法」的計分修正，前端配合調整送出的資料與錯誤處理。
- 整理菜籃 28 項商品從 emoji 換成去背 PNG 圖片。
- 底部導覽列、首頁卡片接上設定頁的字體縮放、深色模式、高對比。

### 計分問題原因（前端這邊需要知道的部分）
- 主因：現在的玩法籃子會跟著規則換，前端 `market_sort_answer_judge.dart` 永遠判不出 `persistent` 錯誤，`persistent_error_rate` 恆為 0，每個人固定多拿約 21 分。後端這次先把這項指標拿掉，改用整體正確率。
- 其他原因（常模假資料太寬、z 分數沒有上下限、repeat 題答錯不扣分）都在後端處理，完整分析見文件「整理菜籃計分問題與修改建議」。
- 修正後實測：幾乎全對與幾乎全錯的分數已有明顯落差。

### 新增檔案
- `assets/images/game/market_sort/*.png`：28 張商品圖（512×512 去背 PNG，每張約 50–140 KB），檔名與商品對照見 `market_sort_item_pool.dart` 的 `imageAsset` 欄位

### 修改檔案
- `lib/features/game/market_sort/controllers/market_sort_game_controller.dart`：新增 `recordedTrialType`，第 1 題（沒有上一題）送給後端時記成 `repeat`；原本的 `isRepeatTrial` 不動，只用來決定鎖定時間，所以第 1 題仍維持 1 秒
- `test/features/game/market_sort/controllers/market_sort_game_controller_test.dart`：新增「第1題記錄成repeat，但鎖定時間仍維持1秒」測試（共 9 個測試全數通過）
- `lib/screens/market_sort_game_screen.dart`：`_submitAndShowResult()` 送出失敗時改顯示「成績送出失敗，請確認網路後再試一次」＋「重試」按鈕，原始錯誤只 `debugPrint` 到終端機；開頭加上 `_isSubmitting` 防呆，避免連按重試重複送出（後端對同一 `session_id` 有冪等處理）
- `lib/features/game/market_sort/models/market_sort_item_pool.dart`：28 項商品全部補上 `imageAsset`，emoji 保留當作備援
- `lib/core/assets/item_visual_resolver.dart`：`Image.asset` 加上 `errorBuilder`，圖片路徑錯誤或檔案漏放時退回顯示 emoji；emoji 備援縮為圖片尺寸的 55%，避免撐出圓形卡片
- `lib/features/game/market_sort/widgets/product_card.dart`：商品卡放大（遊戲畫面圓形 180／圖片 140；教學彈窗 compact 版圓形 95／圖片 74）
- `lib/screens/main_screen.dart`：底部導覽列用 `ListenableBuilder` 監聽三個設定；深色配色與 `TopBar` 一致（底色 `0xFF1E1E1E`、選中綠色 `0xFF4CAF50`、未選中 `0xFFCCCCCC`）；高對比時未選中項目改純黑／純白；文字改用 `AppSettings.scaleFont(12)`，系統字體縮放上限從 1.25 降到 1.0 避免雙重放大，並用 `FittedBox` 確保最大字級時「聲影日記」不被截斷；`withOpacity` 改為 `withValues(alpha:)`
- `lib/features/home/widgets/daily_suggestion_card.dart`、`lib/features/home/widgets/game_card.dart`：兩張卡片各自加上 `ListenableBuilder`；深色模式沿用聲影日記的深綠底容器配色（底色 `0xFF25382E`、文字 `0xFFB8E6D0`）；字體改用 `AppSettings.scaleFont()`；高對比時文字純黑／純白加粗並加 2px 外框
- 5 支 service（`auth_service.dart`、`diary_service.dart`、`go_to_market_service.dart`、`market_shopping_service.dart`、`market_sort_api_service.dart`）：後端 trycloudflare 測試網址更新
- `pubspec.yaml`：assets 新增 `assets/images/game/market_sort/`
- `.gitignore`：新增 `_raw_market_sort/`（本機去背用的原圖資料夾，不進版控）

### 目前狀態
- `flutter test test/features/game/market_sort/` 9 個測試全數通過；本次修改的檔案 `flutter analyze` 皆無問題
- 已手動測試：整理菜籃完整一局（圖片顯示、教學彈窗、送出成績）；設定頁切換字體大小／深色模式／高對比後，底部導覽列與首頁卡片即時更新

### 已知延後項目
- 後端計分修正還在 `feat/game/market-sort-scoring-fix` 分支，待合併後正式環境才會套用新公式
- 整理菜籃、市場買菜、來去菜市場三款遊戲的畫面尚未套用字體縮放／深色模式
- 豬肉的圖目前看起來像培根、牛肉偏褐色（顏色題答案是紅），之後可能重畫
- 整理菜籃的籃子圖案還是 emoji
- 長期是否改成「固定兩籃」玩法待組內決定；`market_sort_answer_judge.dart` 的 persistent 判斷先保留，改玩法後可以直接沿用
- `market_sort_api_service.dart` 的網址仍是寫死的 trycloudflare 網址

### 給接手組員的提醒
- 新增 asset 圖片後 hot reload／hot restart 都讀不到，要重新 `flutter run`；`pubspec.yaml` 裡 `assets/images/` 不包含子資料夾，新資料夾要另外宣告
- 教學彈窗高度固定，`ProductCard` 的 compact 圓形超過約 100 就會出現 BOTTOM OVERFLOWED
- 其他頁面要套用設定，可以比照這次的做法：`ListenableBuilder` 監聽 `AppSettings.fontSizeLevel`／`isDarkMode`／`isHighContrast`，文字用 `AppSettings.scaleFont()`，深色配色沿用 `0xFF121212`（頁面底）／`0xFF1E1E1E`（卡片、列）／`0xFF4CAF50`（綠色）／`0xFF25382E`（淺綠容器）
- `pubspec.lock` 切分支時常被自動改動，commit 時不要用 `git add .`，明確列出檔案

---
## Wen（聲影日記：串接真實後端 API／新增登入狀態檢查／修正 CORS 與錄音格式問題）— 2026/09/23

### 本次異動目標
- 把聲影日記核心流程（上傳照片→AI 問答→生成日記→完成分享）從假資料全面換成呼叫後端真實 API（D-1／D-3／D-5／D-7），D-2／D-4／D-6 待後端補齊前維持假資料。
- 新增 App 啟動時的登入狀態檢查，避免未登入直接看到主畫面。
- 排除串接過程中遇到的一連串環境問題：CORS、音訊上傳格式、後端回應欄位缺漏。

### 新增檔案
- `lib/features/auth/pages/auth_gate.dart`：App 啟動時的登入狀態檢查，有 token 就直接進主畫面，沒有就導去身分選擇頁
- `lib/features/diary/pages/diary_loading_page.dart`：生成日記時的等待畫面（旋轉齒輪動畫），呼叫 D-7 `finalizeDiary`
- `lib/features/diary/pages/diary_finish_page.dart`：完成頁（分享卡片預覽、朗讀貼文、分享日記），使用 `flutter_tts`、`share_plus`

### 修改檔案
- `lib/main.dart`：`home` 從固定的 `MainScreen` 改成 `AuthGate`；`voiceDiaryChat` 路由改成傳遞完整 `DiaryModel` 而非單純 `diaryId`；新增 `voiceDiaryLoading`／`voiceDiaryFinish` 路由
- `lib/features/diary/services/diary_service.dart`：D-1／D-3／D-5／D-7 改接真實後端；新增統一的 `_unwrap()` 解析 `{"data":...}`／`{"error":...}`／DRF 的 `{"detail":...}` 三種回應格式；`_fillMissingDiaryFields()` 補上以 `created_at` 推算 `date` 的容錯（部分後端回應目前沒有 `date` 欄位）；`submitReply()` 明確指定音訊 `contentType` 為 `audio/webm`，避免後端收不到有效檔案
- `lib/features/diary/pages/diary_chat_page.dart`：建構子從 `required diaryId`（int）改成 `required initialDiary`（`DiaryModel`），不再呼叫尚未提供的 D-4，直接用建立日記時（D-3）回傳的資料進聊天室
- `lib/features/diary/pages/diary_upload_page.dart`：導航到聊天室時改傳完整 `DiaryModel`（原本只傳 `diaryId`）
- `lib/features/diary/pages/diary_home_page.dart`：`_loadMonth()` 補上 `try/catch`，讀取失敗時顯示「讀取失敗，請檢查登入狀態後再試一次」＋重新載入按鈕，取代原本失敗時卡死在轉圈圈的問題
- `lib/features/diary/widgets/record_button.dart`：錄音編碼改用 `AudioEncoder.opus`（Chrome 的 `MediaRecorder` 不支援預設的 AAC）；`_completeRecording()` 包裝錄音結果時明確指定 `XFile` 的 `name`／`mimeType`（Web 上 `stop()` 回傳的是沒有副檔名的 blob 網址，不指定會讓後端判斷不出這是音訊檔）
- `lib/features/auth/services/auth_service.dart`：登入／註冊網址更新為後端目前的 Cloudflare Tunnel 網址
- `pubspec.yaml`：新增 `flutter_tts`、`share_plus`、`http_parser`

### 排除的環境問題
- CORS：後端 Django 需要 `django-cors-headers` 開放 Flutter Web 的來源；圖片所在的 Google Cloud Storage bucket 是另一個獨立的 CORS 設定，要另外用 `gsutil cors set` 開放跨網域讀取，兩者要分開設定
- 建立日記（D-3）回應目前只有 `created_at` 沒有 `date` 欄位，`DiaryModel.fromJson` 對 `date` 的強制轉型會直接噴例外，前端改用 `created_at` 推算補上
- 錄音送出（D-5）400 錯誤：Web 上 `XFile` 包 blob 網址沒有副檔名／Content-Type，後端判斷不出音訊格式而拒收，改為明確指定 `name`／`mimeType` 與 `contentType`

### 目前狀態
- 已完成真人手動測試：登入→聲影日記首頁→上傳照片→AI 問答（含第一輪 15 秒門檻）→生成日記→完成頁，全流程跑通
- 測試時發現：錄音若沒有實際講話內容，Whisper 轉譯出空字串，後端會判斷「沒有有效回覆」拒絕生成日記（`NO_VALID_REPLY`），這是後端合理的驗證邏輯，不是前端 bug，測試時需要真的對著麥克風講話

### 已知延後項目
- D-2（動態回顧）、D-4（單篇日記詳情）、D-6（跳過本輪）後端尚未提供，畫面上這幾個功能目前還是假資料
- `finalize` 回應目前沒有 `share_url`，完成頁的分享功能暫時用標題＋內文組字串，之後後端補上再串正式分享連結
- `auth_service.dart`、`diary_service.dart` 的後端網址都還是暫時寫死的 trycloudflare 網址，重開發環境就會換，之後待後端提供正式固定網域再統一改用 `ApiConstants`

### 給接手組員的提醒
- trycloudflare 這類臨時通道網址一換，需要同步更新的檔案是 `auth_service.dart` 和 `diary_service.dart` 兩支
- 之後如果還有新的 multipart 上傳（例如未來要傳影片），記得比照 `record_button.dart` 的做法，明確指定 `XFile` 的 `name`／`mimeType`，不要依賴 Web 端 blob 網址自動推斷
- `diary_service.dart` 的 `_unwrap()`／`_fillMissingDiaryFields()` 是這次串接統一收斂的解析邏輯，之後 D-2／D-4／D-6 換成真實 API 時直接沿用這兩個方法即可

---

## 蘇蘇（合併 goto-market／三款遊戲風格統一／歷史成績 API／後端錯誤格式統一解析）— 2026/09/18

### 本次異動目標
- 把 `goto-market` 分支（來去菜市場：注意力訓練）正式合併進來，讓六大認知領域裡「數學」「執行功能」「注意力」三個領域都能實際進入對應的小遊戲。
- 三款遊戲（市場買菜／整理菜籃／來去菜市場）的暫停選單、結算頁樣式、退出遊戲導航統一。
- 市場買菜補上歷史成績查詢 API。
- 因應後端把三款遊戲的錯誤回應統一成 `{success, data, error:{code, message}}` 格式，前端加上共用解析邏輯。

### 合併 goto-market 分支
- 解決 `lib/main.dart`、`lib/screens/game_home_screen.dart`、`pubspec.yaml`、`pubspec.lock` 的合併衝突，兩邊功能都保留（登入流程、通知鈴鐺、六大領域卡片點擊音效都沒有掉）
- `lib/screens/game_home_screen.dart`：六大領域卡片新增 `domain.id == 'attention'` 分支，導向 `GoToMarketTutorialPage`；「數學」「執行功能」維持原本導向市場買菜／整理菜籃，其餘領域仍是「敬請期待」提示
- `pubspec.yaml`：套件版本取兩邊較新的（`http ^1.6.0`、`audioplayers ^6.8.1`、`shared_preferences ^2.5.5`），assets 補齊 `assets/images/game/market_shopping/`（goto-market 帶進來的魚圖片放在 `assets/images/` 下已涵蓋，不用另外宣告）

### 後端網址更新（4 個檔案）
- `lib/features/auth/services/auth_service.dart`、`lib/features/game/market_shopping/services/market_shopping_service.dart`、`lib/features/game/market_sort/services/market_sort_api_service.dart`、`lib/features/game/go_to_market/services/go_to_market_service.dart`
- 全部改成後端最新的 Cloudflare Tunnel 網址 `stopped-residential-proposal-clients.trycloudflare.com`（go_to_market_service.dart 原本指向的是另一個已經失效的舊網址，這次一併修正）

### 暫停選單樣式統一
- 市場買菜的暫停選單改用共用元件 `lib/features/game/widgets/game_pause.dart`（goto-market 團隊做的正式版，橫向/直向自動排版），刪除原本標記「暫時版」的 `lib/features/game/market_shopping/widgets/game_pause.dart`
- 呼叫端（`market_shopping_memorize_page.dart`／`checkout_page.dart`／`play_page.dart`）呼叫方式完全沒變（`onResume`／`onTutorial`／`onRestart`／`onExit` 參數一致），只改 import

### 結算頁樣式統一 + 退出導航統一
- `lib/features/game/market_shopping/pages/market_shopping_result_page.dart` 改用整理菜籃的 `ResultScoreCard`／`ResultHistoryChart`（fl_chart 折線圖），取代原本自己刻的 `_SimpleLineChartPainter`
- `lib/features/game/market_sort/widgets/result_score_card.dart` 新增 `currentLabel`／`bestLabel`／`unit` 三個可選參數（預設值跟原本一樣是「本次分數」／「最高分數」／「分」），市場買菜傳入「本次正確率」／「最高正確率」／「%」
- 三款遊戲結算頁的「退出遊戲」按鈕統一改成 `Navigator.pushAndRemoveUntil(GameHomeScreen)`，直接清空 route stack 回到六大領域遊戲首頁，不再是 `popUntil(isFirst)`（會跑回登入頁）或單純 `pop()`（來去菜市場原本是跳回上一頁教學頁）

### 市場買菜新增歷史成績 API
- `lib/features/game/market_shopping/models/market_shopping_models.dart` 新增 `HistoryRecord`（score／accuracy／playedAt）與 `HistoryResult`
- `lib/features/game/market_shopping/services/market_shopping_service.dart` 新增 `getHistory()`，帶 `Authorization: Bearer token`
- `market_shopping_result_page.dart` 改成 `StatefulWidget`，進頁面時打 `getHistory()`：讀取中顯示 loading、失敗顯示「無法載入歷史成績」但本次成績正常顯示、取最近 5 筆畫折線圖、最高正確率取全部歷史紀錄的最大值（records 是空的就顯示本次成績）

### 後端錯誤格式統一解析
- 新增 `lib/core/network/api_response.dart`：`ApiException(statusCode, code, message, details)` + `parseEnvelope`／`parseData` 兩個解析函式，對應後端統一後的 `{success, data, error:{code, message}}` 格式，也相容 `market_route` 改版前的純字串 `error` 跟未登入時 DRF 預設的 `{"detail": "..."}`
- 市場買菜、整理菜籃的 service 全部改用 `parseEnvelope` 解析，失敗時丟出 `ApiException`，畫面上 `catch (e) { ... e.toString()... }` 的顯示邏輯不用改，玩家會看到後端給的中文訊息（例如「查無此遊戲局次」）而不是整包原始 JSON
- 來去菜市場的 5 支 API 內部改用 `parseData`，但刻意保留原本「內部 catch 掉、回傳 null、呼叫端 fallback 成本地生成題目／本地計分」的離線優先設計不變，只是 debugPrint 現在會印出後端真正的錯誤代碼跟訊息

### 目前狀態
- 已用 `flutter analyze` 確認全專案 0 error，只剩合併前就存在的既有 lint 提示（65 項，數量沒有變化）
- 已用 curl 直接打過新網址確認 4 支網址都能連上，也確認過後端新的 `SESSION_NOT_FOUND` 錯誤格式（HTTP 404，`{"success":false,"data":null,"error":{"code":"SESSION_NOT_FOUND","message":"..."}}`）能被前端正確解析

### 已知延後項目
- 後端錯誤代碼文件裡 `market_route` 的第 4 支端點 `result`（會回傳 `SESSION_NOT_FOUND`／`SESSION_NOT_FINISHED`）前端目前沒有對應的呼叫方法，之後要接再補
- 目前只是把 `error.code`／`error.message` 結構化解析出來、訊息顯示更準確，沒有針對特定 code 做導頁或其他分支邏輯（例如 `SESSION_NOT_FOUND` 時自動導回首頁），之後有需要再加
- `market_shopping_service.dart` 的 `startGame`／`submitItemAnswer`／`submitChangeAnswer` 目前沒有帶 `Authorization` token（跟 `getHistory()` 不一樣），如果後端這三支也要求登入驗證，要再補上

### 給接手組員的提醒
- 三款遊戲的 service 現在都共用 `lib/core/network/api_response.dart`，之後後端錯誤格式再變動，原則上只需要改這一個檔案，不用三個 service 分別改
- `change.md` 裡蘇蘇之前寫的「`trycloudflare.com`類臨時通道網址會過期或換掉」這則提醒依然有效（這次就是因為網址換了才觸發這輪更新），下次網址再換，需要更新的檔案是上面列的那 4 個

---

## 蘇蘇（市場買菜：完整遊戲流程／串接後端 API／教學彈窗／暫停選單）— 2026/09/16

### 新增檔案
- `lib/features/game/market_shopping/models/market_shopping_models.dart`：資料結構（MarketFood、PurchasedItem、ShoppingQuestion、GameSession、ItemAnswerResult、ChangeAnswerResult）
- `lib/features/game/market_shopping/pages/market_shopping_game_page.dart`：主控制器，管理遊戲階段（loading／memorize／play／checkout／error）與三支 API 的呼叫時機
- `lib/features/game/market_shopping/pages/market_shopping_memorize_page.dart`：記憶購物清單畫面（平滑倒數進度條、「我記住了！」可跳過倒數）
- `lib/features/game/market_shopping/pages/market_shopping_play_page.dart`：選菜畫面（點擊選取、確認後顯示對錯、菜籃預覽）
- `lib/features/game/market_shopping/pages/market_shopping_checkout_page.dart`：結帳找零畫面（easy/medium 顯示總花費、hard 顯示明細自行加總）
- `lib/features/game/market_shopping/pages/market_shopping_result_page.dart`：結算頁（本次/最高正確率、歷史成績折線圖）
- `lib/features/game/market_shopping/widgets/game_in_progress_top_bar.dart`：遊戲進行中頂部列（暫停／標題／通知）
- `lib/features/game/market_shopping/widgets/game_pause.dart`：暫停選單（暫時版，見下方待處理）
- `lib/features/game/market_shopping/widgets/market_shopping_tutorial_dialog.dart`：玩法教學彈窗（4頁，含真實截圖）
- `lib/features/game/market_shopping/services/market_shopping_service.dart`：呼叫後端3支 API
- `lib/features/game/market_shopping/services/sound_player.dart`：音效播放（一般點擊／答對／答錯）
- `lib/features/game/market_shopping/services/tutorial_preference.dart`：教學是否看過的記錄（目前未使用，見下方）
- `assets/images/game/market_shopping/`：8種食材圖片（tomato/egg/tofu/cabbage/pork/cucumber/onion/spinach）＋3張教學截圖

### 修改檔案
- `lib/screens/game_home_screen.dart`：`DomainCard` 的 `onTap` 加上 `domain.id == 'math'` 判斷，跳轉到 `MarketShoppingGamePage`

### 目前狀態
- 核心流程已完整串接真實後端 API，可連續破關跑完整場 10 題（開始遊戲→記憶清單→選菜→結帳找零→結算頁）
- 已測試：Android 模擬器與 Chrome 皆正常運作，含答對／答錯／錯滿3次跳題／整場結束等分支情況

### 待後端補的 API
- 已提需求：`GET /api/games/market-shopping/history/`（查詢歷史成績），用於結算頁的歷史折線圖與最高正確率。**這支 API 做出來之前，結算頁的歷史成績只會顯示「本次」一個點，最高正確率也只是本次分數，不是真正歷史最高**，這是已知功能缺口不是 bug

### 給接手組員的提醒
- `game_pause.dart` 是暫時版本，因為原本說好共用的正式暫停選單一直沒等到，介面（`show()` 的四個參數 `onResume`／`onTutorial`／`onRestart`／`onExit`）已對齊組員說好的呼叫方式，之後拿到正式版可直接整份取代，不用改任何呼叫端
- `tutorial_preference.dart` 目前是孤兒程式碼沒被呼叫，原設計是「只有第一次玩才顯示教學」，後來邏輯改成「每次開局都顯示」（`market_shopping_game_page.dart` 的 `_startGame()` 直接顯示，沒檢查 `hasSeenTutorial()`），如果之後想改回只顯示一次，邏輯都還在，加回判斷即可
- 圖片路徑寫法：`Image.asset('images/game/market_shopping/xxx.png')`，**不要**加 `assets/` 前綴（`pubspec.yaml` 用 `assets/images/` 宣告資料夾後會自動處理，多加會導致雙重路徑 404，Chrome 可能正常但 Android 建置會出問題）
- 後端數字欄位可能是 double 不是 int（例如 accuracy），`market_shopping_models.dart` 檔案最下面有共用轉型函式 `_toInt` / `_toIntOrNull`，之後新增欄位記得套用同樣寫法避免 `type 'double' is not a subtype of type 'int?'` 錯誤
- 錯誤次數是選菜＋找零共用一個計數器（規格書明定），`ItemAnswerResult` 一定要有 `isCompleted` 欄位，否則玩家可能卡在已結束的 session 還被要求作答，導致 `SESSION_COMPLETED` 錯誤
- 選菜卡片視覺是「整片變色」簡化設計（未選＝木盒棕、選中＝深綠、答對＝綠、答錯＝橘），如果要統一六大類別遊戲風格可以參考這個配色邏輯
- Android 模擬器圖片顯示不出來但 Chrome 正常時，先懷疑 Gradle 快取（`C:\Users\<帳號>\.gradle\caches`）卡住舊版本，`flutter clean` 未必清得掉，需要手動刪除該資料夾後重新建置（會需要 5-8 分鐘重建快取，屬正常現象）

## Wen（整理菜籃：靜態元件／拖曳互動／隨機規則／API串接）— 2026/09/16

### 新增檔案
- `lib/features/game/market_sort/widgets/`：`market_sort_top_bar.dart`、`game_progress_header.dart`、`rule_badge.dart`、`basket_row.dart`、`product_card.dart`、`countdown_digit.dart`、`tutorial_modal.dart`（兩頁式玩法教學，含PageView切換與商品移動動畫）、`pause_modal.dart`（暫停選單，退出二次確認尚未做）
- `lib/features/game/market_sort/controllers/market_sort_game_controller.dart`：單題狀態機（locked/interactive/resolved）、計時、判定邏輯，含測試 `market_sort_game_controller_test.dart`（8項全過）
- `lib/features/game/market_sort/services/market_sort_answer_judge.dart`：答題判定演算法（persistent/random錯誤類型）
- `lib/features/game/market_sort/services/market_sort_api_service.dart`：串接後端 `POST /api/games/market-sort/submit/`
- `lib/features/game/market_sort/models/market_sort_stage_plan.dart`：新增 `buildMarketSort28QuestionPlan()`，第四階段（隨機混合）改為真正隨機生成，每2~3題一組同規則、組間規則不重複，取代原本寫死的固定序列
- `lib/core/services/token_storage.dart`：JWT token 存取（`SharedPreferences`）
- `lib/screens/market_sort_game_screen.dart`：整合畫面，串接controller狀態機、`Draggable`/`DragTarget`拖曳判定、動態依規則產生籃子（種類/顏色各3籃、生熟2籃留白維持版位）、音效、5秒逾時提示、暫停/教學彈窗
- `lib/screens/market_sort_result_screen.dart`：結算頁，串接API回傳的分數與歷史成績

### 修改檔案
- `lib/features/game/market_sort/widgets/basket_row.dart`：擴充支援 `DragTarget`、答對/答錯閃光、`compact`模式維持零padding避免教學彈窗溢出
- `lib/features/game/market_sort/widgets/result_score_card.dart`：等級圖示/文字依分數動態變色（綠/橘）
- `lib/features/game/market_sort/widgets/result_history_chart.dart`：加入`fl_chart`折線圖，資料介面對齊API的`recent_scores[]`/`current_score`
- `lib/features/auth/pages/login_page.dart`：補上登入成功後存取JWT token的邏輯（原本完全沒有存）
- `lib/features/home/widgets/game_card.dart`：「菜市場」卡片導向 `GameHomeScreen`
- `lib/screens/game_home_screen.dart`：「執行功能」領域卡片導向整理菜籃（其餘五個領域維持TODO）
- `lib/main.dart`：註冊 `AppRoutes.gameMarketSort` 命名路由
- `pubspec.yaml`：新增 `fl_chart`、`shared_preferences`、`uuid`

### 目前狀態
- 已完成真實API串接測試（後端：筠淇），能登入、玩完28題、送出成績、顯示結算頁與歷史成績折線圖
- 已測試：完整流程（登入→首頁→執行功能→整理菜籃→結算頁）在Chrome跑通，拖曳判定、規則切換音效、5秒逾時提示、暫停/教學彈窗皆正常

### ⚠️ 待後端確認的計分異常（已回報筠淇，附逐題測試資料）
- 兩次真實測試：28題27對1錯→79分；28題4對24錯（正確率14.3%）→77分。正確率差距極大，分數卻幾乎一樣，不符合設計文件Step5「z=-2→10分下限」的預期
- `encouragement_tier` 在分數退步（87→77）時仍回傳`good`，疑似沒有正確依「本次分數－最高分數」判斷
- 懷疑常模假資料設定過寬鬆，或加權公式/z分數計算有誤，需筠淇檢查後端邏輯

### 已知延後項目
- `pause_modal.dart` 退出遊戲二次確認彈窗
- `tutorial_modal.dart` 商品移動到籃子的動畫（此項實際上已完成，見上方新增檔案說明）
- `_testPrimaryColor`（`0xFF2E5940`）暫時測試色，散落在 `pause_modal.dart`、`result_score_card.dart`、`result_history_chart.dart` 三個檔案，待組員提供正式色碼後統一替換
- 暫停時 `Stopwatch` 未真正凍結（用重新倒數緩解，非精確解法）
- 首次進入自動教學（`has_seen_market_sort_tutorial`）尚未接local storage判斷
- 中途退出（`is_complete: false`）尚未送出API，待與筠淇對齊該情境的後端行為
- 一般按鈕點擊音效尚未全面接上（僅答對/答錯/規則切換三種）

### 給接手組員的提醒
- `game_card.dart`／`game_home_screen.dart` 目前的導航是MVP暫時接法，「菜市場」卡片直接連到遊戲首頁、「執行功能」直接連到整理菜籃，之後若六大領域有各自對應的正式遊戲，這裡要重新設計
- API串接遇到401時要先分辨是`"Token is invalid"`還是`"Token is expired"`，兩者原因不同（前者可能是假token或格式錯，後者是token過期需重新登入）
- `trycloudflare.com`類臨時通道網址會過期或換掉，`auth_service.dart`與`market_sort_api_service.dart`裡目前都是暫時寫死網址，待後端提供正式固定網域後要一併更新並改用`ApiConstants`
## 欣紜（Go to Market 遊戲頁面：題號字串修復與介面簡化）— 2026/09/17

### 本次異動目標
- 修復 `go_to_market_game_page.dart` 頂部題號的字串插值問題，解決終端機／命令列在編譯時因解析 `$` 符號導致的字面亂碼。
- 簡化遊戲頂部導航列介面，移除右上角的「快升」進度狀態標籤，使畫面維持清爽。

### 新增與變更檔案
- `lib/features/game/go_to_market/pages/go_to_market_game_page.dart`：
  - 將頂部題號顯示改為 `.toString()` 字串串接：`currentQuestionNumber.toString() + ' / ' + totalQuestions.toString()`。
  - 移除頂部導航列中負責渲染「快升」標籤的 `Container` 區塊。

### 目前狀態
- 已經過本地模擬器測試，題號能正確呈現（如 `1 / 20`），右上角快升標籤已順利移除。
- 已完成專案暫存清理與相依套件重建（`flutter clean` / `flutter pub get`），執行穩定正常。

### 給接手組員的提醒
- 若未來在 Dart 程式碼中遇到終端機因轉譯產生變數顯示異常時，可直接優先採用 `.toString()` 進行字串串接以確保編譯一致性。

## Wen（新手教學：引導頁／首頁教練標記／教學狀態判斷）— 2026/09/02

### 新增檔案
- `lib/features/auth/pages/tutorial_intro_page.dart`：新手教學引導頁（Logo、插圖、標題說明、「開始導覽」／「跳過教學」按鈕）
- `lib/features/auth/models/tutorial_step_model.dart`：教學步驟資料結構（步驟序號、對應底部導覽分頁 index、圖示、標題、說明文字、按鈕文字）
- `lib/features/auth/models/tutorial_mock_data.dart`：五步教學假資料（首頁／聲影日記／資訊站／儀表板／會員）
- `lib/features/auth/services/tutorial_service.dart`：教學完成狀態的資料服務（目前用記憶體變數模擬 `has_completed_tutorial`）
- `lib/features/auth/widgets/tutorial_overlay.dart`：教練標記（coach mark）疊加層，含半透明遮罩挖洞效果與提示框

### 修改檔案
- `lib/screens/main_screen.dart`：新增 `startTutorial` 參數；新增 `GlobalKey` 定位五個底部導覽 icon；新增教學播放狀態管理（目前步驟、目標位置量測、下一步／完成教學邏輯）；`build()` 改用 `Stack` 疊加教學 overlay
- `lib/core/constants/route_constants.dart`：新增 `AppRoutes.tutorial`（`/tutorial`）

### 目前狀態
- 全部使用假資料（`tutorial_mock_data.dart` 的 `mockTutorialSteps`，`TutorialService` 的記憶體變數），尚未接上真實 API
- 教學播放順序（首頁→聲影日記→資訊站→儀表板→會員）與 `MainScreen` 底部導覽的實際 index 順序不同，已在 `TutorialStepModel` 用獨立的 `pageIndex` 欄位對應，避免切換到錯誤分頁
- 已測試：Chrome 瀏覽器正常顯示，5 步教學可依序切換分頁並正確挖洞定位、跳過教學與完成教學皆會標記狀態

### 待後端確認（給後端組看，詳見「新手教學_API需求文件.md」）
- 使用者資料表是否可新增 `has_completed_tutorial`（boolean）欄位
- 讀取方式：建議合併進會員資料 API 一起回傳，不另開新 endpoint
- 寫回方式：完成／跳過教學時要呼叫哪一支 API
- 家屬版之後是否需要獨立的教學狀態欄位（`has_completed_tutorial_elder` / `_family`）

### 給接手組員的提醒
- `TutorialOverlay` 是獨立元件，之後如果別的頁面也要做類似的教練標記引導，可以直接複用，不用重寫挖洞邏輯
- 若要接真實 API，只需修改 `tutorial_service.dart` 內部實作，`MainScreen` 與 `TutorialIntroPage` 呼叫端完全不用改
- `main_screen.dart` 目前是直接切換分頁 widget（非 `IndexedStack`），如果之後遊戲頁或聲影日記頁需要保留頁面狀態（例如遊戲進行到一半），要留意切分頁時狀態會重置的問題

## 欣紜（架構更新：建立 core 核心層與全域常數定義）— 2026/08/31

### 本次異動目標
- 統一前端專案目錄架構，建立 lib/core 共用核心層，解決組員間目錄結構不一致問題。
- 集中管理全域路由路徑與後端 API 網址常數。
- 修復 welcome_page.dart 結尾缺少括號與分號的語法問題。

### 新增與變更檔案
- `lib/core/`：建立共用核心層
  - `constants/route_constants.dart`：定義全 App 頁面路徑常數（AppRoutes）。
  - `constants/api_constants.dart`：定義後端 API 基礎 URL 與請求路由常數（待後端 API 文件提供後更新端點）。
  - `network/`：預留全域網路請求模組。
  - `theme/`：預留全域主題與色票定義。
  - `utils/`：預留共用工具函式庫。
- `lib/features/auth/pages/welcome_page.dart`：修復結尾語法錯誤，恢復可編譯狀態。

### 開發與調用規範
1. 頁面跳轉：
   - 請統一使用 `AppRoutes.xxx` 進行導航，避免手寫字串造成拼字錯誤。
   - 範例：`Navigator.pushNamed(context, AppRoutes.settings);`
2. API 呼叫：
   - 後續所有網路請求端點請統一從 `ApiConstants` 取用路徑。

---

## Wen（遊戲首頁：頂部列／今日進度卡／六大認知領域卡片／底部任務按鈕）— 2026/08/29

### 新增檔案
- `lib/features/game/models/cognitive_domain_model.dart`：認知領域資料結構（id、title、icon、是否今日推薦）
- `lib/features/game/models/game_mock_data.dart`：六大認知領域假資料（語言／工作記憶／注意力／執行功能／視覺空間／數學）
- `lib/features/game/widgets/game_top_bar.dart`：遊戲首頁頂部列（首頁圖示、通知鈴鐺含紅點提示）
- `lib/features/game/widgets/training_progress_card.dart`：今日訓練進度卡片（完成數／總數、百分比、進度條）
- `lib/features/game/widgets/domain_card.dart`：單一認知領域卡片（圖示、標題、今日推薦標籤、按壓效果）
- `lib/features/game/widgets/game_bottom_actions.dart`：底部「每日任務」「我的成就」按鈕
- `lib/screens/game_home_screen.dart`：組裝以上元件成完整遊戲首頁畫面

### 目前狀態
- 全部使用假資料（`game_mock_data.dart` 裡的 `mockCognitiveDomains`），尚未接上真實 API
- 六宮格使用 `LayoutBuilder` 動態計算卡片尺寸，確保 2 欄 3 列剛好填滿畫面、不需捲動
- 已測試：Chrome 瀏覽器正常顯示、圖示置中、進度條與百分比正確反映假資料數值

### 待後端確認（給後端組看）
- 需要欄位：`completed_count`、`total_count`（今日訓練進度）、六大領域各自的 `is_recommended`（今日推薦邏輯，可能由 AI 依表現動態決定）
- 通知紅點 `hasUnreadNotification` 需要對應的未讀通知數量 API

### 給接手組員的提醒
- 六個小元件都是獨立檔案，直接 import 使用即可，不用改內部邏輯
- 卡片點擊（`DomainCard` 的 `onTap`）與底部按鈕點擊目前都只有 `// TODO` 佔位，尚未串接路由，前端路由方案（Navigator 或 go_router）待團隊會議討論後補上
- 若要接真實 API，只需修改 `game_mock_data.dart` 或改為呼叫真正的 service，`game_home_screen.dart` 與六個元件完全不用動