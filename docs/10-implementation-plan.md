# 10. Implementation Plan

## 開發策略

採用垂直切片，而不是先把所有 UI 或所有資料模型一次寫完。每個里程碑都應該能運行、能保存資料、能被手工驗收。

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

## 風險與緩解

| 風險 | 影響 | 緩解 |
|---|---|---|
| AI JSON 不穩定 | 候選無法保存 | parser 容錯、schema validation、retry |
| P0 範圍膨脹 | 延期 | 嚴格按 MVP 文檔執行 |
| SwiftData 遷移問題 | 用戶資料風險 | 早期保守模型、遷移前導出 |
| API Key 泄漏 | 安全問題 | env 文件忽略、日誌脫敏、測試 |
| UI 過度設計 | 延誤核心閉環 | 先做密集、清楚的工作台式界面 |

## P1 啟動條件

只有滿足以下條件才進入 P1：

- P0 閉環可日常使用。
- AI 失敗和重試穩定。
- 用戶已累積至少一批真實詞條。
- 已確認最常用入口確實需要菜單欄或全局快捷鍵。
