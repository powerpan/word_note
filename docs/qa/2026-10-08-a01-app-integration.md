# A01 App Integration

日期：2026-10-08（Asia/Hong_Kong）。起點：`110ac1b`。工作分支：`codex/supplemental-development`。適用：QA-03、QA-04、QA-05，以及相關隊列回歸。

這是 A01 的 App 接入進展，不是 A01 完整驗收。全部自動化使用人工資料、內存容器或私有臨時持久庫；沒有重啟正式 App、恢復唯一真實詞庫或進行 schema 升級。README、介紹截圖和全倉敏感資訊檢查仍後置至 C06。

## Implemented

- `WordNoteRestoreStore` 成為 App 唯一分代啟動入口；沒有恢復日誌時仍兼容歷史 store 位置遷移。套用恢復偏好後持久確認，初始化失敗顯示錯誤頁，不能向臨時空庫繼續寫資料。
- `WordNoteDataProtection` 共享於主窗口、Settings 和浮窗。Settings 提供備份列表、手動快照、完整 JSON 導出/導入預覽、替換確認、明確刪除、失敗及清理告警。Vocabulary 導出選中或当前篩選範圍，打開文件選擇器前固定 DTO，明示行數。
- 恢復要求再次確認替換全部資料及放棄所有窗口未保存表單；先鎖定同容器寫入、暫停分析、持久化暫停旗標，再建立及重讀驗證恢復前快照，最後建新代和受控退出。舊 store 不在線覆寫。
- 若恢復前備份或 staging 失敗，確認日誌沒有待切換狀態後才解鎖；日誌不明時保持鎖定。正常退出在 preparing 期間被拒絕，ready 狀態可退出或取消；取消仍保留保護快照並要求明確恢復分析。
- `WordNoteWriteGate` 在 Course/InputRecord/Vocabulary/Review/修復等 19 個領域寫入口先校驗；同容器其他 context 也受保護。Candidate 目前的直接編輯 Binding 加入屏障，但獨立草稿/revision/安全撤銷仍屬 A04，未宣稱已解決所有未保存編輯問題。
- Inbox 和 Quick Add 的分析共用可測的服務方法。ticket 在安排 Task 前擷取，成功/失敗回調再次驗證，取消恢復也不讓舊 callback 重新有效；忽略 cancellation 的 handler 不能覆寫新狀態。重試數量使用實際新增候選，而非含已確認歷史的原始 AI 項數。
- 自動備份由 App 級保存 observer、1 秒 debounce 及 60 秒检查管理，不要求主頁或 Settings 持續打開；首次/變更/24 小時條件不變。無新變更時不反覆捕獲全庫；輪替失敗可在新備份尚未到期時重試。
- 受管理資料目錄及其符號鏈接別名禁止作為導出目的地。核對時修正了「目的文件尚不存在時只解析完整 URL 會漏掉父目錄別名」的問題，改為先解析父目錄再校驗。

## Automated Evidence

環境沿用 [G00](2026-10-07-g00-a03.md#environment)：macOS 27.0.1、Apple Swift 6.4、Swift 5 語言模式，最低目標 macOS 14 仍未實機驗證。

| 測試組 | 新增數 | 結果與範圍 |
|---|---:|---|
| WordNoteWriteGateTests | 6 | 19 個寫入口、共享/獨立容器、延遲成功/失敗、未開始 Task、忽略取消的 handler、取消後 ticket 仍失效 |
| WordNoteDataProtectionTests | 14 | 備份/導出偏好、固定 CSV 範圍、目的地保護、預覽失敗、ENOSPC、準備/取消/重啟、顯式恢復分析、並發恢復、日誌不明 fail-closed、自動觸發與清理重試 |
| QuickAddAnalysisQueueTests | 1 | 部分已確認記錄重試後保留歷史，新增候選數為 0，但本次临時釋義正常展示 |
| 全套離線回歸 | 175 合計 | 174 通過、1 live 按開關跳過、0 失敗；約 2.38 秒 |
| strict concurrency + warnings-as-errors | build | 通過；約 3.17 秒 |
| 最終版本雙向 DeepSeek live | 1 | 通過，2 次真實請求；約 5.66 秒 |
| launcher 語法 / diff 空白檢查 | check | 通過 |

```bash
env RUN_LIVE_DEEPSEEK_TESTS=0 swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
env RUN_LIVE_DEEPSEEK_TESTS=1 swift test --filter LiveDeepSeekSmokeTests
bash -n script/build_and_run.sh
git diff --check
```

Live 使用明確授權和兩個公開測試輸入 `latent representation`、`過擬合`。請求別名仍為 `deepseek-v4-flash`，兩次返回均為 `deepseek-flash`。測試經 `InputRecordService.analyze` 寫入內存候選區，兩個 InputRecord 為 analyzed、候選數與保存結果一致，正式 Term 數仍為 0，不繞過人工確認；不發送真實詞庫。此前接入版本另有一輪 2 請求通過（約 4.27 秒），此接入工作共 4 次成功 live 請求，不包含 G00 的調用。這不是 C02 的 60 例品質、費用或延遲評測。

## Isolated App Evidence

QA 改為私有臨時持久 session，便於重啟驗證；不把可恢復能力建立在內存 store 上。參數只在 `com.powerpan.WordNote.UITest` 生效；`WordNote-QA/<UUID>` 下保存人工 store、備份和獨立測試憑據，AI 仍為離線 handler。相同 session 可重開，不傳則使用新 UUID，不自動清除舊測試資料。

```bash
./script/build_and_run.sh --ui-fixture populated light 67bbc13b-e856-4a54-8dbf-1204a1d7f685
```

- QA 進程已啟動，該 session 實際產生一份 automatic 快照，format 1 / schema 1.0.0。
- 快照 metadata：2 Course、3 InputRecord、3 CandidateTerm、4 Term、1 ReviewEvent；Backups 目錄 0700、文件 0600。這驗證了 App 的啟動備份 hook 確有執行，不只是核心測試。
- Computer Use 能列到 WordNoteQA，但選取窗口回報 `cgWindowNotFound`；沒有拿到可驗收截圖或完成點擊流程。沒有證據將工具錯誤認定為 App 崩潰，也不以進程存在宣稱 UI 通過。
- 此次 QA 啟動驗證早於最後的候選數量回歸和清理告警調整；最終代碼已完整重建/跑測試，但不能把該次啟動當作最終 UI 驗收。

## Remaining Gates

後續的大庫測量及主線程阻塞修正見 [A01 Background Persistence](2026-10-08-a01-background-persistence.md)。本記錄保留接入當時的測試數；最新原生工具狀態為 Mac 鎖屏，UI/表格軟件未驗收。

- 隔離 App 中實際操作：新建/導出/刪除快照，導入預覽/取消、確認替換/受控退出/重啟、恢復偏好與明確恢復分析；两個主窗口、Settings、浮窗同時開啟時確認寫入禁用。
- 最小/標準/大窗口與明暗版面、原生文件選擇器、VoiceOver/鍵盤、錯誤提示。G00/A03 的 IME、浮窗自適應高度和 10 秒失焦計時仍需實機回歸。
- 用 Excel/Numbers 實際打開含公式前綴、中文、多行的導出 CSV。字串單測通過不等於第三方 App 行為已驗證。
- 1,000/10,000 詞合成庫的捕獲/恢復耗時及主線程影響；尚未證明大庫性能達標。
- 故障測試為注入 ENOSPC、延遲 handler 和持久日誌狀態重放；不冒充真實斷電/磁碟耗盡，亦未強殺真實 App。

A01 與 A 階段保持進行中；僅提交/推送開發分支，不合併 main，不在唯一真實詞庫嘗試恢复或 A02 生產遷移。回退 App 代碼前先保留所有 generation 和保護快照；一旦新代已啟用，不能直接啟動不理解日誌的舊 binary，以免重新打開過期根 store。
