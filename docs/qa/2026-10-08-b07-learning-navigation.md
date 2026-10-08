# B07 課程學習與窗口導航

日期：2026-10-08。基線：`7a604bd9b991ce42565314c44e06a4e394521d5d`。適用：WN2-B07、A06 的 V3 卡片篩選，QA-27/QA-28 的核心與部分原生驗收。本記錄隨本次里程碑提交，不宣稱 B 階段全部完成。

## 邊界

- 普通啟動保持 V1，V2 QA 保持 V2；學習頁只接入 `WORDNOTE_V3_VALIDATION` 的隔離 App。沒有讀取、遷移或修改真實詞庫。
- 沒有修改凍結的 V1/V2 schema、codec 或快照 fixture bytes。原 `populated` 測試資料保留，另增 `learning` 合成長列表。
- 本輪是離線 UI/統計/導航修改，沒有新增 DeepSeek 付費調用；前批 live 結果不當作本輪新增網絡證據。
- README、介紹用截圖及完整敏感資訊審查仍在 C06；本輪界面觀察僅為實作 QA，不提前製作 README。沒有分發、簽名、公證、合併 main 或發布。

## 實作

1. `ReviewCardLearningIndex` 是首頁、課程及詞庫卡片條件的共同分類。Review 工作量也使用該分類；有效題面、停用、埋藏、重學等待/上限、new 引入與日級到期保持分開。
2. `LearningOverviewBuilder` 只讀完整 V3 快照。課程詞表按當前 membership 去重；最近捕獲按凍結 courseID/time 篩選；Inbox 復用 `InboxBrowseItem` 和 active 規則。薄弱詞只用有效新語義 Again 或未消費 priority，不讀 legacy wrongCount。
3. 首頁明示方向，優先呈現繼續固定組、可答/新卡/等待、今日完成量及首次回憶分母；卡片前五項可直接打開，View All 帶同方向/狀態進詞庫。Inbox 和課程行也有精確路由。
4. 課程預設是學習閱讀頁，提供去重詞表、卡片狀態、薄弱詞、最近捕獲、Inbox；課程資料編輯須明確進入。Add 只改當前 capture course；Review 只預選新組範圍，已有組不能被另一課程入口替換。
5. 每個主窗口持有 `LearningWorkspace`。查詢、批選、焦點、閱讀 pin、行級滾動錨點、課程标签/方向和最多 30 個返回狀態不放在全局 runtime。Deep link 保留原搜索；明確開啟全卡/課程 Inbox 則重置不相容的舊條件，Back 可恢復之前狀態。
6. 路由和 Back 共用髒編輯保護，準備捕獲失敗不導航。精確 term/card/record 消失時保留其目標並顯示不可用，不偷換相鄰項；點卡只閱讀，不評分、不擴大固定組。
7. V3 詞庫新增 direction/mastery/state，三者必須匹配同一張卡，結果仍去重為 Term。沒有卡片條件時保留無卡詞條；不恢復舊 Term mastery 篩選。
8. `RememberingList`/`RememberingScrollView` 保存最上方可見行。這是行級恢復，不保證原像素偏移，也不宣稱重啟後保留整段導航歷史。

## 自動回歸

新增 22 項：`LearningOverviewTests` 9、`LearningWorkspaceTests` 12、`WordNoteTestFixtureTests` 1。

- 同時計算首頁/課程/Review 數值，與正式選組的可答 cardID 集合一致；概覽不寫庫。
- 同一卡片多條件匹配、legacy mastery 忽略、沒有卡片的詞仍可閱讀。
- 只有有效新 Again/priority 形成薄弱詞；作廢事件和 legacy 計數不參與。
- 重學到期前一秒/到期點分類改變但 payload 不變；最近遇見不隨 membership 刪除改写，也不顯示未到發生時間的來源。
- Inbox 原生模型與純值投影的 ID、釋義、confirmability 一致；跨課程/方向查詢不改固定組，無效 course/timezone/date 不退回全庫。
- 精確 pin、Back、View All 新範圍、查詢/批選/錨點保留；第二窗口狀態獨立、歷史上限、側欄切換重開路徑。
- 髒草稿取消/保存/放棄、等待 sheet 關閉、忙時拒絕第二導航、前置錯誤不換頁；course capture 不改持久預設或 source/intent。
- `learning` fixture 保留原四詞/課程/候選/事件，增加 40 合成詞及来源、12 draft。V1 -> V2 -> V3 後 44 詞、55 input、40 occurrence、15 active Inbox；不以真實庫生成長列表。

最終嚴格矩陣，均在最後一輪功能修改後執行：

| 構建 | 總項數 | 通過 | 跳過 | 失敗 |
|---|---:|---:|---:|---:|
| 普通 V1 Debug | 1182 | 1176 | 6 | 0 |
| V2 QA Debug | 1182 | 1176 | 6 | 0 |
| V2 QA Release | 1182 | 1176 | 6 | 0 |
| V3 QA Debug | 1182 | 1176 | 6 | 0 |
| V3 QA Release | 1182 | 1176 | 6 | 0 |

每組 Core 1108 項（5 跳過）和 App 74 項（1 跳過），完整並發檢查與 warnings-as-errors 均無警告。六項跳過為三種 live 測試、兩種 opt-in 性能組及原生快捷鍵註冊；未把跳過當通過。

```bash
STRICT=(-Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors)
swift test "${STRICT[@]}"
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION "${STRICT[@]}"
swift test --scratch-path .build-v2-qa -c release -Xswiftc -DWORDNOTE_V2_VALIDATION "${STRICT[@]}"
swift test --scratch-path .build-v3-qa -Xswiftc -DWORDNOTE_V3_VALIDATION "${STRICT[@]}"
swift test --scratch-path .build-v3-qa -c release -Xswiftc -DWORDNOTE_V3_VALIDATION "${STRICT[@]}"
```

本機日誌：`/tmp/wordnote-b07-v1-debug.log`、`/tmp/wordnote-b07-v2-debug.log`、`/tmp/wordnote-b07-v2-release.log`、`/tmp/wordnote-b07-v3-debug.log`、`/tmp/wordnote-b07-v3-release.log`，不納入 Git。`bash -n script/build_and_run.sh` 和 `git diff --check` 通過。

## Computer Use 原生驗證

環境：macOS 27 / arm64，App 為 `WordNoteQA`，窗口 `Word Note V3 QA`。只使用臨時合成 session `E591BC84-1E9C-4C25-B9F8-CDDB887BE91C`。主要窗口截图為 1962x1464 像素，約 981x732 pt @2x，不等同完整指定尺寸矩陣或 macOS 14 真機驗收。

```bash
./script/build_and_run.sh --ui-v3-fixture learning light E591BC84-1E9C-4C25-B9F8-CDDB887BE91C
./script/build_and_run.sh --ui-v3-fixture learning dark E591BC84-1E9C-4C25-B9F8-CDDB887BE91C
```

實際操作與觀察：

1. 初始首頁 44 ready、0 new/waiting/completed、15 Inbox、44 unique terms、2 courses。卡片 `gradient descent` 開啟對應詞條並突出指定英文卡，沒有寫回答。
2. 詞庫滾至 `study term 30` 附近，切 Courses 再回來，該行仍在頂部；課程詞表滾至 `study term 08`，打開 `study term 20` 再 Back，回到 `study term 08` 行。部分可見行恢復為整行頂部，未承諾像素偏移一致。
3. Computer Science 閱讀页顯示 22 詞/22 英文卡；另一門長課程名稱能換行。Add 打開 Quick Add 並預選 Computer Science，Source Other、Direction Automatic 未被入口改寫；沒有發送 AI 請求。
4. 課程 Review 只預選 Computer Science/English to Chinese/Due Today、target 20/new limit 10；點 Start 才建立固定 20 張。
5. 首張 overfitting 揭示後 Again，下一張 quick 出現：0 processed、1 answers、1 waiting。首頁 43 ready/1 waiting/0 completed，first recall 0/1；Waiting 清單精確列 overfitting 及到時時間。
6. CS 課程 21 ready/1 waiting/first recall 0/1，Needs Attention 僅 overfitting；ML 為 22 ready、0 waiting、無首答記錄。從 ML 點 Review 仍顯示現有 CS 20 張組，沒有隱式換組；Back 保留 ML 和 Needs Attention。
7. 最終版本以深色重啟同 session，仍保留 CS 固定組和一次回答。等候已到期，首頁恢復 44 ready/0 waiting，但 completed 仍 0、first recall 0/1，不因時間經過新增回答。
8. View All Cards 打開 Vocabulary，明示 English to Chinese + Ready now，44/44 詞。改 Chinese to English 後 0/44，未混入英文卡；Back 返回原首頁方向和卡片标签。此詞庫深色截图正常，窄窗口未見文字/操作遮擋。
9. CS 的 Inbox 按鈕帶 Computer Science 篩選，8 active/20 handled；Back 返回同課程。Recent Captures 點 `A study term 40 appears in this synthetic reading sample.`，打開相同 completed 原文記錄，原 Inbox 結果仍保留；再次 Back 保留 Recent Captures 标签。

## 工具限制與未驗收項

- 在 overfitting 詞條點 Edit 後，Computer Use 回報 `Sky Computer Use native pipe closed before response`；重新綁定及截圖仍失敗。進程存在不是可操作的證據，沒有把該髒編輯 Back 流程算通過。重啟隔離 App 後非編輯流程恢復，沒有更改測試之外的詞庫。
- 深色課程頁 AX 讀取及深鏈可用，但截圖多次僅返回傾斜的縮略窗口；一次 Raise 仍相同，因此不以那些圖判斷完整布局。原先明色課程及本次正常深色詞庫截图的觀察有效。
- 模型級兩窗口狀態隔離、取消/保存/失效目標已有測試，真正兩個原生主窗口、原生髒表單 Back 和跨窗口刪除目標仍需實機補驗。沒有進行 GUI 刪除測試或再次嘗試失效編輯入口。
- macOS 14 真機、完整三尺寸/多顯示器/大字體/VoiceOver/中文 IME、萬詞庫端到端性能仍按 B08/C06 和原計劃驗收，不能把本次 44 詞原生測試代替。

## 後續與回退

繼續 B08 的統一 Settings、偏好備份白名單、窗口分隔/隱藏、本地化及可訪問性；C01-C06 的義項、AI 契約/評测、來源/練習與最終 README/敏感資訊檢查仍在範圍內。本次沒有正式啟用 V3；普通啟動仍走 V1。測試舊 V2 必須另用新 UUID，不把已有 V3 session 降版打開。回退本提交只撤隔離界面/只讀導航，不回滾真實資料，也不以刪除測試庫掩蓋問題。
