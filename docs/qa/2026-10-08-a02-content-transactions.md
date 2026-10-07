# A02: Isolated V2 Content Transactions

日期：2026-10-08（Asia/Hong_Kong）。基線：`a1a7d1b`；工作分支：`codex/supplemental-development`。

## 狀態與邊界

本批推進 A02 的本地寫入核心，不代表 A02 完成或 V2 已啟用。App 的模型別名、啟動、AI worker 和 Settings 恢復入口仍使用 V1。沒有操作正式詞庫，沒有合併 main，也沒有 app 分發改動。V1 歷史類型和 SQLite fixture 未更改。

所有測試使用人工資料、記憶體庫或臨時 SQLite。這次不涉及 AI 協議變更，沒有發出 DeepSeek 請求；使用者對 live 的授權保留給需要實際網絡驗證的階段。README、最終產品截圖和全倉敏感資訊審核仍在 C06，不提前執行。

## 實施內容

| 範圍 | 已實作 |
|---|---|
| 寫入協調 | V2 schema 檢查；MainActor 共用 container.mainContext；autosave 關閉；恢復屏障先於修改；未保存直接編輯拒絕；一次 save，任何錯誤 rollback |
| 新提交 | captureID 冪等；同文字的不同提交不合併；凍結方向、detector version、課程、note、來源和入口；Save Only 與排隊分開 |
| 本地精確命中 | 同交易建立 occurrence、LookupEvent 和缺少的課程關聯；不建立 InputRecord/Candidate、不調 AI；正式釋義不覆寫 |
| 既有復習規則 | 暫留 legacyMixed 的重查加權、到期及 10 分鐘 wrongCount 冷卻；不是 B04 新計數/排程實作 |
| 候選確認 | 新建英文詞或關聯相同規範詞頭；候選/記錄/目標 revision 與 generation 檢查；確認狀態、savedTermID、operationID、來源/課程一起保存 |
| 關聯已有詞 | 保留正式內容、review event 和計數；不建查詢事件；相同 term/capture 不重建來源；只在關係增加時更新 Term.revision |
| 手動建詞 | 英文主體、必要釋義按凍結方向校驗；原文、課程和捕獲入口保留；來源完成與建詞一起保存 |
| 課程 | 建立課程；增加/解除唯一 membership；解除 membership 不抹掉歷史 occurrence 課程，也不把兼容 courseID 當權威重新寫入 |
| 刪輸入 | 刪候選，清空來源外鍵；保留已确认詞、原文快照、課程關聯和復習歷史 |
| 刪來源 | 解除 LookupEvent.occurrenceID，保留查詢事實；舊提交重送不復活來源；尚無 V3 cloze 卡可停用 |
| 刪詞 | 級聯 ReviewEvent/occurrence/membership/LookupEvent；候選保留 saved 狀態並標 targetDeleted；同確認操作重送不重建詞 |
| 刪課程 | 分別檢查 InputRecord、membership、歷史 occurrence 引用；有引用拒絕。無權威引用時清空兼容 courseID 再刪除，避免懸空外鍵 |
| 快照 | 補充 InputRecord.capturedViaRaw 的持久化/往返；有 sourceRecordID 的 occurrence 必須匹配 captureID 與入口標記 |

服務對外返回值和 ID，不把可變 SwiftData 模型交給另一 executor。交易不含 await 或網絡請求。相同操作重送的保護依賴保留的持久化實體；不是永久 tombstone/事件溯源系統。全部相關資料被用戶明確刪除後，不保留無限期的提交收據。

## 測試矩陣

新增 37 項服務測試及 1 項快照校驗；既有快照往返測試也增加非預設 floatingQuickAdd 記錄及來源。

| 測試類別 | 數量 | 主要證據 |
|---|---:|---|
| WordNoteV2CaptureTests | 14 | 新任務凍結、Save Only、重送、同詞不同提交、ID 衝突、精確命中、恢復後重送、冷卻、中文方向、壞輸入、歧義、保存/計數失敗回滾、未提交編輯保護 |
| WordNoteV2ConfirmationTests | 11 | 新詞/關聯、保留人工內容、缺少未使用候選釋義、恢復後 operation 重送、唯一來源、三方 revision、generation、手動建詞與保存失敗 |
| WordNoteV2DeletionTests | 12 | 四類刪除、targetDeleted、課程三種引用、歷史課程保留、唯一 membership、stale revision、失敗全圖回滾、全部 9 個寫入口的恢復屏障、拒絕 V1 容器 |
| WordNoteV2PersistenceTests | 23 | 前批 22 項，加未知/不匹配 capturedVia 拒絕；非預設入口參與 SQLite 保存、重開和完整快照逐值比對 |

失敗注入測試不只斷言「拋錯」，也核對拋出的是注入的 save 錯誤，避免尚未走到保存就早期失敗而誤報回滾成功。回滾前後比較完整 V2 快照，涵蓋所有 8 類實體及元資料。

## 命令與結果

沿用前批主機/工具鏈，Swift 5 language mode，target macOS 14。這不是實際 macOS 14 機器的驗證。

```bash
RUN_LIVE_DEEPSEEK_TESTS=0 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test -c release \
  --filter 'WordNoteV2CaptureTests|WordNoteV2ConfirmationTests|WordNoteV2DeletionTests|WordNoteV2PersistenceTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

swift build -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

| 檢查 | 結果 |
|---|---|
| 嚴格離線全套 | 248 項，246 通過、2 跳過、0 失敗；測試耗時 3.004 秒 |
| 跳過項 | live DeepSeek 與 opt-in 大庫性能；不將上一批 V1 性能當作本批 V2 測量 |
| Release V2 全套 | 60 項全通過，0 失敗；測試耗時 0.540 秒 |
| 嚴格 App 建置 | 通過，warnings-as-errors 開啟，沒有忽略 warning |
| 文檔相對鏈接 / git diff --check | 5 份本批文檔的 49 個相對鏈接存在；差異空白檢查通過 |

開發時一處 XCTAssertNotEqual 的第二個 throwing 參數漏寫 try，屬測試編譯錯誤，已補正並通過最終完整回歸；沒有跳過測試或放寬 warnings-as-errors。

## 實機狀態與後續

本批透過 Computer Use 重取 `dist/WordNoteQA.app`，返回 `cgWindowNotFound`；全局狀態可列出隔離 QA app 正在運行，正式 Word Note 未運行，但沒有可讀取的 QA 窗口。這不同於前一批的明確鎖屏錯誤，不能據此斷言現在仍鎖屏，也不能替代 UI 驗收。本批沒有繞過 Computer Use、重啟正式 App 或反覆重試窗口查詢。

仍需完成：

- V2 資料完整性報告/保守修復，以及 App 查詢與既有業務服務的版本接入。
- vault/coordinator 的 V2 路由、遷移前保護快照、staged V2 日誌和啟動切換、取消/崩潰集成回歸；不得直接改 typealias 啟用。
- A01/A02 實機、CSV 表格軟件、V2 大庫端到端延遲和最低系統相容性驗收。同步交易在主執行緒，未測量前不宣稱大庫捕獲不阻塞。
- A04 草稿/撤銷、A05 批量 ConfirmationPlan/fill、B01 持久化任務 worker；本批的單項確認與 queued 狀態不是這些頁面/功能已完成。

主 App 正式啟用 V2 前仍須通過 A01 資料保護與實機閘門。QA-06/QA-07 保持未整體完成。
