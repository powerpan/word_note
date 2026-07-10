# 10. Implementation Plan

## 開發策略

採用垂直切片，而不是先把所有 UI 或所有資料模型一次寫完。每個里程碑都應該能運行、能保存資料、能被手工驗收。

截至 2026-07-10，M1-M7、P1-A、P1-B、P1-C 和下列可靠性加固均已落地。後續變更應維持本文件定義的資料一致性與測試門檻。

## M1: Project Foundation

目標：建立可運行的 macOS App 骨架和基礎資料層。

任務：

- 建立 SwiftUI macOS project。
- 設定 bundle id、最低 macOS 版本。
- 建立 SwiftData container。
- 建立基本 model：Course、InputRecord、CandidateTerm、Term、ReviewEvent。
- 建立 repository protocol 和 SwiftData implementation。
- 建立 app navigation shell。
- 建立基礎錯誤和 loading state。

完成標準：

- App 可啟動。
- 可建立和查詢 Course。
- 可建立和查詢 Term。
- 基礎資料測試通過。

## M2: Quick Add And Inbox

目標：用戶可以保存原始輸入，並在 Inbox 查看。

任務：

- QuickAddView。
- QuickAddViewModel。
- InputRecordService.createDraft。
- course/source/note 選擇。
- Inbox list。
- InputRecord detail。
- draft/ignored/delete 流程。

完成標準：

- 只輸入 raw text 可保存。
- 重啟 App 後 InputRecord 仍存在。
- Inbox 正確展示 draft 和 ignored 以外的記錄。

## M3: AI Integration

目標：接入 DeepSeek 解析並保存候選。

任務：

- Settings API Key UI。
- DeepSeekEnvironmentFileStore。
- DeepSeekClient。
- AIAnalysisService。
- prompt builder。
- response parser。
- CandidateTerm persistence。
- failed status 和 retry。

完成標準：

- 三個標準樣例可解析。
- API Key 缺失時可保存 draft，不崩潰。
- 網絡錯誤時 InputRecord.status = failed。
- JSON 錯誤時可重試。

## M4: Candidate Review To Vocabulary

目標：用戶能從 AI 候選建立正式詞條。

任務：

- CandidateReviewView。
- 候選勾選和編輯。
- VocabularyService.createTerms。
- duplicate detection。
- CandidateStatus saved/ignored。
- InputRecord completion status。
- Vocabulary list/detail/edit/delete。

完成標準：

- 保存候選後 Vocabulary 出現 Term。
- 編輯 Term 後持久化。
- 刪除 Term 後列表更新。
- 重複詞條有提示。

## M5: Courses And Filters

目標：課程管理和基本篩選可用。

任務：

- Courses list。
- Course create/edit。
- Course referenced delete guard。
- Vocabulary course filter。
- Vocabulary mastery filter。
- Dashboard 顯示課程和未整理摘要。

完成標準：

- Term 可綁定課程。
- 課程下詞條數正確。
- 被引用 Course 不能直接刪除。

## M6: Review Loop

目標：完成最小復習閉環。

任務：

- ReviewService。
- review scheduler。
- due terms query。
- ReviewView。
- ReviewEvent persistence。
- Term review counters update。
- Dashboard today due count。

完成標準：

- 新增 Term 出現在今日待復習。
- 完成復習後 nextReviewAt 按規則更新。
- ReviewEvent 被保存。

## M7: QA And Release Polish

目標：達到 MVP 可日常使用。

任務：

- 空狀態。
- 錯誤提示文案。
- loading 狀態。
- API timeout 配置。
- 日誌脫敏。
- 單元測試補齊。
- 手動回歸。
- README 更新。

完成標準：

- MVP Release Gate 全部通過。
- 文檔與實作一致。
- 已知限制記錄清楚。

## P1-A: Duplicate Quick Add Hit

狀態：已完成。

目標：用戶再次輸入已存在詞條時，不再調用 DeepSeek，而是直接進入學習回路。

任務：

- VocabularyService.findExactTerm(normalizedTerm)。
- VocabularyService.bumpDuplicateHit(term, now)。
- QuickAddAnalysisQueue 在 enqueue 前查正式 Term。
- 將 existing Term 組裝成 AIExplanationPreview，復用主窗口和浮窗釋義顯示。
- duplicateHitCount、lastDuplicateHitAt、correctStreak、reviewIntervalDays schema migration。
- 10 分鐘冷卻窗口，防止 wrongCount 被短時間重複輸入刷高。

完成標準：

- 精確命中 Term 時不建立 InputRecord。
- 精確命中 Term 時不調用 DeepSeek。
- 主 Quick Add 和浮窗都立即顯示已有釋義。
- 命中後 Term.nextReviewAt = now。
- importance 最多提升一級。
- wrongCount 冷卻窗口外才 +1。

## P1-B: Review Experience Upgrade

狀態：已完成。

目標：把 Review 從固定間隔卡片升級為可日常使用的學習回路。

任務：

- ReviewMode selector。
- 中文 -> 英文卡片。
- Review keyboard shortcuts：space, 1, 2, 3, 4。
- Skip / Later。
- Review session state。
- 完成頁統計 again/hard/good/easy。
- 錯題 / 薄弱詞入口。

完成標準：

- 用戶可選英文 -> 中文或中文 -> 英文。
- 快捷鍵不干擾文本輸入。
- Skip 不更新 Term。
- Later 將 nextReviewAt 推遲到明天。
- 完成頁能展示本輪統計。

## P1-C: Simplified Adaptive Scheduler

狀態：已完成。

目標：用透明規則替代固定 1/3/7/14 天，但不引入完整 SM-2 / FSRS。

任務：

- ReviewScheduler 支持 correctStreak 和 reviewIntervalDays。
- good/easy 根據 streak 漸進拉長間隔。
- again/hard 重置 streak 並縮短間隔。
- ReviewEvent 保存調整前後 nextReviewAt。
- 補遷移和單元測試。

完成標準：

- 新詞第一次 good 不直接跳到 7 天。
- 連續答對會逐步拉長間隔。
- again/hard 會明確降低掌握度並提前復習。
- 單元測試覆蓋所有 feedback 和 streak 分支。

## Reliability Hardening

狀態：已完成。

交付內容：

- SwiftData schema 顯式版本化，舊 `default.store` 安全備份並遷移到私有固定路徑。
- 啟動時修復孤兒記錄與懸空引用，持久化失敗顯示恢復頁而不是直接崩潰。
- AI 佇列以 analyzing InputRecord 作為持久化事實來源，支持重啟恢復、排隊去重和單筆失敗隔離。
- AI 重試候選替換、InputRecord/Term 級聯刪除、Term 全局去重和批量確認原子性。
- DeepSeek 請求契約、輸入上限、live 測試顯式閘門和 strict concurrency build gate。
- Inbox 批量確認、手動建詞、危險刪除確認、響應式三欄佈局與可訪問性標籤。

完成標準：

- 舊 store 遷移測試證明資料保留、備份存在且不覆寫新 store。
- 全部單元與整合測試通過。
- warnings-as-errors 和 Swift 6 complete concurrency warnings-as-errors 建置通過。
- App bundle 啟動及實際本機 store 遷移後資料完整性驗證通過。

## 推薦目錄結構

```text
WordNote/
  WordNoteApp.swift
  Presentation/
    Dashboard/
    QuickAdd/
    Inbox/
    CandidateReview/
    Vocabulary/
    Review/
    Courses/
    Settings/
  Domain/
    Entities/
    Services/
    UseCases/
    Validation/
  Data/
    Models/
    Repositories/
    Migrations/
  Infrastructure/
    AI/
    Configuration/
    Logging/
    Export/
  Shared/
    Components/
    Extensions/
    Errors/
WordNoteTests/
WordNoteUITests/
```

## 開發順序建議

1. 先完成資料模型和 mock repository。
2. 用 mock AI 做 Quick Add -> Candidate Review -> Vocabulary 閉環。
3. 再接入真實 DeepSeek。
4. 最後補 Review 和 polish。
5. P1 先做 Duplicate Quick Add Hit，因為它能立刻降低 AI 成本並提升復習價值。
6. 再做 Review mode / keyboard / session 統計。
7. 最後替換固定排程為簡化自適應排程。

這樣可以避免一開始被 API 不穩定或本機 secrets 文件細節拖慢。

## 分支策略

在個人項目早期可以簡化：

- `main` 保持可運行。
- 每個里程碑用短分支，例如 `m1-foundation`。
- 合併前跑測試。

如果只有本地個人開發，也可以直接在 `main` 小步提交，但每次提交應保持可回退。

## 提交粒度

建議提交：

- docs: add engineering docs
- chore: create macos project
- feat: add swiftdata models
- feat: add quick add draft flow
- feat: add ai analysis service
- feat: add candidate review
- feat: add vocabulary crud
- feat: add review scheduler
- test: cover ai parser and review scheduler
- feat: skip ai for duplicate quick add terms
- feat: add review mode selector and shortcuts
- feat: add adaptive review scheduler

## 風險與緩解

| 風險 | 影響 | 緩解 |
|---|---|---|
| AI JSON 不穩定 | 候選無法保存 | parser 容錯、schema validation、retry |
| P0 範圍膨脹 | 延期 | 嚴格按 MVP 文檔執行 |
| SwiftData 遷移問題 | 用戶資料風險 | 早期保守模型、遷移前導出 |
| API Key 泄漏 | 安全問題 | env 文件忽略、日誌脫敏、測試 |
| UI 過度設計 | 延誤核心閉環 | 先做密集、清楚的工作台式界面 |

## 歷史 P1 啟動條件

下列條件已滿足並已進入 P1；保留作為後續大階段啟動門檻的參考：

- P0 閉環可日常使用。
- AI 失敗和重試穩定。
- 用戶已累積至少一批真實詞條。
- 已確認最常用入口需要菜單欄快速輸入；系統全局快捷鍵仍未實作。
