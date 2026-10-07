# 04. Technical Architecture

版本說明：原章節描述目前架構；文末「2026-10 補充契約」是 [補充計劃](13-supplemental-development-plan.md) 的目標邊界，新增類型名為設計名稱而非已存在 API。

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
  -> if no generation journal, WordNote.store is absent, and legacy default.store exists
       -> copy legacy store + WAL/SHM to unique backup directory
       -> copy into WordNote/WordNote.store
  -> WordNoteRestoreStore reads the generation journal
       -> verify and commit a prepared replacement, or roll back an interrupted activation
  -> open the selected generation using versioned SwiftData schema
  -> apply whitelisted restored preferences and acknowledge durable completion
  -> repair dangling references and orphan rows
  -> set directory 0700 and store files 0600
  -> recover analyzing records only when analysisRequiresResume is false
  -> share WordNoteDataProtection across all windows and the capture panel
  -> observe saves and run automatic backup checks independently of view lifetime
```

舊 `default.store` 永不由遷移器刪除。持久化容器打開失敗時，App 顯示可操作的啟動錯誤頁，只使用記憶體容器承載錯誤 UI，不允許在該狀態下捕獲新資料。

A01 接入已完成代碼和隔離集成測試，完整 UI 驗收仍待補。恢復只能經 `WordNoteDataProtection`：取得同容器寫入屏障、失效舊 AI ticket、持久化分析暫停旗標，建立並驗證當前庫快照後才準備新代。禁止在恢復準備中正常退出；就緒後受控退出，下一次 bootstrap 切庫。失敗時讀取持久日誌決定解除屏障或保持鎖定，不根據單一拋出的錯誤猜測磁碟狀態。

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

## 2026-10 補充契約

### 服務責任與分層

延續 WordNoteCore 與 Presentation 分離，不在這輪更換持久化框架、引入服務端或建立通用插件平台。只在現有服務責任內增加必要協調。

| 邊界 | 責任 | 禁止承擔 |
|---|---|---|
| CaptureCoordinator / 現有 QuickAddAnalysisQueue | 凍結捕獲上下文、保存、精確命中、排隊、恢復/取消/退避；所有入口共用 | 自動確認候選、讀取任意 App 內容 |
| ConfirmationPlanner | 純只讀預檢、重複分類、計數和字段差異 | 提前修改正式模型 |
| VocabularyService | 按預覽 revision 原子確認、關聯、來源/課程寫入，產生 undo receipt | 直接把 AI 原始字串當正式資料 |
| ReviewScheduler | 時間、卡片狀態、反饋 -> 排程結果與按鈕預覽的純函數 | 自行寫資料、調用 AI、讀取系統時鐘全局狀態 |
| ReviewSessionService | 有限隊列、窗口寫入租約、actionID 冪等、事件和卡片同交易保存 | 用頁面生命週期重置會話 |
| BackupService / RestoreCoordinator | 版本化 DTO 快照、校驗、輪替、恢復日誌、啟動前切庫 | 複製正在寫入的 SQLite 三件套作日常備份 |
| AIAnalysisService / RevisionProposal | 帶方向的 schema 解析、候選與建議修訂 | 默認覆寫人工內容或改復習排程 |
| Presentation draft / read model | 未保存編輯、路由、焦點、穩定列表與結果高度 | 跨實體交易、推測錯題數 |

以上可以作為既有服務中的值類型或小型協調器實現；不要求每列都新建大型抽象。依據見 [SwiftData SchemaMigrationPlan](https://developer.apple.com/documentation/swiftdata/schemamigrationplan)：框架提供 schema/stage 契約，但本項目仍須自行驗證歷史資料遷移，不把聲明版本視為遷移已安全。

### 資料流與寫入協調

```text
主窗口 / 浮窗 / Inbox Retry
  -> capture context + operationID
  -> 本地精確查詢
     -> 命中: occurrence + lookup signal -> 已有釋義
     -> 未命中: InputRecord -> 共用 queue -> candidate
  -> read-only confirmation plan
  -> revision check + atomic save
  -> Term + links + occurrences + savedTermID
```

採單一應用級寫入協調器串行化有關聯的交易；不傳遞可變 SwiftData model 穿越不匹配的 actor/context。後台網絡返回 DTO，回到協調器前再次校驗 recordID、analysisGeneration、revision 和 storeGeneration。已取消/刪除/恢復前的回調不能寫進新庫。

持久化 InputRecord 繼續是待分析工作的來源，補充 queued/running/failed/cancelled 的任務狀態與 attemptID，不引入第二份不一致的任務資料庫。失敗有分類：離線、超時、限流、格式、憑據、保存。預設單 worker；可重試的網絡失敗最多自動重試 2 次，遵守 Retry-After 並採有上限退避，格式/鑰匙错误不自動反覆消費。退避上限 60 秒，超過的 Retry-After 保留為下次可手動重試時間，不提前再發。使用者主動重試是新 attempt，不改捕獲上下文。

真正取消 queued 項恢復草稿可再排隊；取消 running 項嘗試終止 URLSession 並阻止舊結果落庫，但不宣稱服務端未執行或不計費。重新分析已完成/部分確認記錄時必須保護 savedTermID，舊候選不在網絡返回前被銷毀。

### 原子性與撤銷

- 確認交易同時寫 Term、候選狀態、savedTermID、課程和 occurrence；任何驗證/保存失敗回到原狀。
- review 交易同時保存 ReviewEvent、ReviewCard、ReviewSessionItem 和會話游標，actionID 唯一；已完成 action 重試返回既有結果。
- revision 是整數版本，不用時間戳替代。計劃/編輯快照攜帶 expectedRevision，失配要求重新讀取並處理衝突。
- 編輯/確認撤銷只在本次 App 運行期提供，receipt 保存受影響 ID、前後 revision 和字段。撤銷前校驗未被後續編輯、正式復習或新來源引用；有衝突拒絕撤銷並說明，不級聯抹除新資料。
- SwiftData autosave 不能使 UI 草稿提前進庫；表單用值副本，正式保存仍經服務預驗證和交易。

### 備份、恢復與啟動

備份取得一致、不可變的 DTO 後才序列化及原子寫文件，不跨 executor 共用可變 ModelContext/model。A01 大庫測量發現 MainActor 全量捕獲會阻塞，因此日常/手動備份改用樂觀一致性讀取：MainActor 先保存當前已修改 context，后台 worker 建自己的唯讀 context，讀取前後同步比較同容器的 willSave/didSave 計數；有任何保存或主 context 待保存修改就丟棄整次讀取並重試，最多三次，仍不穩定則保留舊備份並明確報錯。不能把混合版本或只截取部分實體的結果當成成功快照。

前提是 App 的正式寫入仍由 MainActor 服務串行處理；通知不得延後排入主隊列才計數。新增後台寫入者或另一個寫庫進程時必須重新設計此一致性邊界，不能沿用上述假設。快照 DTO 的同步 adapter 不再強制 MainActor，但呼叫方必須在其 context 所屬 executor 完成全部模型訪問。

恢復仍需要全窗口寫入屏障，按照 [08](08-security-privacy.md) 的 staged store + 恢復日誌實施。建庫、持久化重開驗證和校驗碼計算在后台使用獨立 context，不把它們的模型傳回 UI。worker 完成後回 MainActor 重新讀取 active/pending 日誌，拒絕過期或相競爭的恢復，再寫 prepared；取消不提交 prepared。受控退出後在下一次 ModelContainer 建立前切換，成功後才解除寫入屏障。

每次 schema 改變同時更新 migration、snapshot adapter、刪除/完整性檢查與測試 fixture；先凍結 V1 真實類型形狀，不能讓 V1 指向持續改動的最新類型。V2/V3/V4 的主要寫入切換點見 [05](05-data-model.md)。

2026-10-08 的隔離 V2 基礎不使用在原庫上直接執行的 lightweight migration。`WordNoteV1ToV2Migration` 先檢查完整 V1 DTO，再產生確定性的 V2 值；`WordNoteSnapshotV2Payload` 只允許写入 schema 為 V2 的空庫。完整啟動遷移仍需接入 A01 保護快照、后台建庫/重開比對和恢復日誌，不能單獨改 App 的 typealias 就啟用。

V2 邏輯快照沿用 formatVersion 1 的 checksum envelope，sourceSchemaVersion 為 2.0.0。payload.content 復用凍結的 V1 字段定義，另有按實體 ID 一對一匹配的 revision/捕獲/候選/計數語義元資料表，以及 occurrence、courseLink、lookupEvent 三類實體。缺行、多行、重複業務鍵和錯誤關聯均拒絕恢復。`WordNoteSnapshotReader` 按 schema 路由 V1/V2 讀取器；現行 App vault/coordinator 尚未切換，V1 入口繼續拒絕 V2 文件和 context，防止靜默丟棄新增資料。

### 窗口與性能

全局快捷鍵封裝在單一 AppKit 適配器，只接受已註冊組合鍵；先验证 macOS 14 的可用機制，不預先要求輔助功能或全鍵盤監聽。保持 SwiftUI 命令、菜單欄和浮窗路由一致。

搜索 matcher、補全與精確去重仍分開；列表按穩定 ID 更新，不因篩選改變錯配選中項。性能先測現有查詢與生成資料，再決定索引/分頁/搜索快取；不能為預估大資料量先引入向量庫。時計、Calendar、網絡、store 路徑和偏好可注入，測試不用 sleep 等待真實 10 分鐘。
