# B03/B04：V3 內容流水線與真實調用

日期：2026-10-08（Asia/Hong_Kong）。基線：`7a98ac9bc2fd3e71e009c6c7ffe16cacaf9a0ce0`，分支：`codex/supplemental-development`。承接 [B06 題型內容](2026-10-08-b06-question-content.md)，補齊下一步 V3 App 接入需要的內容/分析/資料保護核心。普通 App 仍是 V1，QA App 仍是 V2。

環境沿用本機 arm64、macOS 27.0.1（26A434）、Apple Swift 6.4；套件仍為 macOS 14 minimum / Swift 5 language mode。沒有最低系統實機通過聲明。

## 實作範圍

- [V3 分析](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3Analysis.swift) 保留原捕獲及固定方向，開始前保存 running，回調校驗完整記錄/元資料、revision、generation、attemptID、store ticket。新候選只追加，不覆蓋人工釋義/已確認關聯/忽略決策。
- [持久隊列](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3AnalysisQueue.swift) 保留 FIFO、兩次自動重試上限、provider deadline、非阻塞捕獲和取消 epoch。存儲錯誤不自動重發；重啟/恢復保持持久暫停，需明確恢復。單一實例只持有一個 worker，App runtime 仍需統一擁有該實例。
- [確認交易](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ConfirmationCommit.swift) 復用值型確認預覽/衝突選擇，但只寫 V3 模型。手動、單個和批量新詞均同交易建立一張 new 英文識別卡；Term.nextReviewAt=nil、legacy 計數為零，不複製能力。關聯已有詞不建額外卡、不造 ReviewEvent。
- [編輯](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3Editing.swift) 與整理保留 revision/完整預覽比對。內容編輯不能修改 legacy mastery。手動加詞補上服務層對已處理/忽略來源的拒絕，與草稿界面阻止狀態一致。
- [撤銷](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3UndoHistory.swift) 只持有一個容器內收據，現在檢查卡片、TermHistory、事件及 session/item。後續入組、揭示、作答、查詢、建卡或引用變動阻止撤銷；不刪學習歷史、不回滾 legacy 計數。無關詞復習不阻止內容撤銷。凍結課程 session 仍阻止撤銷新增課程，即使 membership 已移除。關聯會話內的其他項變化可能保守阻止撤銷，不靜默覆蓋。
- [資料保護](../../Sources/WordNoteCore/Domain/Services/WordNoteDataProtection.swift) 增加 V3 queue adapter 和待分析數。完整備份/預覽/恢復保留十一實體；取消或 ENOSPC 故障不自動恢復付費分析；舊 generation 的回調不能寫入新庫。

沒有修改 V1/V2 歷史模型、V3 SwiftData 模型或備份格式；format=4 延續 B06。部分純值類型沿用 `WordNoteV2*` 名稱，不代表在 V3 使用 V2 寫入服務。

## 新增驗證

| 測試 | 項數 | 主要內容 |
|---|---:|---|
| [V3AnalysisTests](../../Tests/WordNoteCoreTests/WordNoteV3AnalysisTests.swift) | 13 | 固定請求、一次保存、回調冪等/失效、重試預算、人工內容、草稿保護 |
| [V3AnalysisQueueTests](../../Tests/WordNoteCoreTests/WordNoteV3AnalysisQueueTests.swift) | 13 | 連續輸入、單 worker、精確命中、退避喚醒、取消/刪除/晚回調、存儲暫停 |
| [V3AnalysisRestartTests](../../Tests/WordNoteCoreTests/WordNoteV3AnalysisRestartTests.swift) | 4 | 磁盘多次重開、Retry-After、切庫拒絕、重啟不重置重試預算 |
| [V3ConfirmationCommitTests](../../Tests/WordNoteCoreTests/WordNoteV3ConfirmationCommitTests.swift) | 20 | 完整依賴、預覽/選擇、重送、已刪目標、混合批次回滾、撤銷 |
| [V3EditingTests](../../Tests/WordNoteCoreTests/WordNoteV3EditingTests.swift) | 16 | 批量草稿、同源 revision、英文主體、課程、完整回滾/屏障/忽略 |
| [V3ContentPipelineTests](../../Tests/WordNoteCoreTests/WordNoteV3ContentPipelineTests.swift) | 12 | 雙向捕獲至復習/備份、三種建詞、全部新卡原子回滾、安全撤銷、會話依賴、legacy 只讀 |
| [V3DataProtectionTests](../../Tests/WordNoteCoreTests/WordNoteV3DataProtectionTests.swift) | 6 | 十一實體備份導出、實際 SQLite 切庫、迟到回調、取消/故障暫停、草稿/CSV 邊界、舊備份不降版 |
| [LiveDeepSeekV3QueueTests](../../Tests/WordNoteCoreTests/LiveDeepSeekV3QueueTests.swift) | 1 | 兩次真實合成請求，再確認/本地命中/復習/完整快照往返 |

84 項新增離線測試通過。重用 V2 內容契約的測試仍先捕獲/校驗完整 V3，再檢查內容子集；全鏈路和資料保護測試直接比對完整 V3，避免只檢查八類舊字段。初輪集成測試有一個草稿字段名編譯錯誤、兩個樣本假設錯誤（已有 fixture tag、空課程沒有可選卡），修正測試後重跑，沒有降低產品驗證。

## 真實調用

用戶已允許實際調用。本輪只通過既有 `DeepSeekAPIKeyResolver` 讀取本機配置，沒有手動回顯 key、提交憑據、讀取真實詞庫或發送私人詞句。

- 輸入：`latent representation`、`過擬合`。
- 實際請求數：2；測試 handler 在第三次呼叫前拒絕，沒有批量評測或無界重試。
- 請求預設模型：`deepseek-v4-flash`；兩次服務回報模型皆為 `deepseek-flash`。
- 完整 live 流程約 6.44 秒，測試總耗時約 6.46 秒；token usage 未暴露，未估算費用。
- 分析後仍只有候選，人工確認後主體為英文、各建立一張 new 卡。重查及 captureID 重送不增加 API 請求，lookup 不寫正式作答/legacy 錯題；一次正式復習只更新一張卡並寫 version=2 事件。備份編解碼/新容器恢复完整相等。

這是兩個樣本的服務契約 smoke，不代表常用多義項/專業義品質的 60 例評測完成，也不是介面或真實用戶庫驗收。

## 回歸記錄

| 最終驗證 | 結果 |
|---|---|
| 普通 V1 完整嚴格 Debug | 1135 項，1129 通過、6 跳過、0 失敗 |
| V2 QA 完整嚴格 Debug | 1135 項，1129 通過、6 跳過、0 失敗 |
| V2 QA 完整嚴格 Release | 1135 項，1129 通過、6 跳過、0 失敗 |
| V3 真實 DeepSeek | 1 項通過，2 次请求 |

三套均為 Core 1090 項（5 跳過）+ App 45 項（1 跳過），沒有編譯 warning/error。opt-in 跳過組為三個付費 DeepSeek、兩個性能、一個原生快捷鍵；跳過不等於通過。本輪 V3 live 另以明確 opt-in 執行，不自動重跑舊 live 組。`git diff --check` 通過，6 份變更文檔共 177 個本地鏈接目標存在。

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
RUN_LIVE_DEEPSEEK_V3_TESTS=1 swift test -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors --filter LiveDeepSeekV3QueueTests
```

本機日誌：`/tmp/wordnote-v3-content-focused.log`、`/tmp/wordnote-v3-data-protection.log`、`/tmp/wordnote-v3-content-live.log`、`/tmp/wordnote-v3-content-v1-debug.log`、`/tmp/wordnote-v3-content-v2-debug.log`、`/tmp/wordnote-v3-content-v2-release.log`。保存/ENOSPC 測試為故障注入，不冒充真實斷電或磁碟已滿。

## 剩餘工作

1. 優先完成隔離 V3 runtime、共享唯一 queue、現有頁面/浮窗及新 Review/Settings/建卡交互，接上已測試的核心。不以繼續追加孤立 helper 代替產品交付。
2. 普通 App/真實詞庫尚未遷移，沒有正式啟用或原生 UI 驗收；不得把 V1/V2 writer 連到 V3 容器。
3. 全圖校驗仍在 MainActor；大庫保存/查找/列表及復習互動性能待測，不能由毫秒級單測推斷。
4. README 更新、界面介紹截图及最終工作樹/暫存區/可達歷史敏感資訊檢查仍留在代碼完成後的 C06。沒有改 README、生成介紹圖、執行完整敏感資訊審核、分發 App 或合併 main。
