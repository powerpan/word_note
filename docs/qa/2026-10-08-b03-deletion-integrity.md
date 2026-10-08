# B03 V3 刪除與受保護完整性修復

日期：2026-10-08（Asia/Hong_Kong）。基線：`02f9b49`，分支：`codex/supplemental-development`。承接 [第二批備份/恢復](2026-10-08-b03-protected-recovery.md)，補齊 QA-20 的刪除/修復核心邊界；不是 B03/B04 完整啟用驗收。

## 範圍與契約

- [V3 ContentService](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ContentService.swift) 與 [Deletion](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3Deletion.swift) 實作 record、occurrence、term、course、card 刪除及停卡。每次操作先檢查寫入屏障、未提交草稿、整庫關聯與 revision，完成後驗證全部十一實體，單次保存，失敗全部回滾。未提交的外部草稿不被保存或 rollback。
- 正常刪除不能充當自動壞資料清理：原圖非法時，在任何改動前停止。record 刪除只解除 live source 引用，保留詞條/occurrence 原文及卡片；Term 刪除級聯其來源、查詢、membership、卡及作答事件，已保存候選轉 targetDeleted 並保留確認身份。
- occurrence 刪除使依賴它的 cloze 卡停用。`ReviewClozeTarget.sourceDeletedAt` 是既有 JSON 內的可選 tombstone，不改 SwiftData 模型欄位；保留卡/target/原 occurrence ID，清空 hash、答案變體與範圍，清除 due/priority。缺此標記的來源失聯仍是損壞，不推測使用者曾刪除。舊 JSON 缺此可選欄位仍可解碼。
- 刪卡/停卡使對應會話項 unavailable，保留 originalCardID、position、attemptCount、lastActionID，不增成功作答。當前項失效且仍有待展示項時 paused，不自動抽卡；只剩 waiting 時按原暫停狀態處理；全終態才結束。已結束會話的結束時間/範圍不改。單獨刪卡或來源保留事件，刪 Term 才級聯其事件。
- 課程仍受 InputRecord、membership、歷史 occurrence 引用數保護；無權威引用時才可刪除並清 legacy Term.courseID。已保存會話的課程範圍是歷史快照，不改成另一課程。
- [V3 IntegrityService](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3IntegrityService.swift) 的檢查與預覽只讀。只復用 V2 的三種可空失效外鍵解除；保留全部卡/會話/事件/legacy 計數，受影響 Term revision 只加一次。必要引用、重複鍵/actionID、元資料不匹配、非法日期/排程等都阻止自動修復，無半修復結果。
- 修復方案綁定完整 payload 與白名單偏好，不只比 revision。background inspection 保留非法關聯，但 JSON/enum 嚴格解碼失敗時仍停止，保留原 SQLite，不以空值替換來製造可修復證據。
- [V3 EvidenceVault](../../Sources/WordNoteCore/Infrastructure/Persistence/V3/WordNoteV3RepairEvidenceVault.swift) 獨立保留原始十一實體及元資料，schemaVersion=3.0.0、完整 counts/checksum，700 目錄與 600 文件，原子新文件寫入及重讀全值比對。它不是正常 backup；普通 reader/V2 evidence reader 拒絕。既有 V2 evidence 文件格式不變。
- [StartupCoordinator](../../Sources/WordNoteCore/Domain/Services/WordNoteStartupCoordinator.swift) 新增 inspectV3Repair；共用 repair 流程按版本選正確 plan/evidence。顯式預覽後才可修復：保存 repair 意圖與分析暫停、封鎖源寫入、保留並重讀原始證據、在新 generation 建庫，再次確認源資料及 pending 後切換。不覆寫原庫，失敗要求重新預覽，不重播 AI 請求。
- [RestoreStore](../../Sources/WordNoteCore/Infrastructure/Persistence/WordNoteRestoreStore.swift) 只允許同版本 V2/V3 repair，不把修復當升級；V3 仍為 version 3 日誌及十一類 counts。取消或競爭只撤本次 pending，prepared 重啟可完成，activating 中斷保留原庫並要求顯式恢復。

## 測試證據

| 新增測試 | 項數 | 主要覆蓋 |
|---|---:|---|
| [V3DeletionTests](../../Tests/WordNoteCoreTests/WordNoteV3DeletionTests.swift) | 15 | 六種操作的 revision/草稿/屏障/非法時間/保存失敗；完整刪除關聯、停卡不改歷史、會話 paused/waiting/終態、課程引用、counter overflow、壞圖禁止清理、來源 tombstone 的完整備份及真實磁盤重開 |
| [V3IntegrityTests](../../Tests/WordNoteCoreTests/WordNoteV3IntegrityTests.swift) | 13 | 三種可空引用且一次 revision、所有新表重複 ID/業務鍵/元資料、必需/交叉引用、缺 cloze 源不捏造刪除、舊 JSON 與 tombstone 嚴格驗證、非法標量/歷史、全值方案過期、只讀檢查、損壞 JSON、舊 schema 拒絕、后台完整捕獲 |
| [V3RepairEvidenceTests](../../Tests/WordNoteCoreTests/WordNoteV3RepairEvidenceTests.swift) | 6 | 非法關聯十一實體原樣往返、普通/舊 reader 拒絕、counts/header/payload 篡改、寫入故障保留前檔、建立後重讀 generation/date、700/600 權限、symlink 拒絕、非法時鐘/來源代次 |
| [V3StartupRepairTests](../../Tests/WordNoteCoreTests/WordNoteV3StartupRepairTests.swift) | 13 | 只讀 preview/顯式修復、原庫/證據保留、必要 review 關係阻塞、備份/建庫/準備/啟用/提交故障、偏好/卡/會話變動、草稿、取消/重入/競爭、prepared/activating 重啟、非法日誌與顯式分析恢復 |

新增合計 47 項；同時回歸既有 V2/V3 備份、恢復、啟動及 evidence 測試。

| 驗證 | 結果 |
|---|---|
| V3、V2 啟動及 evidence 定向嚴格 Debug | 155 通過，0 失敗 |
| 普通 V1 完整嚴格 Debug | 850 項，845 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Debug | 850 項，845 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Release | 850 項，845 通過、5 跳過、0 失敗 |

完整套件分為 Core 805 項（4 跳過）與 App 45 項（1 跳過）。跳過項為兩組付費 DeepSeek、兩組性能及一組原生全局快捷鍵。本批不涉及 provider/prompt/queue 寫入改動，無新增付費 AI 呼叫；實際調用授權保留給需要網絡驗證的階段。

測試只用人工樣本、內存/臨時 SQLite 和原版 V1 fixture 的副本，未讀寫真實詞庫。ENOSPC 用 checkpoint 注入，activating 中斷用日誌狀態模擬，不聲稱實際磁盤已滿或完成斷電測試。切庫及重新打開使用實際 SwiftData/SQLite。

開發測試曾發現兩個測試自身問題：比較未 canonicalize 的新增卡順序；切庫後讀取已被釋放 context 的模型 ID。分別改為 canonical 全值比較及切換前保存 UUID，未降低產品的關聯/校驗約束；修正後重跑定向及全套。

```bash
swift test --scratch-path .build-v3-qa \
  --filter 'WordNoteV3|WordNoteV2Startup|WordNoteRepairEvidence' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v3-qa \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

本機日誌：`/tmp/wordnote-b03-third-focused.log` 及 `/tmp/wordnote-b03-third-{v1-debug,v2-debug,v2-release}.log`，最終四份均無 compiler warning/error。本批沒有改 V1/V2 模型/codec、原版 fixture、項目 README 或 docs 索引。

`git diff --check` 通過；7 份變更文檔共 179 個本地鏈接目標均存在。沒有以刪減原有測試或放寬舊快照讀取器來取得通過。

## 剩餘門檻

1. 普通 App 仍 V1、隔離 QA App 仍 V2。B04 scheduler/查詢信號、完整 V3 content writer/queue/資料保護 UI 須共同接入，不能把 V2 服務接在 V3 容器上。
2. B05 會話控制器、正式作答冪等與窗口租約尚未實作。本批修改既有會話資料的刪除語義，不代表整個會話工作流已完成。
3. 刪除服務為阻止壞圖清理，在 MainActor 進行前後完整校驗。啟用前須量測大詞庫刪除/停卡延遲，必要時優化一致性讀取；本批核心正確性測試不是性能通過證据。
4. 尚未新增 V3 UI、Computer Use 或最低 macOS 14 實機驗收；既有未過的 UI/窗口/快捷鍵門檻保留。QA-20/B03/B04 不標整體完成。
5. README 項目介紹、介紹截圖及全倉/可達歷史敏感資訊檢查仍在 C06、代碼與測試完成後執行；不分發 App、不合併 main。

下一批推進 B04 的純排程與查詢信號契約，再接完整 V3 寫入服務及隔離 App。
