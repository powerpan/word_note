# A02/B01 持久分析隊列與受控 Live 驗證

日期：2026-10-08（Asia/Hong_Kong）。分支：`codex/supplemental-development`。前置提交：`9286403`。

## 範圍與狀態

本批補齊 V2 App 接入所需的分析交易和 B01 共用隊列核心。沒有啟用真實詞庫遷移，沒有修改 App 的 V1 類型別名、三個輸入入口、任務視圖或正式恢復界面。A02/B01 仍為進行中，G00/A01/A03 的實機閘門沒有新增通過證據。

README 改寫、介紹截圖、全倉敏感資訊審查保持在 C06，未提前執行；未涉及分發、公證或 main 合併。

## 代碼變更

- [分析交易](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2Analysis.swift)：begin 先保存 running/attemptID；網絡只接收值型 request；complete/fail 重新核對 revision、generation、attemptID 和恢復 ticket。刪除、取消、恢復或過期回調均不能重建記錄。
- [持久隊列](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2AnalysisQueue.swift)：InputRecord 為唯一工作來源，單 worker、非阻塞捕獲、可取消/重試/暫停，新的即時任務喚醒退避等待。生產構造入口綁定 store generation，發送和保存前檢查 pending restore。
- [重試策略](../../Sources/WordNoteCore/Domain/AnalysisRetryPolicy.swift)：連線/超時/429/5xx 最多兩次自動重試，基準 2/4 秒；遵守 Retry-After，超過 60 秒只允許到期後人工重試。格式和憑據問題不自动消費。
- [HTTP 客戶端](../../Sources/WordNoteCore/Infrastructure/AI/DeepSeekChatClient.swift)：區分取消/超時/格式/HTTP 失敗，不把錯誤 body 或 URLSession 診斷內容傳給 UI。未修改模型別名、prompt 或 thinking 配置。
- [內容服務](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2ContentService.swift) 強持有 ModelContainer，避免網絡等待後只剩不具擁有權的 context；保留未保存直接修改的拒絕邊界。
- [V2 快照校驗](../../Sources/WordNoteCore/Infrastructure/Persistence/V2/WordNoteSnapshotV2Validation.swift) 接受 cancelled 任務攜帶尚未到期的 nextAttemptAt；這是冷卻期限，不是自動工作，不新增實體或字段。

## 資料與重試保護

1. 同 captureID 的重送不重建或再次發送；不同 capture 保留各自 note、courseID、sourceType 和方向。英文精確命中沿用本地查詞交易，不經 AI。
2. 重分析不刪除既有候選，不覆寫同 normalizedTerm 的人工內容、savedTermID 或 saved/ignored 狀態，只追加新英文主體。已刪的保存目標不會重建。pending 候選帶到目前 generation，失敗/取消後仍能人工確認。
3. 釋義預覽基於實際保存/保留的內容，不把未接受的新文字展示成已修改成功。完整字段差異採納仍由 C02 實作。
4. 保存失敗回滾本次變更並暫停，不把成功網絡請求當作可直接再發的工作。原輸入及 running 狀態留存，明確恢復時才允許重放；服務端可能已處理/計費。
5. 中斷 running 先持久化 analysisRequiresResume，再改 queued 並使舊 generation 失效；保留 autoRetryCount。日誌失敗不改工作、不發請求，第二次重啟仍需明確恢復。
6. 取消退避任務保留未到期 deadline，跨快照及 SQLite 重開一致，不能經「取消再重試」提前越過服務端等待。

## 測試結果

本批新增 42 項：策略 6、HTTP 5、分析交易 13、隊列 13、磁盤重啟 4、獨立 live 1。既有 HTTP 2 項和其他回歸亦保留。

| 檢查 | 結果 |
|---|---|
| 嚴格 Debug 全套 | 390 項，387 通過、3 跳過、0 失敗；約 6.09 秒 |
| 嚴格 Release 定向 | 203 項通過、0 失敗；約 3.51 秒 |
| App 編譯 | Debug 全套及 Release 定向均成功編譯、連結 WordNote 產品，無編譯診斷 |
| V2 雙向 live | 1 項通過，2 次真實請求，約 4.68 秒 |
| 真實詞庫 | 未讀取、未遷移、未寫入；資料測試全部使用內存或臨時 SQLite |

離線跳過項為既有 V1 live、新增 V2 live、大庫 opt-in 性能。先前一次 Release 構建因新增測試中的局部 weak 變量警告失敗，已修正並重跑通過；沒有把該次失敗算作成功。

重現命令：

```sh
env RUN_LIVE_DEEPSEEK_TESTS=0 RUN_LIVE_DEEPSEEK_V2_TESTS=0 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

env RUN_LIVE_DEEPSEEK_TESTS=0 RUN_LIVE_DEEPSEEK_V2_TESTS=0 swift test -c release \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors \
  --filter 'WordNoteV2|WordNoteVersioned|QuickAddAnalysisQueueTests|WordNoteWriteGateTests|AnalysisRetryPolicyTests|DeepSeekChatClientTests'

# 必須獲明確授權；會產生最多兩次付費請求。
env RUN_LIVE_DEEPSEEK_V2_TESTS=1 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors \
  --filter LiveDeepSeekV2QueueTests
```

## Live 邊界

使用固定公開輸入 `latent representation` 和 `過擬合`，現有 resolver 在進程內讀取配置，未輸出 API key。配置請求模型是 `deepseek-v4-flash`，兩次服務回傳均為 `deepseek-flash`；不混淆別名與返回值。

兩筆原始捕獲可連續保存，完成後只進入英文候選，沒有自動加入正式詞本。測試顯式確認英文候選後，再以大寫英文精確查詢，返回相同本地釋義並記錄一次 lookup event，真實請求數仍為 2。此測試不代表 C02 的 60 例語義品質、費用或延遲評測；未取得 token usage，不估算費用。

## 尚待接入

- App 的異步 V2 啟動狀態、V2 模型/服務綁定和版本化資料保護入口。
- 主 Quick Add、浮窗、Inbox 分析/重試全部改用唯一 V2 queue；目前主 App 仍走 V1。
- B01 任務視圖及整理交互、A04 編輯保護/A05 預覽與撤銷。
- 真正渲染及交互回歸、恢復對話框、窗口尺寸與實機閘門；本批沒有用核心測試冒充界面驗收。
