# A02 V2 隔離 App 接入

日期：2026-10-08（Asia/Hong_Kong）。基線：`28224dc`，分支：`codex/supplemental-development`。本記錄對應 QA-06、QA-07、QA-09、QA-15 的新增代碼與自動化證據，不把尚未完成的 UI 項標記通過。

環境：macOS 27.0.1（26A434）、Apple Swift 6.4（swiftlang-6.4.0.34.1）、arm64，SwiftPM 的 macOS 14 部署目標。測試只用內存或臨時磁盤 fixture。

## 範圍與隔離

- 新增 `WORDNOTE_V2_VALIDATION` 編譯標記和 `--ui-v2-fixture` 啟動選項，復用現有頁面，不另做一套產品設計。
- 測試版必須使用 `com.powerpan.WordNote.UITest`，且有合法 fixture 參數；否則顯示啟動錯誤，不能回退到生產 store 或憑據。資料留在系統臨時目錄的 `WordNote-QA/<session UUID>`。
- 普通編譯及 `WordNote.command` 仍使用 V1。Core 的頂層 V1 model aliases 和凍結 schema 不變；只有 QA App 模組中的綁定切換到 V2。
- QA App 分析使用離線 fixture；真實 DeepSeek 請求只經顯式 opt-in live 測試，公開合成輸入，內存庫，最多兩次請求。
- 沒有讀寫、遷移用戶的真實詞庫。沒有改 README、製作介紹截圖、執行全倉敏感資訊審計或處理 App 分發。

## 已實作

| 路徑 | 接入與保護 |
|---|---|
| [異步啟動](../../Sources/WordNote/App/V2ValidationRuntime.swift) | 先檢查 QA 身份，再建立或重開 fixture；經既有遷移 coordinator 返回 ready 後，才建立 queue、資料保護及浮窗。失敗提供明確重試、只讀檢查和另行確認的保守修復入口 |
| [場景入口](../../Sources/WordNote/App/WordNoteV2ValidationApp.swift) | 主窗口、Settings、菜單欄和浮窗共用同一 session；啟動失敗時不展示可寫頁面 |
| [App 綁定](../../Sources/WordNote/App/AppDataBindings.swift) | 復用現有页面；所有 V2 增刪改由交易服務執行，不將 V1 模型寫入 V2 容器 |
| Quick Add / 浮窗 / Inbox | 唯一 V2 queue，保存後立即允許下一次輸入；主/浮窗捕獲來源分別保存；Inbox 不再另起網絡 Task |
| [任務入口](../../Sources/WordNote/Presentation/V2AnalysisTasksView.swift) | Inbox 獨立可展開區，列出持久任務、狀態、錯誤與重試時間，可取消、重試、暫停；不把 queued/running 混入待確認 |
| [候選草稿](../../Sources/WordNote/Presentation/V2CandidateEditorRow.swift) | 值型編輯，不直接綁定正式模型；明確保存/放棄，未保存時禁用本候選區的直接確認，衝突拒絕覆寫 |
| [內容編輯](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2Editing.swift) | Term/Course 載入時記住 revision；保存一次交易；詞頭英文校驗、課程引用、候選世代、回滾和恢復屏障 |
| [批量基礎](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2CandidateSelection.swift) | 先核對整批候選/記錄 revision，再單次保存；重複新詞整批拒絕，忽略不破壞已保存關聯。尚非 A05 衝突預覽/自動關聯 |
| 多課程 | 詞條可選多個課程，Vocabulary/Review 篩選、課程計數和 CSV 都使用 TermCourseLink；原 occurrence 和兼容 courseID 不被編輯覆寫 |
| [資料保護](../../Sources/WordNoteCore/Domain/Services/WordNoteDataProtection.swift) | V1/V2 版本化捕獲、八類計數預覽、恢復前快照、準備/取消/重啟切換；V2 未提交模型修改不能被備份或恢復代為保存 |
| [復習兼容](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2LegacyReview.swift) | feedback/postpone 進入 V2 單次交易；沿用 legacyMixed、既有間隔和事件意義，不提前啟用 B03/B04 |

## 自動化證據

新增 25 項：內容編輯/批量交易 12、版本化 App 資料保護 8、V2 舊復習兼容 5。既有 V1 controller 測試新增版本化預覽拒絕 V2 的斷言。

| 驗證 | 本批結果 |
|---|---|
| 嚴格 Debug 全套，普通 App 編譯 | 415 項，412 通過，3 跳過，0 失敗，約 6.67 秒 |
| 嚴格 Debug 全套，V2 QA 編譯 | 415 項，412 通過，3 跳過，0 失敗，約 6.72 秒 |
| 嚴格 Release 定向回歸 | 249 項通過，0 失敗，約 5.34 秒 |
| 嚴格 V2 QA Release 構建 | 通過，約 25.46 秒 |
| 最後修訂的 Release 回歸 | 資料保護、恢復預覽及確認交易 34 項通過，約 1.80 秒 |
| V2 雙向 live | 1 項通過，2 次真實請求，約 4.88 秒；服務返回 `deepseek-flash`，確認後精確重查不增加請求數 |
| Shell 語法 | `bash -n script/build_and_run.sh` 通過 |
| 文檔與差異 | 四份本批文檔的 79 個相對文件鏈接有效；`git diff --check` 通過 |
| 隔離啟動 | 腳本完成；進程存在；該 QA session 日誌 version 2、activeSchemaVersion 2.0.0、previousSchemaVersion 1.0.0、pending 為空、分析仍暫停 |
| Computer Use | `getApp("com.powerpan.WordNote.UITest")` 返回 `cgWindowNotFound`；沒有本批 UI/截圖驗收證據，不推斷鎖屏 |

三個預設跳過項是 V1 live、V2 live 和 opt-in 性能組；本批 V2 live 已另外執行。首次 V2 嚴格編譯發現 DynamicProperty 的 Query 缺少 MainActor 宣告，已修正重跑，不把失敗建置當成通過。

重要回歸包括：值草稿不污染 context；任一批次項失敗全部回滾；舊 revision 不覆寫新內容；資料恢復不提交其他編輯；恢復後先保持暫停、明確恢復才調用分析；多課程導出不退回兼容單課程；確認/精確重查/備份保留來源與查詢事件。

```bash
# 普通構建與完整離線回歸
env RUN_LIVE_DEEPSEEK_TESTS=0 RUN_LIVE_DEEPSEEK_V2_TESTS=0 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

# V2 QA 條件編譯與完整離線回歸
env RUN_LIVE_DEEPSEEK_TESTS=0 RUN_LIVE_DEEPSEEK_V2_TESTS=0 swift test \
  --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

# 隔離 UI 入口，可傳第四個參數重開同一 QA session
./script/build_and_run.sh --ui-v2-fixture populated light

# 已獲本輪授權的受控 live；不可當作一般 CI 預設
env RUN_LIVE_DEEPSEEK_V2_TESTS=1 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors \
  --filter LiveDeepSeekV2QueueTests
```

## 未完成與下一步

1. A04：切換詞條/課程/欄目、關窗的保存/放棄/取消，以及當次運行期安全撤銷。當前草稿保護只覆蓋保存邊界，不能宣稱離頁不丟修改。
2. A05/B01：批量確認預覽、明確關聯/補充、搜索/篩選、下一條及焦點流程。
3. G00/A01/A02/A03：實機淺/深色、多窗口、輸入法、Tab 補全、浮窗焦點計時、恢復確認、CSV 在表格軟件中打開、大庫端到端性能仍需驗證。
4. A01 出口未通過前，不修改普通 App 的 V1 啟動，不遷移真實用戶庫。QA 進展不能替代正式启用閘門。

回退：普通 V1 啟動未改。QA 重開使用同一 session UUID；測試遷移與恢復保留舊 generation 及保護快照，不靠刪除生產資料解決問題。`.build-v2-qa`、`dist` 和臨時 QA 資料不是提交產物。
