# A02: Protected Startup Integrity Repair

日期：2026-10-08（Asia/Hong_Kong）。基線：`4b4725c`；工作分支：`codex/supplemental-development`。

## 範圍與邊界

延續現有啟動協調器、完整性值層方案及共用切庫日誌。V2 啟動完整性檢查失敗後，inspectRepair 只讀預覽；repair 必須明確呼叫，且只使用本次有效預覽。正式 App 仍是 V1，未接入此入口，不操作個人詞庫。

- 僅解除已確認不存在的可選引用，不刪行、不猜測缺少的詞/課程，不改寫釋義或歷史計數。
- 寫入屏障及 analysisRequiresResume/recoveryRequired=repair 先落地，才保存原始證據。預覽過期需重新檢查，失敗不自動重跑修復。
- 獨立 evidence 文件保留原始八實體、元資料、偏好及非法引用，附原 generation、數量和 checksum；不是能直接導入的備份。正常 snapshot/vault 校驗沒有放寬。
- 文件在私有 Backups/RepairEvidence 目錄，0700/0600，64 MiB 上限；以 UUID 新建、不覆寫、不自動清除。寫後與 staging 前重讀比對；只保存在本機，不打印原文。
- 正常修復結果由同一后台建庫/重開校驗及 journal 啟用。operation=repair 時，兩個 snapshot ID 欄位引用 evidence ID；取消或故障保留原庫，取消僅匹配自己的 pending generation。
- 修復標記下不能直接恢復不合法資料的分析；若原庫已經人工修正，明確恢復分析會重新完整校驗再清除標記。沒有繞過完整性閘門。

證據文件的 checksum 用於一致性和損壞檢查，不是加密或防止同一帳號惡意改寫的簽章。不可自動修復的問題繼續保留原库並要求人工處理；本批沒有承諾通用的壞庫修復器。

## 測試

新增 `WordNoteRepairEvidenceVaultTests` 6 項及 `WordNoteV2StartupRepairTests` 12 項。資料全部為合成/臨時 SQLite；故障使用 checkpoint 和日誌重放，不冒充物理斷電或真實磁碟耗盡。

| 類別 | 覆蓋 |
|---|---|
| 證據格式 | 非法引用完整往返、正常 reader 拒絕；錯誤 purpose/版本/schema/ID/世代/checksum/數量均拒絕 |
| 文件保護 | 權限、符號鏈接、寫前/寫後失敗、替換元資料、舊文件保留；非法世代/時鐘不寫入 |
| 明確操作 | 無預覽不得修復，預覽不改日誌/不寫證據；必要引用問題阻止修復 |
| 成功路徑 | 修復副本逐字段與方案相同；原庫/原始證據保留，舊 context 在持有其 container 時仍受屏障保護 |
| 失敗路徑 | 備份、staging、prepared、activate、commit 失敗保持原 generation；證據保留，未重新預覽不得再提交 |
| 並發與草稿 | 取消、reentrant、已保存內容/偏好變更使預覽過期；未保存內容不由捕獲保存或丟棄 |
| 啟動恢復 | prepared 跨啟動完成；activating 中斷退回原庫，不自動再修復；非法日誌不重寫 |
| 分析恢復 | 不合法原庫不能解除暫停；已人工修正的原庫經明確校驗可恢復，不被舊標記永久鎖住 |

初次定向測試曾因測試只保留 ModelContext、未保留其 ModelContainer，在檢查退休 context 時觸發 SwiftData unowned 引用陷阱。已讓測試明確持有 session/container，跨切庫檢查只保留值 ID；沒有修改業務校驗來放行測試。下列是修正後的結果。

```bash
RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test -c release \
  --filter 'WordNoteV2Startup|WordNoteRepairEvidenceVaultTests|WordNoteVersioned|WordNoteRestoreStoreTests|WordNoteDataProtectionTests|WordNoteSnapshotCaptureTests|WordNoteBackupVaultTests|WordNoteV2IntegrityTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

swift build --product WordNote -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

| 檢查 | 結果 |
|---|---|
| 嚴格離線全套 | 348 項，346 通過、2 跳過、0 失敗；測試耗時 5.524 秒 |
| 跳過項 | live DeepSeek、opt-in 大庫性能；本批沒有網絡協議變動，不重複產生付費請求 |
| Release 定向回歸 | 145 項通過、0 失敗；測試耗時 4.352 秒 |
| 嚴格 App 建置 | 通過；完整並發檢查及 warnings-as-errors 開啟 |
| 文檔鏈接與差異 | 8 份文檔共 80 個相對鏈接有效；git diff --check 通過 |

## 剩餘工作

App 的 V2 查詢、交易、隊列、Settings/啟動恢復 UI 仍待整體接入。本批沒有打開真實詞庫，沒有重新做 V2 大庫性能或最低 macOS 14 實機驗收。Computer Use 再選隔離 QA bundle ID 回報 cgWindowNotFound；不推斷鎖屏，不把編譯/服務測試當成實機通過。

A02/G00/A01/A03 的 UI 閘門保留；不合併 main、不分發 App。README、產品截圖和全倉敏感資訊審核仍在 C06 後置執行。
