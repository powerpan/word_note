# A01 Persistence Foundation

日期：2026-10-08（Asia/Hong_Kong）。起點：`77c17de`。工作分支：`codex/supplemental-development`。

本次是 A01 的核心資料保護提交，不是完整功能交付。沒有修改正式 App 的啟動選庫路徑、Settings 或唯一真實詞庫。所有測試只使用合成樣本、固定 V1 資源的副本和臨時目錄；沒有執行真實詞庫替換或 schema 升級。README、介紹截圖和最終敏感資訊檢查仍按 C06 後置執行。

## Implemented

- 完整 V1 邏輯快照包含 5 類模型的全部持久字段，保留 UUID、原始文本、人工修訂、候選狀態、日期、規範化字段、重複查詢計數及完整 ReviewEvent。舊中文主體或混合語義的 wrongCount 不在恢復時偷偷刪改。
- envelope formatVersion 1 / sourceSchemaVersion 1.0.0。payload 是 JSON 字符串，SHA-256 對其解碼後原始 UTF-8 bytes 校驗；外層 JSON 重新排版不影響驗證。恢復比較按實體 ID 排序，不依赖輸入陣列順序。
- 限制完整文件 64 MiB、模型總數 100,000、單字段 1,000,000 字符、字符串列表 10,000 項。讀取前檢查常規文件和大小，按塊有界讀取，再檢查格式、版本、checksum、數量、重複 ID、外鍵、枚舉、日期與數值。
- 偏好只白名單收錄 appearance/defaultSource；不讀取任意 UserDefaults、API key 或 env 文件。尚未新增的模型/偏好不虛構序列化字段。
- 备份 actor 串行處理檔案工作。私有目錄 0700、文件 0600；同目錄臨時文件寫入、fsync、原子替換及目錄同步。已存在的快照不得覆寫，拒絕符號鏈接及非常規文件，導出不改用戶所選父目錄權限。
- 首次有資料即允許自動備份；後續變更且滿 24 小時才觸發。系統時間回撥以最近建立記錄重置基準，不無限等待未來時間；持久 catalog 保持建立順序。
- 保留最近 7 份 automatic，保留所有 manual/beforeMigration/beforeRestore。新文件及 catalog 落盤並校驗後才刪舊自動快照；損壞文件原樣保留並計數告警。輪替失敗不丟新備份，下次檢查即使內容未變也可重試清理。
- CSV 僅使用呼叫方顯式提供的詞條範圍，採雙引號 escaping / CRLF，對公式前綴與控制字符轉安全文字。CSV 不含原文全文、候選或事件，不是恢復格式。
- 分代恢復底層在私有 `Stores/<UUID>/WordNote.store` 建新庫，保存後重新打開核對；不 rename 或覆寫已打開的原庫。只接受 UUID generation，不接受快照提供的路徑。
- `store-generations.json` 記錄 prepared/activating 狀態及校驗資料。下次 open 在建立 ModelContainer 前讀取；成功驗證後原子提交 active generation，上一代和恢復前快照保留。啟動未提交中斷或驗證失敗時回原代，不自動創建空庫冒充恢復。
- 有 analyzing 記錄的恢復庫持久保存「待使用者明確恢復」旗標；非機密偏好另有待套用確認，重啟不會忘記。App worker 是否尊重旗標尚待接入測試，不能只憑底層旗標宣稱已防止付費重播。

## Automated Evidence

環境沿用 [G00 記錄](2026-10-07-g00-a03.md#environment)：macOS 27.0.1、Apple Swift 6.4、Swift 5 語言模式、macOS 14 最低目標。未在 macOS 14 實機驗證。

| 測試組 | 數量 | 結果與範圍 |
|---|---:|---|
| WordNoteSnapshotTests | 17 | 全字段往返、固定 V1 store -> JSON -> 新持久庫重開、完整性、不支持新版、損壞 checksum、超限、無效枚舉/引用/ID；schema metadata 與 DTO 字段集合一致 |
| VocabularyCSVExporterTests | 4 | 指定範圍、逗號/引號/換行/中文、公式前綴與控制字符 |
| PrivateFileIOTests | 6 | 0700/0600、原子覆寫、禁止覆寫既有快照、ENOSPC 中斷原檔不變、符號鏈接/FIFO/目錄/超大文件拒絕、父目錄權限不變 |
| WordNoteBackupVaultTests | 10 | 首次/變更/24 小時/重啟/回撥、刪至空庫、7 份輪替與保護種類、寫入/catalog/清理失敗、損壞清單恢復、導入導出與顯式刪除 |
| WordNoteRestoreStoreTests | 14 | 準備後不改原庫、下次啟動切換、取消、各日誌中斷點、暫存數據篡改/缺失、非法 generation/符號鏈接、保留旧代、stale token、分析與偏好確認跨重啟保留 |
| 全部離線回歸 | 154 | 153 通過、1 live 測試按開關跳過、0 失敗 |
| 嚴格並發及警告視為錯誤 | build | 通過 |

可重跑命令：

```bash
env RUN_LIVE_DEEPSEEK_TESTS=0 swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

本次未重跑付費 live 測試：沒有改 AI handler、prompt 或模型配置。上一個提交已在用戶授權下完成兩次真實 DeepSeek 請求，詳見 G00 記錄；該結果不當作此次恢復入口或 C02 品質評測證據。

測試開發時曾定位到輔助函數用臨時 `ModelContainer` 取 `mainContext` 後，容器過早释放導致 SwiftData trap。修正為顯式保留容器生命期後，單獨恢復組及完整套件均通過；未把測試進程崩潰誤報為正式 App 崩潰或跳過該用例。

ENOSPC 為受控故障注入，activating 中斷為持久日誌狀態重放；尚未以實機強殺 App、真實磁碟耗盡或斷電替代測試。成功通過不代表任何檔案系統/硬體故障均可恢復。

## Remaining Gates

以下保留本次核心提交時的待辦基線；後續 coordinator、啟動、Settings 和網絡屏障接入結果以 [A01 App 接入記錄](2026-10-08-a01-app-integration.md) 為準，不改寫本次 154 項歷史測試結果。實機、表格軟件和大庫性能仍未完成。

- App 級資料管理 coordinator、所有窗口和領域寫入服務的寫入屏障、未保存表單處理、取消/過期 AI 回調驗證。低層 `prepareRestore` 的前置條件是已取得屏障且傳入當前庫的已驗證保護快照，不能直接綁在 UI 按鈕上。
- Settings 的備份列表、手動建立/導出/刪除、錯誤與輪替告警、恢復預覽和替換確認；Vocabulary 所選/篩選 CSV 的範圍與數量確認。
- 正式啟動路徑掛接唯一 generation bootstrap、受控退出/重啟、恢復偏好套用、待分析顯式恢復；不能與舊啟動路徑並行競爭選庫。
- 自動備份的啟動補做與運行期觸發接入；大庫捕獲及恢復耗時測量，避免主線程長時間阻塞。
- QA-04 的延遲網絡回調/同時兩窗口寫入，QA-05 的 Excel/Numbers 實際開啟驗證，以及隔離 App 的完整恢复 UI 流程。
- G00/A03 的實機未過項仍有效；本次沒有重試已知失敗的 Computer Use 連接，也沒有將未驗證 UI 標記通過。

未完成以上項目前，A01 及 A 階段保持「進行中」。此提交只能作為開發分支上的核心邏輯進展，不合併主分支、不在真實詞庫試驗恢復或開始 A02 生產遷移。
