# 04. Technical Architecture

## 技術目標

首版架構應滿足：

- 原生 macOS 體驗。
- 本地資料可靠保存。
- AI 服務可替換、可測試。
- UI、業務邏輯、資料存取、網絡請求邊界清楚。
- 支持後續菜單欄、全局快捷鍵、導出和同步擴展。

## 推薦技術棧

| 層 | 推薦 |
|---|---|
| UI | SwiftUI |
| App lifecycle | SwiftUI App |
| Persistence | SwiftData |
| Networking | URLSession + async/await |
| Secrets | 本機 env 文件 |
| State | ViewModel + service protocols |
| Tests | XCTest |
| Platform | macOS 14+ |

如果必須支持 macOS 13 或更早版本，持久化方案需要改為 Core Data 或 SQLite/GRDB。

## 分層架構

```text
WordNoteApp
  -> Presentation
      -> SwiftUI Views
      -> ViewModels
  -> Domain
      -> Entities
      -> Use Cases
      -> Review Scheduler
      -> Validation
  -> Data
      -> SwiftData Models
      -> Repositories
      -> Migrations
  -> Infrastructure
      -> DeepSeek Client
      -> Environment File Store
      -> Exporter
      -> Logger
```

## 模塊邊界

### Presentation

職責：

- 顯示頁面。
- 接收用戶操作。
- 展示 loading、empty、error、success states。
- 不直接拼接 AI prompt。
- 不直接操作 env 文件。
- 不直接寫 SwiftData，通過 use case 或 repository。

### Domain

職責：

- 定義核心業務概念。
- 執行狀態流轉。
- 驗證資料。
- 安排復習時間。
- 去重和規範化規則。

### Data

職責：

- SwiftData model。
- query。
- create/update/delete。
- 資料遷移。
- 本地索引和排序。

### Infrastructure

職責：

- DeepSeek API 請求。
- JSON decode 和容錯。
- env 文件存取。
- 日誌。
- 文件導出。

## 主要服務

### InputRecordService

職責：

- createDraft(rawText, course, sourceType, note)
- saveAndAnalyze(...)
- resolveExistingTerm(rawText)
- markAnalyzing(recordID)
- markAnalyzed(recordID, candidates)
- markFailed(recordID, error)
- ignore(recordID)
- delete(recordID)

### AIAnalysisService

職責：

- build request。
- call DeepSeek client。
- validate response。
- convert response to CandidateTerm。
- return structured errors。

### VocabularyService

職責：

- create Term from CandidateTerm。
- manual create Term。
- update Term。
- delete Term。
- search and filter。
- duplicate detection。
- exact lookup by normalizedTerm。
- bump existing Term after duplicate Quick Add hit。

### CourseService

職責：

- course CRUD。
- prevent deleting referenced course unless reassigned。

### ReviewService

職責：

- load due terms。
- record review feedback。
- update review counters。
- compute nextReviewAt。
- promote existing Term into due queue when duplicate input is detected。
- support P1 review modes and simplified adaptive scheduling。

### SettingsService

職責：

- env 文件 API Key 存取。
- default course/source。
- test API connectivity。

## 依賴方向

依賴只能向內：

```text
Views -> ViewModels -> UseCases/Services -> Repositories/Clients
```

Domain 不依賴 SwiftUI、SwiftData、URLSession 或 env 文件。

## 資料流：Save & Analyze

```text
QuickAddView
  -> QuickAddViewModel.saveAndAnalyze()
  -> VocabularyService.findExactTerm(normalized(rawText))
  -> if existing Term:
       -> VocabularyService.bumpDuplicateHit(term)
       -> QuickAddViewModel.showExistingExplanation(term)
       -> stop, no DeepSeek request
  -> InputRecordService.create(status=analyzing)
  -> AIAnalysisService.analyze(rawText, metadata)
  -> DeepSeekClient.send()
  -> AIResponseParser.decode()
  -> CandidateRepository.insertMany()
  -> InputRecordRepository.update(status=analyzed)
  -> CandidateReviewView opens record
```

精確命中規則：

- 只比較 normalized(rawText) 和 Term.normalizedTerm。
- 不做包含匹配、模糊匹配或 stemming。
- 輸入句子包含既有詞條時仍走 DeepSeek，因為句子可能包含新詞或新的上下文。
- 命中時不創建 InputRecord，避免 Inbox 被重複查詞污染。

## 資料流：Save Selected Candidates

```text
CandidateReviewView
  -> CandidateReviewViewModel.saveSelected()
  -> VocabularyService.createTerms(from candidates)
  -> ReviewService.initialize(term)
  -> CandidateRepository.markSaved()
  -> InputRecordService.updateCompletionStatus()
```

## 資料流：Duplicate Quick Add Hit

```text
QuickAddView / FloatingQuickAddPanel
  -> QuickAddAnalysisQueue.enqueue(rawText)
  -> TextNormalizer.normalized(rawText)
  -> VocabularyService.findExactTerm(normalizedTerm)
  -> VocabularyService.bumpDuplicateHit(term, now)
  -> latestAIExplanation = preview built from Term
  -> UI displays existing explanation immediately
```

`bumpDuplicateHit` 必須是原子資料更新：

- `nextReviewAt = now`。
- 若 `masteryLevel` 為 familiar/mastered，降為 vague；new/vague 保持不提高。
- `importance` 最高提升一級。
- `duplicateHitCount += 1`。
- `lastDuplicateHitAt = now`。
- `wrongCount` 只在超過冷卻窗口時 +1，避免短時間重複輸入刷高錯題統計。

## 錯誤模型

建議定義 typed errors：

```swift
enum AppError: Error {
    case validation(ValidationError)
    case persistence(PersistenceError)
    case ai(AIError)
    case settings(SettingsError)
}

enum AIError: Error {
    case missingAPIKey
    case network
    case timeout
    case rateLimited
    case invalidResponse
    case schemaMismatch
    case emptyCandidates
}
```

UI 不應直接顯示底層錯誤原文。應映射成可理解、可行動的提示。

## 日誌原則

可以記錄：

- request id。
- status code。
- latency。
- input length。
- candidate count。
- error type。

不記錄：

- API Key。
- 完整 request body。
- 完整 AI response。
- 用戶原始輸入的全文，除非用戶顯式導出調試包。

## 配置

首版配置：

- API base URL，可在 Debug build 開放。
- model name。
- timeout seconds。
- max tokens。
- default course id。
- default source type。

API Key 存在本機 env 文件或進程環境變量，不進入 SwiftData、日誌或導出文件。

## 後續可擴展點

### Menu Bar

P1 可增加 MenuBarExtra，復用 QuickAddViewModel 和 InputRecordService。

### Global Hotkey

P1 可增加全局快捷鍵，需單獨處理權限和衝突。

### Export

P1 可從 VocabularyService 和 CourseService 導出 JSON/CSV，不應直接讀 SwiftData model 拼接文件。

### Sync

P2 若做 iCloud，需要先制定資料衝突策略，不能直接把本地模型簡單同步。
