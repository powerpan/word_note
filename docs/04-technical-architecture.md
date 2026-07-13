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
| State | Observation state + domain services |
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
- 可用 SwiftData `@Query` 做只讀列表查詢；所有跨實體寫入必須通過 domain service，以保證原子性和級聯規則。

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

- `createDraft(rawText, courseID, sourceType, note)`
- `createAnalyzing(rawText, courseID, sourceType, note)`
- `applyAnalysisResult(result, record)`
- `markFailed(record, summary)`
- `ignore(record)`
- `delete(record)`，按規則級聯候選並清空正式詞條來源引用

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
- 使用 `AppStorage` / `UserDefaults` 持久化 `system | light | dark` 外觀偏好；未知舊值回退為 `system`。
- 將同一外觀偏好套用到 WindowGroup、Settings Scene 和獨立 NSHostingView Quick Add 浮窗。
- test API connectivity。

### QuickAddAnalysisQueue

職責：

- 將每次 Save & Analyze 先持久化為 `InputRecord.status = analyzing`。
- 主窗口和菜單欄浮窗共用同一個進程內協調器。
- 依序處理多個請求，單次失敗不阻塞後續項目。
- App 啟動時恢復仍為 `analyzing` 的記錄。
- 同一 normalizedText 已在分析中時直接返回既有排隊記錄，不重複調用 AI。
- 使用 `LookupDirectionDetector` 識別方向；中文查英文跳過英文 term 的 duplicate short circuit，但仍沿用同一持久化隊列與恢復流程。
- 中文查英文完成後把英文 candidates 寫入既有 CandidateTerm/Inbox 流程，不直接建立 Term。

### LookupDirectionDetector

職責：

- 統計 rawText 中 CJK Han scalar 與 ASCII 英文字母，漢字非零且不少於英文字母時判定為 `chineseToEnglish`。
- 無漢字、英文佔主導或空輸入時使用既有 `englishToChinese` 流程。
- 提供英文詞本主體校驗：至少包含一個 ASCII 英文字母且不能包含漢字。

方向只由原始輸入確定，不新增 SwiftData 字段；Inbox、重試和 App 重啟恢復時可由 `InputRecord.rawText` 得到相同結果。

### Chinese-to-English Result Guard

`AIAnalysisService` 在解析 JSON 後只保留英文 `term` 且具有 `chineseMeaning` 的候選。`VocabularyService` 在 Candidate Review 和手動加入時再次校驗，防止用戶編輯或替代分析器把中文查詢保存為詞本主體。

### VocabularyCompletionMatcher

職責：

- 接收當前原始輸入和正式詞庫詞條文本，返回至多一個補全結果。
- 只做大小寫不敏感的 anchored prefix match，不做 substring 或編輯距離模糊匹配。
- 排除空輸入、少於 2 個字符、包含換行、已完整匹配和沒有剩餘後綴的候選。
- 優先選擇剩餘後綴最短的候選，長度相同時按穩定字母順序選擇。
- 保留用戶已輸入文本，只追加正式詞條中的剩餘後綴。

匹配器屬於 `WordNoteCore` 純邏輯，不依賴 SwiftUI、AppKit、SwiftData 或網絡。Presentation 層只把 `Term.term` 快照傳入匹配器。

### VocabularySearchMatcher

職責：

- 對英文 term 和 englishDefinition 保持 normalized、大小寫不敏感的 contains 搜索。
- 對查詢和 chineseMeaning 使用 ICU `Hant-Hans` 統一為簡體搜索鍵。
- 中文搜索鍵移除空白、標點和符號後執行子串匹配。
- 空查詢匹配全部；只有標點的非空查詢不能退化成匹配全部。

搜索 matcher 屬於 `WordNoteCore` 純邏輯。它不改寫持久化資料，也不與 duplicate detection、Quick Add completion 或 AI 請求共用模糊規則。

## 依賴方向

依賴只能向內：

```text
Views -> Observation state / Services -> SwiftData Models / Infrastructure Clients
```

純排程與規範化規則不依賴 SwiftUI。現階段 domain services 使用 SwiftData `ModelContext` 作為交易邊界；若後續引入同步後端，再抽取 repository protocol。

## 資料流：Save & Analyze

```text
QuickAddView
  -> QuickAddAnalysisQueue.enqueue()
  -> LookupDirectionDetector.detect(rawText)
  -> if englishToChinese:
       -> VocabularyService.findExactTerm(normalized(rawText))
  -> if englishToChinese and existing Term:
       -> VocabularyService.bumpDuplicateHit(term)
       -> QuickAddAnalysisQueue.latestAIExplanation = existing term preview
       -> stop, no DeepSeek request
  -> InputRecordService.createAnalyzing()
  -> return immediately to UI
  -> queue worker: AIAnalysisService.analyze(rawText, metadata)
  -> DeepSeekClient.send()
  -> AIResponseParser.decode()
  -> CandidateRepository.insertMany()
  -> InputRecordRepository.update(status=analyzed)
  -> Inbox exposes analyzed record for confirmation
```

精確命中規則：

- 只在 `englishToChinese` 方向執行；`chineseToEnglish` 必須進入 AI 分析與 Inbox 確認。
- 只比較 normalized(rawText) 和 Term.normalizedTerm。
- 不做包含匹配、模糊匹配或 stemming。
- 輸入句子包含既有詞條時仍走 DeepSeek，因為句子可能包含新詞或新的上下文。
- 命中時不創建 InputRecord，避免 Inbox 被重複查詞污染。

## 資料流：Save Selected Candidates

```text
CandidateReviewView
  -> VocabularyService.confirmCandidates(selections)
  -> ReviewService.initialize(term)
  -> CandidateRepository.markSaved()
  -> InputRecordService.updateCompletionStatus()
```

批量確認必須先驗證全部選項，再在一次 `ModelContext.save()` 中建立 Term、更新 CandidateTerm 與 InputRecord。任一項失敗時整批不落盤。

## 持久化啟動流程

```text
prepare private app directory
  -> if WordNote.store is absent and legacy default.store exists
       -> copy legacy store + WAL/SHM to unique backup directory
       -> copy into WordNote/WordNote.store
  -> open versioned SwiftData schema
  -> repair dangling references and orphan rows
  -> set directory 0700 and store files 0600
  -> recover analyzing records into the queue
```

舊 `default.store` 永不由遷移器刪除。持久化容器打開失敗時，App 顯示可操作的啟動錯誤頁，只使用記憶體容器承載錯誤 UI，不允許在該狀態下捕獲新資料。

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

## 資料流：Vocabulary Input Completion

```text
QuickAddView / FloatingQuickAddPanel
  -> SwiftData @Query loads Term.term snapshot
  -> AppKit completion editor observes text and selection
  -> VocabularyCompletionMatcher.bestCompletion(input, terms)
  -> editor draws suffix as non-editable gray ghost text
  -> Tab accepts completion into rawText
  -> Enter / Save remains the only submit action
```

AppKit bridge 只處理文本選區、ghost text 繪製和 Tab/Escape 鍵。候選排序留在可單元測試的 core matcher；橋接不得直接讀取 ModelContext 或觸發 QuickAddAnalysisQueue。

`NSTextView.hasMarkedText()` 為按鍵路由的最高優先級。輸入法組合期間所有按鍵先交回 AppKit 文本系統；只有 marked text 已提交後，bridge 才可攔截 Tab 補全、Escape 隱藏或單行 Enter 提交。

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

已實作 `MenuBarExtra` 和 AppKit 浮動 panel，與主窗口共用 `QuickAddAnalysisQueue`。panel 只負責窗口生命週期、置頂和焦點事件，資料寫入仍由 domain services 完成。

### Global Hotkey

目前只有 App 內 `Command-Shift-N`；真正的系統全局快捷鍵仍需單獨處理權限和衝突。

### Export

P1 可從 VocabularyService 和 CourseService 導出 JSON/CSV，不應直接讀 SwiftData model 拼接文件。

### Sync

P2 若做 iCloud，需要先制定資料衝突策略，不能直接把本地模型簡單同步。
