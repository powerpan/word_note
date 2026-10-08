# B02 全局快捷鍵與提交

日期：2026-10-08（Asia/Hong_Kong）。基線：`88f227c`，分支：`codex/supplemental-development`。對應 QA-16、QA-17 的快捷鍵子範圍，不代表完整 B02 驗收。

## 範圍與環境

- 全局註冊、設置入口和主窗口 Command-Return 的新語義僅在隔離 V2 QA 啟用，普通 V1 入口不切換；不讀寫真實詞庫、不改 schema/快照/AI 契約。
- 本機 macOS 27.0.1（26A434）、Apple Swift 6.4、arm64；部署下限仍為 macOS 14，沒有最低系統或 Swift 5.9 實機證據。
- XCTest 使用臨時 UserDefaults suite、內存/臨時合成庫；QA bundle 為 `com.powerpan.WordNote.UITest`，分析為離線 stub。本批無付費 DeepSeek 請求。
- README、介紹截圖、全倉敏感資訊審計仍留在 C06，不進行分發或合併 main。

## 實作與邊界

| 文件 | 責任 |
|---|---|
| [CaptureShortcut](../../Sources/WordNoteCore/Domain/CaptureShortcut.swift) | 可編碼的啟停/鍵/修飾鍵配置、合法性和錯誤；預設 Control-Option-Space |
| [CaptureShortcutController](../../Sources/WordNoteCore/Domain/Services/CaptureShortcutController.swift) | 注入 backend/UserDefaults；先註冊新鍵再釋放舊鍵、失敗回滾、損壞偏好 fail closed、重按去重和暫停 |
| [CarbonCaptureShortcutBackend](../../Sources/WordNote/App/CarbonCaptureShortcutBackend.swift) | 系統快捷鍵預檢、exclusive 註冊、單一原生 handler 與進程唯一 native ID、主線程清理 |
| [CaptureShortcutSettings](../../Sources/WordNote/Presentation/CaptureShortcutSettings.swift) | 設置草稿/Apply/Reset/Retry、活動鍵及錯誤狀態；使用普通鍵選單和修飾鍵 checkbox |
| [V2ValidationRuntime](../../Sources/WordNote/App/V2ValidationRuntime.swift) | runtime 擁有唯一快捷鍵控制器，與菜單/命令共用 panel.toggle；替換/退出清理 |
| [WordNoteDataProtection](../../Sources/WordNoteCore/Domain/Services/WordNoteDataProtection.swift) | 直接通知恢復可用性；不依賴主窗口存活，不把恢復捕獲誤當恢復付費分析 |
| [VocabularyCompletionEditor](../../Sources/WordNote/Presentation/VocabularyCompletionEditor.swift) / [QuickAddView](../../Sources/WordNote/Presentation/QuickAddView.swift) | 目前編輯框 Command-Return 先同步 binding 再提交；IME 優先、不自動接受灰色補全；V1 nil 回調保留原窗口快捷鍵 |

配置只存本機 `captureShortcut.v1`，不加入詞库備份。Space/A-Z/F1-F12 按虛擬實體鍵碼，字母為 ANSI 位置，不宣稱隨任意鍵盤佈局翻譯。至少兩個修飾鍵且含 Control/Command；停用草稿可暫存未完整組合，未知 bit 或損壞值不能啟動註冊。

註冊失敗不覆寫保存值或釋放原鍵；原鍵釋放失敗則撤回新鍵，清理失敗的非活動 ID 也不觸發動作。handler 釋放與 key 釋放分開，避免已成功釋放 key 卻被錯報為仍活動；C 上下文只在 handler 成功移除後釋放。明確的 stop/disable/restore 是主清理路徑，析構僅兜底。

代碼復查去掉了最初的 `isolated deinit`；[Swift SE-0371](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md) 將其列為 Swift 6.2 新功能。新實作捕獲獨立原生狀態，在主線程同步或排回 MainActor 清理，不為此修改 package tools version。這不代表已用舊工具鏈驗證整個項目。

## 自動回歸

新增 28 項：

| 測試 | 新增數 | 證據範圍 |
|---|---|---|
| [CaptureShortcutControllerTests](../../Tests/WordNoteCoreTests/CaptureShortcutControllerTests.swift) | 12 | 預設/重複 start、長按去重、改綁順序、衝突保留、重試、停用/持久化、損壞設定、非法組合、暫停、釋放及回滾清理失敗、遲到回調 |
| [WordNoteDataProtectionTests](../../Tests/WordNoteCoreTests/WordNoteDataProtectionTests.swift) | 3 | 無窗口的立即狀態與轉換通知；取消/可恢復失敗恢復捕獲；recoveryRequired 保持暫停 |
| [CompletionTextViewTests](../../Tests/WordNoteAppTests/CompletionTextViewTests.swift) | 11 | 普通/小鍵盤 Command-Return、binding 順序、精確修飾鍵、Caps Lock、實際 AppKit marked text、非焦點不搶事件、普通 Return、Tab 與灰色補全、無 handler 回退 |
| [CarbonCaptureShortcutTests](../../Tests/WordNoteAppTests/CarbonCaptureShortcutTests.swift) | 2 | 全部鍵碼唯一；opt-in 真實註冊/排他衝突/重註冊/冪等釋放及 backend 析構清理 |

`WordNoteAppTests` 是新增 SwiftPM 組件測試 target，不是 XCUITest。直接調用 NSTextView 的事件處理方法不能證明中文輸入法候選窗口或跨 App 焦點的端到端行為。

| 最終驗證 | 結果 |
|---|---|
| 普通 V1 嚴格 Debug 全套 | 648 項，643 通過、5 跳過、0 失敗 |
| V2 QA 嚴格 Debug 全套 | 648 項，643 通過、5 跳過、0 失敗 |
| V2 QA 嚴格 Release 全套 | 648 項，643 通過、5 跳過、0 失敗 |
| opt-in 快捷鍵 + 編輯框 + 資料保護定向 | 43 項，全部通過 |
| Release opt-in 原生註冊組 | 2 項，全部通過 |

三份完整回歸日誌均無 warning/error，未降低 complete concurrency、warn-concurrency 或 warnings-as-errors。六份變更文檔的 131 個相對文件鏈接有效，`git diff --check` 通過。

5 個默認跳過項是兩组 live DeepSeek、兩組性能和一組 native hotkey。原生組已單獨打開開關執行：同進程兩個 backend 嘗試四修飾鍵加 F12，第二個報 `eventHotKeyExistsErr`；釋放第一個後可註冊，釋放/析構後再次註冊成功。不發送系統按鍵，不當作跨進程或跨 App 觸發驗收。

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
RUN_NATIVE_HOTKEY_TESTS=1 swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors \
  --filter 'CaptureShortcut|CompletionTextView|WordNoteDataProtectionTests'
./script/build_and_run.sh --ui-v2-fixture populated light
```

## 原生核對與限制

本批早期 QA session `86477D34-B479-468D-8361-035E424275B0` 成功構建啟動，Computer Use 讀到 `Word Note V2 QA` 首頁和合成資料。隨後「點擊 Settings 並讀取截圖」返回 `Sky Computer Use native pipe closed before response`；重置 REPL 後重新 getApp 仍同錯誤，沒有使用其他 UI 技術繞過。

不能確定 Settings 點擊是否生效，沒有取得新快捷鍵設置的畫面，也沒有驗證其他 App 前台按鍵。這份首頁觀察在後续主線程清理和恢復 hook 修改之前，不能替代最終二進制的 UI 驗收。未把任何畫面當作 README 介紹圖。

## 下一步及回退

1. 完成 B02 的主/浮窗共享當前與預設課程、來源、方向，提交凍結元資料並跨重試保留。
2. 完成浮窗最小隊列/錯誤反饋、複製英文、按需朗讀/停止與跳轉正確記錄。
3. 完成臨時结果可見上下文、10 秒失焦時計與隱藏後不重播，保留內容自適應高度。
4. 工具恢復後驗證：另一 App 前台 Control-Option-Space 顯示/再按隱藏；改綁/衝突/停用/重啟、主窗口關閉時恢復暫停；實際中文 IME 的 Return/Tab/Command-Return 及長按行為；最低系統與不同鍵盤、主題和窗口尺寸。

回退保持普通 V1 入口，V2 仍只允許 QA bundle/臨時 fixture。可在 V2 設置停用全局鍵；退出 QA 進程也會釋放系統註冊，不修改真實詞庫。B02 整體及 B/C 其餘任務仍進行中。
