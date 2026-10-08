# B03 完整備份與受保護恢復

日期：2026-10-08（Asia/Hong_Kong）。基線：`3925a0a`，分支：`codex/supplemental-development`。對應 QA-19、部分 QA-20；承接 [第一批](2026-10-08-b03-isolated-foundation.md)，不是 B03/B04 完整啟用驗收。

## 交付範圍

- [VersionedPayload](../../Sources/WordNoteCore/Infrastructure/Persistence/WordNoteVersionedPayload.swift)、[reader](../../Sources/WordNoteCore/Infrastructure/Persistence/WordNoteSnapshotReader.swift)、[background capture](../../Sources/WordNoteCore/Infrastructure/Persistence/WordNoteSnapshotCapture.swift) 與 [vault](../../Sources/WordNoteCore/Infrastructure/Persistence/WordNoteBackupVault.swift) 現可完整捕獲、驗證、列出和導出 V3。cards/sessions/sessionItems 及事件前後狀態都參與 checksum，不能只備份 nested content。
- V1/V2 codec 和文件格式未變；舊 `readSnapshot`/`capture` 入口仍拒絕 V3。V2 App 資料保護預覽和直接傳入的 restore preview 都按 schema 能力拒絕 V3，拒絕發生在暫停分析、持有寫入屏障、建立保護備份之前。
- [Manifest](../../Sources/WordNoteCore/Infrastructure/Persistence/WordNoteStoreManifest.swift) 對 V3 使用 version 3、十一類 counts；V1/V2 日誌維持原五/八類編碼。新 counts 缺失、跨版混入、負數、超限及整數極值不允許通過。不以缺失字段默認 0 掩蓋會話丟失。
- [RestoreStore](../../Sources/WordNoteCore/Infrastructure/Persistence/WordNoteRestoreStore.swift) 在獨立 generation 建庫、完整值比對、關閉後重開再比對；啟用時再次核對全部 counts/checksum。原庫及保護備份保留，沒有重新命名或覆寫已打開 SQLite 的操作。
- V3 取消/回退後仍保留 version 3 日誌，V1/V2 store 入口拒絕它。低層 `open` 沒有待切換 generation 時只打開當前 schema，不隱式執行遷移。V3 缺失的已選中 SQLite 不會變成新空庫。
- 舊備份恢復到 V3 時只建立每詞一主卡，不補其他方向或會話。遷移時鐘取本次已驗證 beforeMigration/beforeRestore.createdAt；不使用導入舊備份的時間，也不在 worker 重開時重新取 now。V3 -> V3 原有 card ID、活動游標、已刪卡 tombstone 和 Unicode cloze 逐值保留。
- [StartupCoordinator](../../Sources/WordNoteCore/Domain/Services/WordNoteStartupCoordinator.swift) 共用現有遷移/恢復流程，V2 名稱保留兼容 typealias。V1 可經純值 V2 adapter 直達 V3，無中間活動庫。遷移在 UI/worker 建立前持有源庫寫入屏障，先持久化意圖/分析暫停，再建立並重讀保護文件；比較完整 payload 和摘要，包含 createdAt，staging 前後再次核對源庫。
- 中斷或失敗後要求顯式重試，不自動重播付費請求。取消只清理本次 pending，不撤銷另一操作的勝出 generation。歷史 cloze 缺穩定範圍時保留 term/event ID 問題列表及可讀錯誤，不猜測答案或改換方向。
- 已是 V3 的啟動也先做完整校驗；損壞會話不返回 ready。V2 inspectRepair/repair 不接受 V3 目標，完整 V3 修復仍是後續工作。

## 測試證據

| 新增測試 | 項數 | 覆蓋 |
|---|---:|---|
| [V3BackupTests](../../Tests/WordNoteCoreTests/WordNoteV3BackupTests.swift) | 8 | 十一實體后台捕獲、未保存草稿、跨 context 保存後整體重讀、錯 schema reader、混合 inventory/導出/權限、僅卡/會話變動、損壞備份不導出/不輪替、分析恢復信號 |
| [V3RestoreStoreTests](../../Tests/WordNoteCoreTests/WordNoteV3RestoreStoreTests.swift) | 14 | 活動游標/已刪卡/Unicode 完整恢復、舊備份升級時鐘、顯式開庫、舊入口拒絕、取消後不降版、counts/日誌篡改、staging/prepare/activate/commit 故障、卡片 checksum、缺失庫、取消與競爭 |
| [V3StartupTests](../../Tests/WordNoteCoreTests/WordNoteV3StartupTests.swift) | 13 | 原版 V1 SQLite 直達 V3、V2 升級、空庫保護、備份/目錄寫入失敗、cloze 阻止、保護時間篡改、prepared 重啟、activating 中斷、取消、源變動、競爭勝出者、損壞會話與缺失源庫 |
| [V2DataProtectionTests](../../Tests/WordNoteCoreTests/WordNoteV2DataProtectionTests.swift) | 1 | V2 預覽及直接 prepare 在任何暫停/保護寫入前拒絕 V3 |

新增合計 36 項。另調整原有 mixed retention 測試，三版共同保留最新七份自動備份及全部手動/保護備份；原有 V3 persistence 測試改為舊 codec 拒絕而共用 reader 完整讀取，沒有降低 checksum/關聯約束。

| 驗證 | 結果 |
|---|---|
| 版本化備份/恢復/啟動及 V3 定向嚴格 Debug | 152 通過，0 失敗 |
| 普通 V1 完整嚴格 Debug | 803 項，798 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Debug | 803 項，798 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Release | 803 項，798 通過、5 跳過、0 失敗 |

完整套件各為 Core 758 項（4 跳過）與 App 45 項（1 跳過）。跳過項為兩組付費 DeepSeek、兩組性能、一組原生全局快捷鍵；本批無 provider/prompt 改動，未產生新付費 AI 呼叫。所有資料為合成樣本或原始 V1 fixture 的臨時副本；fixture 原始 bytes 及歷史 V1/V2 模型未變，未開啟真實詞庫。

ENOSPC/權限問題由 checkpoint 故障注入驗證，不是填滿真實磁碟；activating 中斷由持久日誌狀態模擬，不聲稱已驗證真實斷電。磁盤 round trip 使用本機 SwiftData/SQLite，並實際重開資料庫。

```bash
swift test --filter 'WordNoteV3|WordNoteVersioned|WordNoteV2Startup|WordNoteV2DataProtection' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v3-qa \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

本機最終日誌：`/tmp/wordnote-b03-second-focused.log` 及 `/tmp/wordnote-b03-second-{v1-debug,v2-debug,v2-release}.log`。四份均無 compiler warning/error。開發中修正過新增 enum 分支遺漏及測試 async autoclosure；孤立 session item 同時使 waiting 會話缺項，按既有驗證順序先回 invalidValue，測試已按已核對契約修正，沒有放寬產品校驗。

`git diff --check` 通過；本批 7 份變更文檔的 173 個本地鏈接目標均存在。V1/V2 模型、codec、原始 V1 fixture、項目 README 及 docs 索引均無變更。

## 剩餘門檻

1. B03 刪除/完整性交易和 V3 專用 repair evidence/修復方案尚未實作；恢復合法 tombstone 不等同已提供刪除服務。
2. B04 scheduler、查詢信號分離及單一排程寫入，B05 會話控制器/正式作答冪等/窗口租約待實作。完整資料保護 UI 和 V3 分析隊列尚未接入，不能把 V2 writer 掛到 V3 容器。
3. 普通 App 仍是 V1，隔離 QA App 仍是 V2。本批只補預覽的 schema 分支及未來 counts 行，沒有啟用 V3 UI，未新增 Computer Use/最低 macOS 14 實機驗收聲明。
4. README、介紹截圖及全倉/可達 Git 歷史敏感資訊檢查仍在代碼完成後 C06；本批不執行、不分發 App、不合併 main。

下一批繼續 V3 刪除/完整性交易，完成後與 B04 共同接入隔離 App；QA-20 和 B03/B04 尚不能標記整體完成。
