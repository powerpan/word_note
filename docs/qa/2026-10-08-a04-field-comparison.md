# A04 三方字段比較與草稿回填

日期：2026-10-08（Asia/Hong_Kong）。基線：`d9d2761`，分支：`codex/supplemental-development`。本批完成隔離 V2 的字段比較入口與核心，不等於 A04 的實機驗收完成。

## 使用範圍

- Term、Course 及候選外部更新後，Compare Changes 在表單中展開 Original / Mine / Stored；只顯示變更字段和版本，窄欄使用縱向排列。
- 不同字段的修改各自保留；同一字段雙方改成同值不算衝突，改成不同值則必須明確選 Mine/Stored。課程集合整體選擇，不自動做聯集。
- Apply to Draft 只回填草稿；Save 才校驗並寫庫。關閉比較保留草稿，Refresh 重新讀取並清空舊選擇；過期預覽不可套用。
- 手動建詞比較的是來源記錄，不是不存在的「正式詞条」。Use Latest Source 不改英文詞頭或釋義，來源已處理/分析中時禁止回填；沒有以來源中文覆蓋英文的路徑。
- 只使用內存或臨時合成 fixture，不讀寫真實詞庫，不啟用生產 V2，不改 schema，不提前執行 README/介紹截圖/全倉機密審計或 App 分發。

## 實作

| 組件 | 行為 |
|---|---|
| [比較核心](../../Sources/WordNoteCore/Domain/Services/WordNoteEditComparison.swift) | 強型別比較與不可變預覽；校驗草稿值、基線、revision，以及重新讀取的庫中值、revision、阻塞狀態；只修改值草稿 |
| [詞條字段](../../Sources/WordNoteCore/Domain/WordNoteTermEditValues.swift) / [課程字段](../../Sources/WordNoteCore/Domain/WordNoteCourseEditValues.swift) | 正式表單使用同一份可測值型資料；12 個 Term 可編輯字段與 5 個 Course 字段都有對比定義，原始捕獲課程不是會員關係編輯字段 |
| [V2 草稿讀取](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2DraftReading.swift) | 恢復屏障與未提交模型保護；按原 ID 查最新值，缺失不重建；Term 會員關係以 TermCourseLink 為準 |
| [候選比較](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2CandidateComparison.swift) | 按候選 ID 對應而非位置；改名不是列表增刪；保留新增 pending 項；原組中任一候選已處理時整次回填被阻止，草稿仍保留；分析中/過期世代阻止回填，原 ID 被刪或跨來源則拒絕 |
| [来源值](../../Sources/WordNoteCore/Domain/WordNoteManualSourceValues.swift) | readonly 原文、筆記、課程、方向、整理與分析狀態；與手動英文/中文草稿分離 |
| [比較 UI](../../Sources/WordNote/Presentation/DraftConflictView.swift) | 行內比較、逐字段選擇、refresh/close 圖標、狀態提示；不搶占離開確認 sheet，不設全局鍵盤捷徑 |

保存後以規範化的正式值刷新 Term/Course 基線。接受比較後即使第三次外部修改發生，正式 Save 的 revision 檢查仍拒絕覆寫。回填不建立撤銷 receipt；後續保存再撤銷，只回到回填前已存在的最新庫中內容，不抹去先前其他操作。

## 自動化

- [比較與字段覆蓋](../../Tests/WordNoteCoreTests/WordNoteEditComparisonTests.swift)：16 項。含不重疊/同值/真正衝突、空字串與空白、顯示名相同但 ID 不同、readonly、未知選擇、僅 revision 變化、最後一次輸入、基線/版本再次變化、阻塞狀態、重複字段 ID、實際表單字段全覆蓋。
- [V2 整合](../../Tests/WordNoteCoreTests/WordNoteV2EditComparisonTests.swift)：13 項。含回填不寫庫、不改 history，保存/撤銷保留外部修改，再次更新擋住保存，課程合併，候選/source revision、重排及新增 ID、已確認/分析中、刪除/跨來源/重複 ID、恢復屏障/直接未保存模型，以及手動來源狀態。

| 驗證 | 結果 |
|---|---|
| 開發中 V2 Debug 定向比較測試 | 29 通過、0 失敗，約 0.17 秒；最後修訂另由以下三组完整回歸覆蓋 |
| 普通 App 嚴格 Debug 全套 | 498 項，495 通過、3 跳過、0 失敗，約 7.54 秒 |
| V2 QA 嚴格 Debug 全套 | 498 項，495 通過、3 跳過、0 失敗，約 7.56 秒 |
| V2 QA 嚴格 Release 全套 | 498 項，495 通過、3 跳過、0 失敗，約 7.09 秒 |
| 編譯與文檔 | 三组最終日志無 warning/error；五份文檔的 96 個相對文件鏈接有效，`git diff --check` 通過 |
| QA 啟動 | 最終測試後重建，合成 session `1693F114-02B3-48EA-856B-DCFC7420D397`；啟動命令成功，`pgrep -x WordNoteQA` 確認進程存在 |
| Computer Use | 本輪前次合成啟動中，一次 `getApp("com.powerpan.WordNote.UITest")` 仍返回 `-10005 cgWindowNotFound`；最終重建未反復重試相同故障，不推測原因，不把進程存在算 UI 通過 |

開發中來源狀態顯示有 Optional.none/AnalysisQueueState.none 歧義，被 warnings-as-errors 擋下；改為明確 nil 分支後重跑，沒有放寬編譯檢查。三個預期跳過項是兩組 opt-in live DeepSeek 和 Release 性能組，本批不改 AI 協議、不重複付費請求。

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
./script/build_and_run.sh --ui-v2-fixture populated light
```

## 剩餘事項

1. 真實主窗口中的窄欄/長文字/明暗主題、字段選擇、刷新、失敗提示、關窗、正常退出和輸入法焦點回歸。QA-02、QA-09 尚不能宣稱完整通過。
2. A05 的 ConfirmationPlan、批內同名詞歸併、已有詞逐字段補充和原子確認，不是本次草稿比較的替代名稱，仍需實作。
3. 大庫字段比較性能本批未實測；UI 目前仍沿用既有表單，A06 閱讀預設與 B08 窗口策略另行推進。
