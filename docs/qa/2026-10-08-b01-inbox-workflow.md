# B01 Inbox 決策工作流

日期：2026-10-08（Asia/Hong_Kong）。基線：`1969e5e`，分支：`codex/supplemental-development`。對應 QA-14、QA-15，以及本批擴展的 QA-09 忽略撤銷。

## 範圍

- 新界面僅在 `WORDNOTE_V2_VALIDATION` 啟用，普通 V1 App 不變；不激活正式遷移，不讀寫真實詞庫。
- 不改 schema、快照格式或 AI 契約。單測使用內存合成資料，原生 UI 使用臨時 populated fixture；QA 的 analysis handler 為離線 stub。
- 本輪沒有 DeepSeek 請求，未執行 C06 的 README 重寫、介紹截圖或全倉敏感資訊審計；不做 App 分發。

## 實作

| 入口 | 行為 |
|---|---|
| [InboxBrowseIndex](../../Sources/WordNoteCore/Domain/InboxBrowseIndex.swift) | 不可變記錄/候選值投影；簡繁中文和英文全文鍵、捕獲課程/來源/狀態交集；18 Character 摘要、輸入/候選分計數 |
| [InboxSelection](../../Sources/WordNoteCore/Domain/InboxSelection.swift) | 可見可處理 ID 批選、切範圍清選、原列表後鄰優先的焦點；候選推薦只初始化一次 |
| [V2InboxView](../../Sources/WordNote/Presentation/V2InboxView.swift) / [Filters](../../Sources/WordNote/Presentation/V2InboxFilters.swift) | 獨立分析任務、可搜尋列表、默認折疊 Handled；根視圖持有 A05 確認 sheet，避免詳情切換導致預覽消失 |
| [InputRecordDetail](../../Sources/WordNote/Presentation/V2InputRecordDetailView.swift) / [CandidateReview](../../Sources/WordNote/Presentation/V2CandidateReviewView.swift) | 默認閱讀、原文/元資料按需展開、單條/批量保存關聯、忽略、手動建詞、展開編輯 |
| [CandidateReadingRow](../../Sources/WordNote/Presentation/V2CandidateReadingRow.swift) / [DraftEditor](../../Sources/WordNote/Presentation/V2CandidateDraftEditor.swift) | 英文主體與完整中文、技術義/英文/例句 Disclosure；A04 值草稿及離頁保護保留 |
| [Ignore candidates](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2CandidateSelection.swift) / [Ignore record](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2Editing.swift) / [UndoApply](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2UndoApply.swift) | 整理忽略接入單步安全撤銷；恢復任務狀態/等待時間但 revision 繼續增加 |
| [AnalysisTasks](../../Sources/WordNote/Presentation/V2AnalysisTasksView.swift) | running 取消先提示可能計費，凍結提示時的 job revision，再交原隊列校驗 |

### 狀態口徑

`completed` 表示候選全已處理，包含全忽略，故折疊區稱 Handled 而非 Confirmed；其內容只在 All 下按相同文字/課程/來源篩選。Pending 表示有未處理候選，Failed 表示分析失敗，兩者可以重疊。Drafts 為無 pending 且非失敗的 draft，包含取消後空草稿。queued/running 不在主列表，ignored 輸入不在主列表。

英查中摘要顯示中文，中查英依已凍結的方向顯示英文候選；最多 18 個 Swift Character，先選 pending 的非空釋義，再取已處理候選/句意/狀態，不截斷完整資料。中文搜索也包含原文、備註、句意及候選中英文定義。

批量確認前在未保存編輯保護之後重新讀取 revision/generation，要求全部原選中 ID 仍可見可處理；不能將過期範圍靜默縮小。單候選同樣先預覽；部分處理保留當前記錄，全部處理選原後鄰、原前鄰，最後才回退首項。新到記錄不搶焦點，Undo 返回的記錄也不奪走仍有效的當前選擇。

確認舊候選不抹掉失敗的重新分析任務，因為整理與分析是獨立狀態軸。整條 ignore 清除非運行中任務，Undo 必須還原原失敗/取消及 provider deadline，不得藉此繞過等待時間或自動重發付費請求。

## 回歸測試

新增 34 項：

| 測試 | 數量 | 覆蓋 |
|---|---|---|
| [InboxBrowseIndexTests](../../Tests/WordNoteCoreTests/InboxBrowseIndexTests.swift) | 13 | 簡繁/英文字段、交集、pending/failed 重疊、draft/cancelled、排隊分離、Handled、18 字/字素/凍結方向、不可變值、世代、範圍計數及穩定排序 |
| [InboxSelectionTests + InboxCandidateSelectionTests](../../Tests/WordNoteCoreTests/InboxSelectionTests.swift) | 10 | 部分/全部處理、新到項、撤銷回流、篩選清批選、僅可見全選、折疊焦點、推薦初始化及用戶清空/新候選保留 |
| [WordNoteV2InboxWorkflowTests](../../Tests/WordNoteCoreTests/WordNoteV2InboxWorkflowTests.swift) | 11 | 忽略/撤銷、既有關係不變、failed/cancelled/deadline、保存失敗全回滾、上一張 receipt 保留、stale/no-op、後續分析/引用拒絕、dirty/restore/queue 屏障、A05 與下一條整合 |

先執行新增 34 項測試，僅 `testUndoRecordIgnoreRestoresFailureOrCancellationAndProviderDeadline` 失敗，兩種狀態合計 8 個斷言復現缺陷：Undo 後 queue 仍為 none、deadline 為 nil，且原本應被延後的重試被放行。修正 `applyUndo` 還原 RecordState 後，新增 34 項加既有 31 項 Undo 測試全部通過，沒有放寬預期或嚴格編譯選項。

| 最終驗證 | 結果 |
|---|---|
| 普通 V1 嚴格 Debug 全套 | 620 項，616 通過、4 跳過、0 失敗 |
| V2 QA 嚴格 Debug 全套 | 620 項，616 通過、4 跳過、0 失敗 |
| V2 QA 嚴格 Release 全套 | 620 項，616 通過、4 跳過、0 失敗 |
| 定向 Inbox + Undo | 65 項，全部通過 |

4 個跳過項為兩組 opt-in live DeepSeek 與兩組 opt-in 性能測試；本批不借用舊性能數字作 Inbox UI 延遲證據。嚴格模式為 complete concurrency、warn-concurrency、warnings-as-errors，最終測試日誌沒有 warning/error。QA 構建成功，普通 App 未切換 V2。六份變更文檔的 130 個相對文件鏈接有效，`git diff --check` 通過。

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
./script/build_and_run.sh --ui-v2-fixture populated light
```

## 原生 UI 核對

本輪 Computer Use 一度恢復可用，不沿用前批 cgWindowNotFound 推斷。全部操作限定 `Word Note V2 QA`，無真實詞庫。兩次 session：

- `6FB0D641-B62F-452B-B6B2-12F19A86A8DD`：工作流核對，發現更多菜單橫向過度拉伸及失敗狀態重複兩次。
- `775D38A2-AC9B-49E0-9FF2-CBC3C4E4BD83`：修正並重建後的新 fixture；更多菜單固定圖標寬度，失敗提示只出現一次。

通過當次 AX 及實際畫面確認：

1. 默認候選閱讀顯示英文主體和完整中文，單候選匹配既有詞顯示 Link，未匹配顯示 Save。
2. 全選由 3 active 中選 2 條可確認輸入，計數 3 個候選，不把無候選失敗項算進來。
3. 搜索「吞吐」剩下一條句子並清除批選；候選詳情保留 quick、throughput 兩個 ID，不因匹配命中其中一個而丟棄另一個。
4. 修改 quick 中文草稿後用真實鍵盤改搜索，觸發 Save/Discard/Cancel；Cancel 保留原「吞吐」搜索和草稿。保存後返回閱讀能顯示新值，Undo 標題是 Edit Candidates。
5. 點 quick 的 Link 打開單候選 A05 預覽，顯示 1 record/1 candidate、既有值默認 Keep stored；提交後仍在同一輸入，剩 throughput，Handled Candidates 收起。
6. 清搜索後忽略最後 throughput，自動移到原後鄰 bounded queue；整條進默認折疊 Handled。Undo Ignore Candidates 恢復待確認候選，但仍聚焦 bounded queue。
7. 最終重建畫面已修正菜單和重複提示；拖窄窗口後側欄切圖標模式，列表/釋義/操作無可見重疊。觀察到的截图栅格為 2498x1600 和 1964x1464；後者對應約 980 點寬、680 點內容高度，不宣稱所有計劃尺寸均已覆蓋。
8. 緊湊窗口全選的預覽顯示 2 records/3 candidates、1 new term/2 links；滾動可見第三候選 throughput。提交後顯示 1 active/2 handled，Handled 默認收起，展開可查看兩条已處理輸入。

最後一組「撤銷批量確認並前往 Settings」操作返回 `Sky Computer Use native pipe closed before response`，之後一次重新取得 App 仍同錯誤；無法確定該組操作完成到哪一步，未算通過，沒有反復重試或改用其他 UI 技術。

## 尚待驗收

- 深色主題、精確 1320x800/1920x1080 等完整尺寸矩陣、長詞頭/多行內容極限和 VoiceOver。
- 原生課程/來源/狀態 picker 的組合交互、鍵盤遍歷、篩選後多窗口競爭及恢復屏障時的交互；核心已覆蓋不等於 UI 全通過。
- running 取消提示與結果競態、離線/429/重啟後任務的原生顯示；本 fixture handler 即時返回，不能用它冒充慢網絡窗口驗證。
- 批量確認後的原生 Undo、跨窗口錯誤和刷新預覽，以及剩餘 A04/A05/A06 的實機清單。

本批為代碼與核心回歸里程碑，B01 不因此標記完全驗收。後續繼續 B02，不因局部 UI 工具中斷停掉可獨立完成的開發；README/對外截圖/完整敏感資訊審計仍在 C06 收尾。
