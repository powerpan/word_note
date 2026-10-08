# B02 捕獲結果生命週期與操作

日期：2026-10-08（Asia/Hong_Kong）。基線：`c6911da`，分支：`codex/supplemental-development`。對應 QA-18 及 QA-16/17 的部分回歸；不是完整 B02 或正式 V2 上線驗收。

## 實作範圍

- V2 queue 保存成功後才發 CaptureFeedbackEvent，固定 direction、captureID、capturedVia 及目標 ID；本地命中指向既有 Term，新分析指向 InputRecord。失敗、取消、過期及冪等重送不誤報新結果。
- CaptureFeedbackHub 不保存最後事件，弱訂閱；主 Quick Add/浮窗各自處理顯示生命週期，隱藏、離頁、最小化及關閉清空。只有當時已顯示的捕獲畫面接收新結果。
- 浮窗 systemUptime 時計累計失焦 10 秒，聚焦暫停；窗口和 popover 用不同焦點 owner，舊 timer token 不能清新結果。主 Quick Add 不自動倒數。
- 任務圖標顯示 pending/failed/paused，按需展開同一隊列的恢復、暫停、取消、重試；不新建第二份隊列。
- 英文複製、按需系統朗讀/停止及打開目標記錄。Apple 英文 voice 不可用時明確顯示狀態，不索取麥克風/Personal Voice 權限，不接第三方雲端語音。controller 持有操作狀態，presentation 替換或清理結果時同步停止音頻，不依賴 SwiftUI 重繪。
- 導航只選一個主窗口，按 ID 固定詳情，保留當前已打開目標頁的搜索/篩選並提供返回；不新增已銷毀頁面的歷史篩選持久化。沒有主窗口時用 openWindow 重開；目標已刪顯示不可用。Save/Discard/Cancel 保護不被路由繞過。
- 高度按內容量測，限於所在螢幕 visibleFrame 減 36 pt；無結果仍為 360x60 pt。跨顯示器位置限制有純值測試，尚未做真實多顯示器拖動驗收。
- 實機重現「喚出後立即輸入 quick，實際入隊 uick」：移除 60 ms 延遲，顯示時同步設定原生 firstResponder；掛載前焦點請求不丟失，同一請求重繪不搶焦點。共用 completion 控件的這項修復也覆蓋 V1；V1 不啟用新的 V2 結果/路由或全局快捷鍵。
- 修正 QA 新建庫的外觀初值：先設定本 session 要求的主題，再產生遷移偏好，避免 dark 測試被上一會話的 light 覆蓋。已有恢復偏好的優先順序不變，未修改正式資料。

## 代碼與測試

| 文件 | 責任 |
|---|---|
| [CaptureFeedback](../../Sources/WordNoteCore/Domain/Services/CaptureFeedback.swift) | 結果事件、弱訂閱及單調時計 |
| [CaptureFeedbackTests](../../Tests/WordNoteCoreTests/CaptureFeedbackTests.swift) | 新增 17 項可見性、焦點、timer 邊界與同步清理回調 |
| [CaptureFeedbackQueueTests](../../Tests/WordNoteCoreTests/CaptureFeedbackQueueTests.swift) | 新增 7 項保存、方向、目標、失敗及重送整合 |
| [FloatingExplanationRowTests](../../Tests/WordNoteCoreTests/FloatingExplanationRowTests.swift) | 新增 3 項顯式方向及英文投影 |
| [CaptureResultWindowBridge](../../Sources/WordNote/App/CaptureResultWindowBridge.swift) | AppKit 可見性/焦點邊界，不覆蓋窗口 delegate |
| [CaptureResultActions](../../Sources/WordNote/App/CaptureResultActions.swift) / [測試](../../Tests/WordNoteAppTests/CaptureResultActionsTests.swift) | 新增 12 項 copy/speech/stop/失敗/晚到回調及隱藏結果同步停止 |
| [CaptureResultNavigation](../../Sources/WordNote/App/CaptureResultNavigation.swift) / [測試](../../Tests/WordNoteAppTests/CaptureResultNavigationTests.swift) | 新增 12 項單窗口、弱引用、重開、一次消費、恢復及編輯保護 |
| [FloatingQuickAddMetricsTests](../../Tests/WordNoteAppTests/FloatingQuickAddMetricsTests.swift) | 新增 5 項螢幕高度/位置約束及 V1 保持 |
| [CompletionTextViewTests](../../Tests/WordNoteAppTests/CompletionTextViewTests.swift) | 新增 3 項同步初始焦點/掛載/不搶焦點，原 IME/Tab/提交用例保留 |

新增共 59 項。核心使用內存或臨時合成庫；時計注入可控 monotonic clock/sleep，不用真的等 10 秒。copy/speech/router 替身不讀剪貼板、不播放音頻、不操作真實窗口或詞庫；AppKit completion 組件使用未顯示窗口，不合成系統輸入事件。

| 驗證 | 結果 |
|---|---|
| V2 嚴格定向 | 79 項通過 |
| 普通 V1 嚴格 Debug 全套 | 730 項，725 通過、5 跳過、0 失敗 |
| V2 QA 嚴格 Debug 全套 | 730 項，725 通過、5 跳過、0 失敗 |
| V2 QA 嚴格 Release 全套 | 730 項，725 通過、5 跳過、0 失敗 |

使用 complete concurrency、warn-concurrency、warnings-as-errors。默認跳過兩組 live DeepSeek、兩組性能和一組 native hotkey。這批沒有改 prompt/provider，UI 使用離線合成 handler，沒有新增付費 AI 呼叫；fixture 對非特定輸入回傳示例釋義，不能當成 DeepSeek 語義品質測試。最低 macOS 14 尚未實測。

```bash
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors \
  --filter 'CaptureFeedback|CaptureResult|FloatingExplanationRowTests|FloatingQuickAddMetricsTests|CompletionTextViewTests'
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
./script/build_and_run.sh --ui-v2-fixture populated dark
```

日誌：本機 `/tmp/wordnote-b02-complete-focused.log` 和 `/tmp/wordnote-b02-{v1-debug,v2-debug,v2-release}.log`。四份最終日誌均無 compiler warning/error；`git diff --check` 通過，本批 7 份文檔的 152 個本地鏈接目標均存在。

## Computer Use 證據

所有 session 都是 `com.powerpan.WordNote.UITest` 的獨立合成庫，未讀寫正式詞庫。截圖只用於開發回歸，不作 README 介紹圖。

1. `FF5FF5FB-4FD5-49D5-8417-A70DC3008008`：任務 popover 明確 Resume；新結果在主 Quick Add/浮窗顯示，浮窗保持焦點超過 10 秒仍保留。主頁切 Inbox 再回 Quick Add 不重播；浮窗隱藏再開只剩 360x60 pt 輸入行。失焦累計的精確時間以注入時計測試為證，不把操作間隔當精密計時。
2. `B7F99133-B56D-416B-87F1-BEF7A367B611`：詞庫搜索 gradient，浮窗精確查 quick。Copy English 後粘貼進輸入框只得到 quick；点击朗讀出現 Stop speaking。Open Record 打開 quick 詳情，gradient 篩選原樣保留且有返回入口。這是原生播放狀態驗證，不等於聽音品質驗收。
3. 点击 Edit 時 Computer Use 斷連；重置再連一次仍失敗。系統 `SkyComputerUseService-2026-10-08-115652.ips` 報告該工具服務在 Array.remove(at:) 斷言觸發 EXC_BREAKPOINT/SIGTRAP；QA 進程仍在。沒有用替代 UI 通道繞過；不把該編輯頁或其保護彈窗記為已驗收。
4. `7C5849D3-3D97-4ED2-85D4-CF3CB2BCF0E0`：連續提交 precision/recall，顯示 2 pending/1 failed/paused；明確恢復後兩筆完成。Inbox 搜索 quick 不變，Open Record 精確定位 recall，主操作為 Confirm All。關閉主窗口後浮窗仍可查 quick，再点击 Open Record 重開主窗口並定位 quick。此會話要求 dark 但仍呈 light，據此定位 QA 外觀初始化問題，未冒充深色驗收。
5. `67DC6048-5DA6-417F-84A9-9EC9ADB4BE8B`：外觀修复後浮窗為黑灰色；立即喚出/輸入的同一操作序列復現 uick，據此修復同步聚焦。
6. `83D696BB-71D7-4B3E-BE8B-98A059E76E48`：同步聚焦修復後，重跑連續的喚出/輸入 quick/Return 操作，正確本地命中 quick，0 pending，未丟首字母。深色結果完整顯示中文釋義與操作按鈕，未留下多餘底部空白。
7. `BF606128-7D93-4728-BA96-702F4E012462`：最終 controller 持有操作狀態及同步清理改動後重建；立即喚出/輸入 quick/Return 仍正確本地命中，點朗讀顯示 Stop speaking。快捷鍵隱藏再打開沒有重播舊結果，浮窗回到 360x60 pt 輸入行。這次只驗證可見操作狀態；隱藏時同步停止音頻由生命週期整合測試驗證，不宣稱已完成聽音品質測試。

## 未過門檻

Settings 配置、真正另一 App 前台的系統鍵、實際中文 IME 組合輸入、編輯保護彈窗、真實多主窗口/多顯示器完整矩陣仍需補驗。缺聲音/停止/回調隔離的替身用例不等同所有 macOS 語音環境都已驗證；不能把 B02 標成全面完成。

B08 仍須完成新增預設的備份兼容；B03 及後續復習/義項階段按計劃繼續。README、介紹截圖及全倉/可達歷史敏感資訊檢查保留到 C06；本批不執行上述後置任務、不分發 App、不合併 main。
