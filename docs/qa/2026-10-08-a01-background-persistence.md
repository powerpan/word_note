# A01 Background Persistence

日期：2026-10-08（Asia/Hong_Kong）。起點：`7df95be`。分支：`codex/supplemental-development`。適用：QA-03、QA-04、QA-05；不代表 UI 驗收完成。

本輪先以合成資料量測，再修正已確認的主線程阻塞。沒有操作真實詞庫或升級 schema。README、產品介紹截圖與敏感資訊檢查仍留在 C06。

## Finding And Change

初次 Release 探測在 10,000 詞、40,002 個模型下，同步快照捕獲約 972 ms、同步恢復建庫約 9,397 ms。這是預熱後一次探測，不是 p95 證據；它證實這兩個同步呼叫不能繼續放在主線程。

- `WordNoteSnapshotCapture` 在后台創建自己的 ModelContext，只返回不可變 DTO。主 context 的待保存變更先落盤；同容器的保存通知同步計數，任何保存或待保存修改使整次讀取失效，最多重試三次。其他容器保存不誤觸發；持續變動、未改變的壞資料或取消均不生成成功備份。
- 正式 App 寫入仍集中於 MainActor。這個假設、同步通知計數與跨 executor 不傳 model/context 的限制已補入架構契約，不能用 `@unchecked Sendable` 包裝模型繞過隔離。
- staged restore 的建庫、保存、重開驗證及 checksum 改在后台；主線程返回後重新讀取 journal，保留期間新增的暫停旗標，拒絕競爭恢復的舊結果。取消不提交 pending，原庫及保護快照保留。
- 啟動前切換仍保留完整驗證。本輪不以省略校驗改善數字，也沒有將恢復總耗時描述為 15 ms。
- 將嚴格並發編譯擴展到測試後，發現原 live 測試共用非 Sendable 分析服務的診斷；已改成與生产入口一致的每請求建立實例，不更改 prompt、模型或 API 契約。

## Verification

| 項目 | 結果 |
|---|---|
| SnapshotCapture 新測試 | 9 項通過：未保存內容、其他 context 保存、無關庫、重試上限、並發驗證失敗、穩定失敗、取消、新 context |
| RestoreStore 新測試 | 3 項通過：后台執行且 MainActor 可繼續、取消不落 pending、重新讀 journal、競爭恢復不覆寫；該組合計 17 項 |
| 相關集成組 | 40 項通過（含 14 項 DataProtection） |
| 全量嚴格並發離線回歸 | 188 項，186 通過、2 按開關跳過、0 失敗；約 2.47 秒 |
| App/core 嚴格並發建置 | 通過 |
| Release 專用測試嚴格編譯 | 通過；該次明確關閉長測，只證明編譯，不當作性能重跑 |
| 實際 DeepSeek 回歸 | 2 次公開輸入請求，1 項通過，約 5.81 秒；返回模型均為 `deepseek-flash` |
| 正式性能組 | 兩檔各預熱 1 次、量測 30 次，全部字段往返一致；總計約 495 秒 |

Live 只發送 `latent representation`、`過擬合`，使用內存 store，正式詞條仍需人工確認。本輪只有這兩次成功 live 請求，嚴格編譯失敗那次沒有進入執行或發送請求。

```bash
env RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
env RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=1 BACKUP_PERFORMANCE_ITERATIONS=30 swift test -c release --filter WordNoteBackupPerformanceTests
env RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors --filter WordNoteBackupPerformanceTests
env RUN_LIVE_DEEPSEEK_TESTS=1 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors --filter LiveDeepSeekSmokeTests
```

## Performance

Apple M4、10 核、16 GiB；macOS 27.0.1 (26A434)、Apple Swift 6.4、Swift 5 語言模式。Release；最低目標 macOS 14 未實機驗證。電源/熱狀態未記錄，不據此推斷其他硬件表現。

每詞一筆 InputRecord、CandidateTerm、ReviewEvent，加兩門共享課程，總數分別為 4,002 / 40,002；JSON 約 2.08 / 20.80 MB（十進制）。源庫、每輪恢復目標與備份均為私有臨時合成資料。完整精度的 p50/p95/max 見 [JSON 結果](metrics/2026-10-08-a01-backups.json)。以下單位均為 ms。

| 操作 | 1,000 詞 p50 / p95 / max | 10,000 詞 p50 / p95 / max |
|---|---:|---:|
| 同步捕獲參考值 | 98.53 / 101.27 / 102.00 | 991.14 / 1008.86 / 1010.84 |
| 后台捕獲總耗時 | 98.45 / 101.77 / 102.62 | 1000.42 / 1025.20 / 1028.87 |
| 后台捕獲期間 MainActor 最大間隔 | 14.01 / 15.12 / 15.12 | 14.92 / 15.15 / 15.17 |
| 后台建庫/重開核對總耗時 | 593.04 / 604.66 / 612.81 | 9263.65 / 9328.86 / 9365.35 |
| 后台建庫期間 MainActor 最大間隔 | 14.89 / 15.10 / 15.12 | 15.08 / 15.12 / 15.13 |
| 下次啟動切換驗證（同步） | 119.88 / 124.10 / 127.14 | 1203.89 / 1227.23 / 1227.26 |
| Vault 新快照寫入與驗證 | 52.09 / 52.81 / 53.95 | 532.70 / 539.75 / 539.79 |

MainActor probe 每 10 ms 排程一次，表中的間隔是每輪的最大間隔再計算分位數，包含定時器本身等待；不是單幀時間、按鍵延遲或完整 App 端到端時延。改善的是主線程可調度性，不是恢復吞吐量。Vault 量測只含較小的恢復前 inventory，尚未模擬七份大型歷史快照；UI 下背景讀取與密集保存的實際體驗仍需回歸。

## Remaining Gates

- Computer Use 本輪能列到 QA App，但選取窗口時明確回覆 Mac 已鎖定且不能自動解鎖。已請用戶手動解鎖；未重複嘗試解鎖，也未把此前 `cgWindowNotFound` 猜測成 App 崩潰。
- 解鎖後仍需完成 [App 接入記錄](2026-10-08-a01-app-integration.md#remaining-gates) 的真實 Settings/文件選擇器/多窗口/退出重啟/CSV 表格軟件流程，以及 G00/A03 浮窗與 IME 回歸。
- 啟動校驗仍同步約 1.23 秒（10,000 詞 p95），本輪有意保留；完整啟動、保存可再輸入 p95 <= 300 ms 和搜索 p95 <= 200 ms 未由本測試驗收。
- 不能把 60 次隔離恢復成功推廣為已覆蓋物理斷電、macOS 14 實機或任意 schema 遷移。A01 保持進行中，不合併 main、不操作唯一真實庫。
