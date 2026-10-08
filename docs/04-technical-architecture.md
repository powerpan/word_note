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
  -> inspect dangling references without changing data; stop with a storage issue if found
  -> apply whitelisted restored preferences and acknowledge durable completion
  -> set directory 0700 and store files 0600
  -> recover analyzing records only when analysisRequiresResume is false
  -> share WordNoteDataProtection across all windows and the capture panel
  -> observe saves and run automatic backup checks independently of view lifetime
```

舊 `default.store` 永不由遷移器刪除。持久化容器打開失敗時，App 顯示可操作的啟動錯誤頁，只使用記憶體容器承載錯誤 UI，不允許在該狀態下捕獲新資料。

完整性檢查也採相同失敗關閉策略：V1 啟動不再先刪孤立候選/復習事件、再等日常備份觸發。`validateBeforeOpening` 只返回帶 ID 的問題報告或通過，不清外鍵、不刪行；問題庫保留原樣。成功選定 generation 後，錯誤頁指向該代 store 和同一目錄的 Backups，不誤指舊的根目錄 store。舊 `repairDanglingReferences` 僅保留為顯式維護 API，不再由 App 啟動呼叫。

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

普通 V1 入口仍只有 App 內 `Command-Shift-N`。2026-10-08 的隔離 V2 已接入可配置系統註冊，正式啟用及完整實機驗收仍待完成，見文末 B02 契約。

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

取消 queued 項保留原整理狀態並標記 queueState=cancelled，可明確重新排隊；不能把已有候選/已確認內容退回空白草稿。取消 running 項嘗試終止 URLSession 並阻止舊結果落庫，但不宣稱服務端未執行或不計費。重新分析已完成/部分確認記錄時必須保護 savedTermID，舊候選不在網絡返回前被銷毀。

2026-10-08 隔離實作：`WordNoteV2AnalysisQueue` 從 InputRecord 讀取值型任務列表；主線程只做短交易，網絡等待不持有 SwiftData 模型。`beginAnalysis` 先保存 running、attemptID 和 revision，再把凍結的請求值交給 handler。回應寫入同時核對 attemptID、generation、revision、容器 ticket，以及 store 日誌仍選中原 generation、沒有待切換的 restore。完成/失敗各自一次交易，保存失敗暫停全隊列，不再把已成功的付費請求自動重發。

重試採 2/4 秒基準退避，至多兩次；有效 Retry-After 更晚時優先遵守，超過 60 秒改為需要人工重試的 failed，保留 deadline。取消等待中的重試仍保留未到期 deadline，不能藉取消再排隊提前發送。等待中的任務不阻塞其他已到期任務，新捕獲立即喚醒休眠 worker。

中斷留下的 running 先在共用日誌寫 analysisRequiresResume，再正規化成 queued；再次崩潰/重開也不自動付費重放。正規化增加 generation 使舊回調失效，但保留 autoRetryCount；只有明確新一輪重試才重置預算。重新分析同名候選保留原字段和 saved/ignored 狀態，只追加新英文主體；pending 候選同步到目前 generation，失敗或取消後仍可人工確認。C02 的差異採納界面完成前，不自動更新既有釋義。

隊列核心證據見 [隊列與真實調用](qa/2026-10-08-a02-analysis-queue.md)。後續 `WORDNOTE_V2_VALIDATION` QA 編譯已串接 Quick Add/浮窗/Inbox 三入口，持有唯一 queue，並在 Inbox 提供獨立可展開任務視圖。queued/running 不混入待確認列表；取消/重試/暫停均走同一持久隊列。普通 App 仍使用 V1，沒有啟用真實資料遷移；見 [隔離 App 接入](qa/2026-10-08-a02-app-integration.md)。

### 原子性與撤銷

- 確認交易同時寫 Term、候選狀態、savedTermID、課程和 occurrence；任何驗證/保存失敗回到原狀。
- review 交易同時保存 ReviewEvent、ReviewCard、ReviewSessionItem 和會話游標，actionID 唯一；已完成 action 重試返回既有結果。
- revision 是整數版本，不用時間戳替代。計劃/編輯快照攜帶 expectedRevision，失配要求重新讀取並處理衝突。
- 編輯/確認撤銷只在本次 App 運行期提供，receipt 保存受影響 ID、前後 revision 和字段。撤銷前校驗未被後續編輯、正式復習或新來源引用；有衝突拒絕撤銷並說明，不級聯抹除新資料。
- SwiftData autosave 不能使 UI 草稿提前進庫；表單用值副本，正式保存仍經服務預驗證和交易。

2026-10-08 隔離實作：`WordNoteV2ContentService` 是 V2 的 MainActor 同步交易入口；同一 container 的服務共用 mainContext 並關閉 autosave，不另建彼此可能過期的寫入 context。入口先檢查恢復屏障，遇未提交的直接模型修改則拒絕操作，不替其他表單保存或回滾。交易內沒有網絡或 await；驗證、插入、關聯、revision 更新只保存一次，失敗全部 rollback，對外返回值/ID 而非可變模型。

`captureID` 識別提交而非相同文字：同次重送返回已保存結果，不重建來源或增加計數；不同提交保留各自課程、note 和捕獲入口。Save Only 建草稿而非查詢事件。精確英文命中不排 AI、不進 Inbox；候選確認只做內容/來源整理，不冒充再次查詞。此批仍保留 `legacyMixed` 的復習反饋，B04 才改新統計。

單項確認支援新建與關聯已有詞，校驗候選/記錄/目標 revision 及分析世代；相同 confirmationOperationID 重送返回原目標，目標已刪除則明確報錯、不重建。`confirmNewCandidates` 保留為顯式 new-only 相容 API，不偷偷改為覆蓋已有詞。刪除與課程引用保護的基礎證據見 [V2 內容交易](qa/2026-10-08-a02-content-transactions.md)。

A05 的 V2 QA Inbox 和候選確認改用不可變 `WordNoteV2ConfirmationPlan`。讀取時凍結選中候選、來源、課程、同名目標及其關係；選擇和 resolve 都是純值運算。既有詞預設 link，逐字段補充必須顯式指定候選；新同名候選內容不同時選一份主內容，不拼接義項。commit 在同步交易中重讀依賴及同名詞集合，先全量檢查再一次保存。無關詞條更新不使方案失效，相關字段即使漏加 revision 仍由值比較擋住；每個來源和被修改的既有詞在整批中最多增加一次 revision。

保存候選的 token 綁定預覽 operationID 與解析後的實際選擇，防止換了覆蓋決定仍被當成原操作重試。相同方案重送是零寫入，不替換 undo receipt；V2 的 ignored 不允許持久 token，只接受精確終態及單步 revision 相符的零寫入收斂，不能據此聲稱操作所有權。失敗可用原方案重試；資料過期則 refresh 產生新方案並清空選擇，原選中候選被處理/刪除時拒絕刷新，不悄悄縮小批次。見 [A05 預覽與原子確認證據](qa/2026-10-08-a05-confirmation-preview.md)。

V2 QA 的候選輸入綁定值型 `WordNoteV2CandidateEdit`，保存前不碰 SwiftData；已修改未保存的行會阻止該候選區直接確認。Term/Course 表單在載入時保存 revision，正式保存與刪除不能偷偷改用當前 revision。詞條課程成員資格由 TermCourseLink 控制，編輯不改寫原 occurrence 或兼容 courseID；詞庫、課程計數、復習篩選及 CSV 使用相同成員資料。V2 review 只把既有排程搬入原子交易，保留 legacyMixed，不提前啟用 V3 分方向規則。

A04 編輯保護：每個主窗口持有 `WordNoteEditProtection`，表單使用引用生命週期穩定、內容為值型的 `WordNoteEditDraft`。保護器在決策時讀取當前值，不等 SwiftUI 的 onChange，避免漏掉最後一次輸入；草稿不是 SwiftData 模型。導航/篩選/列表切換/Inbox 整理操作先處理保存、放棄或取消，sheet 完全關閉後才執行待處理動作。保存失敗保留草稿和原目的地，第二個請求不能覆蓋第一個。其他窗口移除模型時，髒草稿仍留在當前窗口，可查看並複製文字；保存按 ID 重查並拒絕已刪除/過期的目標，不重建已刪內容。

原生 NSWindow 代理只攔截關閉並轉發原有 SwiftUI delegate；取消時嘗試恢復原控件與文字選區。正常退出由 `WordNoteQuitProtection` 逐窗口處理，任何取消/保存失敗都阻止退出，過程中新窗口也重新納入；已明確準備的資料恢復沿用既有受控退出流程。同記錄的候選草稿整批一次交易保存，各候選 revision 增加一次，來源 revision 只增加一次。這些代碼僅在 V2 QA 注入窗口保護，不啟用生產遷移；UI 尚未實機通過，見 [A04 證據](qa/2026-10-08-a04-edit-protection.md)。

`WordNoteEditComparison<Value>` 凍結 baseline/local/current 和雙方 revision，字段以強型別 getter/key path 比較，不依賴顯示名稱或拼接字串相等。只有一方改的字段保留該方；相同修改不算衝突；不同修改須逐字段選擇。readonly 字段與未編輯的元資料保留 current，課程集合不自動聯集。apply 前同時重查草稿的值/基線/revision 與目前庫中值/revision/阻塞狀態，任一不符則保留全部原草稿。

回填只更新 `WordNoteEditDraft` 的 value、baseline 和預期 revision，不保存 SwiftData、不建立 undo receipt。正式保存再次走原有校驗與單次交易；因此「接受最新版本」不能跳過英文主體、課程存在性或下一次版本衝突。V2 draft reader 受恢復屏障保護，拒絕把 mainContext 的未提交模型當成庫中值；讀取缺失的實體不重建。Term/Course 保存後以正式規範化值更新基線，不把裁切前文字當作已保存值。

候選比較按原 ID 讀取，包括已處理候選，另保留同來源新出現的 pending 候選；已處理、分析中或不同世代時禁止回填，刪除/跨來源/重複 ID 拒絕讀取。回填後每個候選使用最新 candidate/source revision，整批仍一次保存。手動建詞有獨立只讀來源草稿，比較只更新來源版本，不重新生成英文/中文字段。比較 UI 在表單內展開，避免與窗口離開確認 sheet 競爭；見 [三方字段比較證據](qa/2026-10-08-a04-field-comparison.md)。

`WordNoteV2UndoHistory` 每個 V2 container 一份，所有主窗口共享，只保留最近一次成功且實際有變更的可撤銷交易。receipt 是記憶體中的局部 DTO 集合及引用標記，不是完整快照或備份；未注入 history 的原有服務不做捕獲。before/body/after/save 同步完成，保存失敗不覆蓋上一張 receipt；幂等確認重送不製造可刪除既有詞的偽 receipt。

撤銷先比較最新字段、revision、來源、候選反向引用、membership、occurrence、lookup/review 事件，再核對被還原的外鍵、詞頭唯一性和關係 ID 所有者。所有檢查通過才反向寫入受影響值，刪除範圍限於那次操作新建的實體與關係；不調用一般級聯刪除，不重建外部已刪除目標。還原後 revision 從當前值繼續增加，舊表單仍失效。資料衝突使 receipt 失效；保存失敗、恢復屏障或直接模型髒修改則保留 receipt 供重試。

工具列和 Edit 菜單使用相同 `operationID` 校驗；若離開確認中的 Save 或另一窗口保存替換了 receipt，舊 Undo 動作會拒絕，不誤撤新保存。無 redo、跨重啟歷史、永久刪除或復習撤銷，也不取代輸入框的 Command-Z。新增可撤銷操作時必須同時擴充 scope、還原字段和依賴測試，不能直接套用到關係字段編輯。詳見 [安全撤銷記錄](qa/2026-10-08-a04-safe-undo.md)。

### Inbox 閱讀與連續整理

B01 的 `InboxBrowseIndex` 在 MainActor 將記錄與按 inputRecordID 分組的候選轉為不可變 DTO，預計算簡繁中文/英文搜索鍵。記錄/候選 ID 或 revision 變更重建；搜索/課程/來源/狀態變化只重算可見結果。篩選課程是捕獲記錄的 courseID，與詞庫 membership 不混用。queued/running 與 ignored 不进入主列表，completed 進 Handled；同一項可同時有 pending 候選與 failed 任務。

`InboxSelection` 管理當前焦點與可見、可處理的批選 ID；以舊列表鄰項決定下一條，切範圍清批選。`InboxCandidateSelection` 只在首次出現 pending 時初始化推薦勾選，此後只刪除已處理 ID、不自動選新項。A04 保護完成後重新獲取當前 revision/generation，完整範圍仍有效才生成 A05 預覽；預覽由 Inbox 根視圖持有，與可替換的記錄詳情分離。不得把勾選當作提前寫庫。

候選/整條输入的 ignore 經 `undoableTransaction`，scope 包含來源與受影響 pending 候選；既有 saved 候選是引用校驗依賴，不因撤銷重新覆寫。`applyUndo` 還原來源 curation 和 RecordState，同時從當前 revision 遞增，修補原先僅還原 status 會丟失失敗/取消任務及 provider deadline 的缺口。queued/running 來源本來就禁止整理，撤銷不啟動分析、不清除計費或憑空重發請求。取消 running 的對話框凍結 job revision，實際取消仍走隊列校驗。見 [B01 證據](qa/2026-10-08-b01-inbox-workflow.md)。

### 詞庫閱讀與批量整理

A06 的 `VocabularyBrowseIndex` 僅持有不可變 DTO 和預計算的中英文搜索鍵、標籤鍵及真實再次查詢日期，不捕獲 SwiftData 模型。V2 頁面在詞 ID/revision、membership 或 LookupEvent 改動時重建索引；查詢/篩選/排序變化時集中計算可見結果，不在每個行或按鈕重繪時重複整庫排序。60 秒時計刷新活動篩選；ID 選擇由純值 `VocabularySelection` 管理。全文仍交給閱讀投影，列表摘要只影響展示，不寫回資料。索引建構和讀取仍在 MainActor；10,000 詞的核心數值測量不是包含 SwiftData/渲染的 200 ms UI 驗收。

`WordNoteV2OrganizationPlan` 凍結選中 Term 的完整內容/revision、現有 membership 和所用課程內容/revision。預覽計算課程與標籤的實際增減；提交先批量讀取並建立 ID/關係索引，校驗全部依賴後才一次保存，避免逐詞重掃全庫。相關字段即使漏加 revision 也阻止舊預覽，無關詞條修改不阻塞。只增減 `TermCourseLink`、`tags` 並 touch 實際改動的詞，不改原 courseID/來源/釋義/排程；失敗全回滾，支持 A04 相同安全邊界的撤銷。

此方案不新增持久 token；成功後重送原方案會因版本不符而拒絕，重新預覽相同增減得到 no-op，零保存且不替換既有 undo receipt。取消只丟棄值草稿；不提供恢復後自動重放整理操作。詳見 [A06 閱讀與批量整理證據](qa/2026-10-08-a06-vocabulary-reading.md)。

### 卡片排程與查詢信號（B04 第一批）

`ReviewCardScheduler` 是不持有 ModelContext 的純值服務，分開 `presentation` 與 `feedback`：前者只在真正呈現時消耗重學次數/首次新卡標記，後者產出不可變 before/after、排程延遲、處理結果及時鐘異常。預覽可重複計算，不寫庫；新規則只復用舊 Good/Easy 曲線，不改 V1/V2 的反饋歷史語義。

`ReviewStudyClock` 保留 observedAt 與非倒退 effectiveAt。到期使用有效交互高水位，事件時間仍是 observedAt；每日桶以明確 Gregorian 日期和時區解析，不接受被系統正規化的非法/不存在民用日期或公元前年份。排程和完整 V3 snapshot 共用標量/狀態校驗，避免兩套約束漂移。時區變更先保留既有桶的結束邊界；詳細 quota 與跨日規則見 [07](07-review-system.md)。

`ReviewCardQueuePolicy` 只分類下一次可用性，不建會話。停用/埋藏先阻擋，新卡始終留在 new 分類，重學按精確分鐘與日上限判断，日級卡才使用當地日末。pending priority 不繞過上述限制。它不應用來重新計數已呈現項；B05 仍須提供固定組、全局每日新卡配額、呈現冪等和窗口租約。

V3 `capture` 復用既有不可變 request/result 契約，但本地命中交易改為來源、LookupEvent、membership 和一個 priorityRequestedAt。Term 僅 touch revision/updatedAt，舊計數、重要度、能力及排程不雙寫。選卡先啟用的英文 wholeTerm，再其他啟用 wholeTerm；無任何卡才建立 new 英文卡，僅 cloze/停用卡不自動擴卡。captureID 重送不刷新優先時間，已刪來源不因重送復活。服務沒有 provider 引用，未命中只持久排隊。沿用前後全圖校驗及單次保存/回滾，性能門檻仍須另測。

這批沒有接入正式反饋 writer、按鈕預覽或 V3 runtime。後續必須將 snapshot/revision/lease/actionID 校驗和 card/event/item/cursor 寫入放在單一交易；不能由 UI 直接把純 plan 寫進卡片，也不能把 presentation 重跑當會話恢復。證據見 [B04 排程與信號](qa/2026-10-08-b04-scheduler-signals.md)。

### 正式作答交易（B04 第二批）

`WordNoteV3ReviewService` 是隔離 V3 的唯一正式作答入口，復用 ContentService 的單 MainActor context、寫入屏障、草稿保護、前後完整校驗及一次 save/rollback。正式作答方法只對當前 active/presented 項操作，不隱式建立會話或呈現卡片。完整 V3 校驗拒絕 presented 的 new 卡缺 introducedAt，導入/啟動/寫入一致阻擋，不在評分時補造配額事實。

回答權按 ModelContainer 共享而不是每頁各自持有，綁 sessionID、窗口 ownerID、隨機 lease ID 和 WriteGate ticket。容器弱引用避免永久保留已關閉 store；同 owner 重取不換權，其他 owner 被拒。新可恢復會話或恢復後 ticket 變更才換代；遲到 release 不釋放新 owner。這是單進程、同一 runtime 容器內的窗口協調，沒有宣稱能協調兩個獨立進程/容器同寫 SQLite；App 仍須維持唯一 runtime writer。

`currentAnswerSnapshot` 返回不可變的完整 Term/TermState/Card/Session/Item；read 本身不取得回答權。`revealAnswer` 先比對畫面快照，再原子保存 sibling burial 和本組 siblingDeferred，touch 當前卡 revision/交互高水位，成功後才標记該 lease 的內存已揭示快照。同 lease/同快照重揭示不重存；失敗不授予評分能力；釋放、重啟或換窗口要重新揭示。所有非當前同詞啟用卡均為 sibling，不改其能力/原始 due，不縮短較晚的 burial，已結束會話項不重寫。

`previewFeedback` 不寫庫；`recordFeedback` 重新核對完整依賴快照與揭示能力，重算並核對原 preview 防止任意排程注入。實際提交時間重新計算絕對 due，但相對間隔、處理分類及其他 after 狀態須與顯示一致；跨日、倒退或語義變更要求刷新。依賴包括內容本身，漏加 revision 也能發現；其他詞的正常編輯不使預覽失效。

正式保存同時新增 semantics=2/scheduler=simple-v2 事件、寫 Card 排程、Item 的 attempt/lastAction/結果、Session 的固定組游標及 revision。Term/legacy 快照不寫。唯一 actionID 由交易前完整校驗及串行 writer 保護；同操作重送只讀返回持久收據，已完成/刪卡仍可返回原 originalCardID，不再推進游標，也不清除下一張卡的揭示狀態。不同輸入的 actionID 衝突、已作廢事件或已刪 Term 不補記。保存成功後只執行不拋錯的內存清理，避免已提交卻向 UI 報失敗。

正式 UI 尚未接入此服務。B05 會話及控制核心、B06 題型內容見下節，窗口生命週期仍待接入。證據見 [B04 作答交易](qa/2026-10-08-b04-answer-transactions.md)。

### 固定會話與首次呈現（B05 第一批）

`WordNoteV3ReviewService.startSession` 在同一交易讀取範圍、時鐘、卡片與全局配額；按 membership 篩課程、按 mode 篩方向，使用 `ReviewSessionSelection` 固定最多 target 張不同 cardID 及順序。空隊列不建空會話；既有可恢復會話阻止第二組。呼叫方保留同一 sessionID 重試時只讀回原組，範圍/target/limit 不同則衝突。課程名稱在建立時取真實庫值，後续改名/移除 membership 不重建本組。

建立時只保存 pending 項，不扣配額。`presentNextCard` 經租約和 session revision 檢查：當前 presented 項原樣恢復，不重跑 scheduler；沒有已呈現項時先取本組已到分鐘的重學，再取固定順序的 pending。首次呈現同時保存 Card 排程/introducedAt、SessionItem 狀態和 Session 游標/revision/引入台帳，任一步失敗全部回滾。未到重學時間返回 nil，不擴組或造事件。pending 排程已改成未到期時要求刷新，不偷偷提前評分。

`ReviewNewCardQuota` 從全部會話台帳按 originalCardID 去重，不按課程/方向分配多份額度。會話新增可空 introductionsJSON，首次引入記錄觀察時間、配額高水位和凍結日桶；刪卡/刪詞保留匿名身份用量。時鐘倒退不重置，時區切換先等舊日末，重疊區間保守計入；DST 使用本地日曆邊界。舊原型 V3 缺台帳時僅以存活卡 introducedAt 作保守計算，從未記錄且已刪除的舊用量不能推斷或重造。

`pauseSession` 保存 paused 後釋放回答權，`resumeSession` 維持原 item/範圍並重新顯示正面；`endSession` 提前結束不修改卡片排程、不造完成量/事件。所有控制受 revision/恢復屏障/草稿保護，保存失敗保留原租約。應用仍需把原生窗口/頁面生命周期接到這些入口。

新台帳改變必需保留的備份語義，因此 V3 ordinary backup 與 repair evidence 的各自格式號升為 2；舊讀取器明確拒絕，新版兼容沒有台帳的 format=1。不得把帶台帳資料降標為 1；V1/V2 格式/模型不改。V3 仍為未發布原型 schema，不聲稱舊 V3 SQLite 能直接跨此模型改動打開。

第一批測試及兼容邊界見 [B05 會話與呈現](qa/2026-10-08-b05-session-presentation.md)。Settings/Review UI 和 V3 runtime 整套接入尚待實施；大庫 MainActor 全圖校驗仍有性能出口。

### 非評分控制與共用統計（B05 第二批）

`skip` / `later` 驗證完整當前回答快照與租約，但不要求先揭示。控制收據放在 Session.controlsJSON，actionID 與正式 ReviewEvent 共用唯一命名空間；保存前先檢查只讀重送，異來源/種類衝突拒絕。收據只保存 SHA-256 指紋、身份、時鐘、结果 revision/status/due，不複製答案內容。保存失敗不清理揭示/租約；成功後的記憶體清理不能再拋錯。每組有 10,000 筆上限，保留已有收據而非偷偷淘汰。

Skip 輪轉固定項順序，保持 presented 和所有卡片排程/配額，保存 skippedItemIDs。全部當前可答項已略過就暫停並釋放回答權；未到重學不阻止暫停，已到重學可由下一次呈現優先接手。恢復從輪轉隊首開始；正式反饋、Later 或明確繼續清空略過輪次。Later 使用純延期計算，只把 due 延至不倒退時鐘的次日本地日界，保留重學桶和能力，不寫事件或增加 attempt。兩者與會話游標同次 save。

新正式事件在同一交易分配 recordedOrder，按當前所有事件（包括作廢事件）的最大值递增並做溢出檢查。`ReviewStatisticsBuilder` 僅讀不可變 V3 快照，全局先按 dayKey/cardID 找首次有效回答，再過濾會話/課程/方向。legacy 和 invalidated 事件排除；舊原型缺序號時採觀察時間/UUID 並明示估計順序。當日日桶不因換報表時區而重寫歷史。只讀服務不回寫任何 Term 計數。

處理進度使用實際固定 item 數，成功完成、手動延期、上限延期、原因未知延期、sibling、不可用、未驗證完成分開。課程統計依當前 membership；卡片刪除後仍按 originalCardID 計真實事件，刪詞已級聯移除的歷史不補造。工作量復用 `ReviewCardQueuePolicy`，將可答、等待重學、未引入新卡、埋藏/停用和缺中文方向分開。新控制/序號由 format=3 保護，format=1/2 仍按字段能力向後讀取。證據見 [B05 控制與統計](qa/2026-10-08-b05-controls-statistics.md)。

### 題型內容與明確建卡（B06）

`ReviewQuestionFront` 只含 cardID/mode/prompt，View 不接收完整 Term 再靠 hidden 遮答案。背面由 `revealedQuestion` 校驗當前 lease/已揭示完整快照後返回；純 `ReviewQuestionContent.back` 是內容構造器，不具備寫入排程權。輸入比較保留原始文字，只標記空白、匹配或需自評，不產生 ReviewEvent。正式選組、呈現前與統計共用相同題面資格；失效題面在修改卡片、游標和新卡台帳之前拒絕。

`ReviewClozeBuilder` 與 `ReviewTextMasking` 使用 ICU 邊界匹配、Unicode canonical normalization 及一次建立的 UTF-16/Character 邊界表。原文 hash 仍基於原始 UTF-8，不能把等價 Unicode 當成同一份未修改源 bytes。所有已知答案形式合併遮蔽，重複命中最多 1,000 個，超限停止並拒絕；撇號只在詞內構成邊界，包住詞頭的引號不洩露答案。這不等於形態學推斷，屈折形式須明確選定。

`previewClozeCard` 只讀，記住 Term/TermState、Occurrence、InputRecord/RecordState 的完整依賴及不可變預覽。只接受已保存、凍結 englishToChinese、來源與捕獲 bytes 一致的英文原文。`createClozeCard` 再檢查依賴、重建預覽、拒絕相同來源範圍重複卡；同 cardID/target 重送只讀回原卡。新卡、Term revision 和可用日期同交易，失敗全回滾。

`enableReviewDirection` 僅接受整詞識別/回憶，明確 opt-in；新方向為獨立 new 卡，不複製 sibling 的能力。重新啟用既有方向保留自身能力/桶/引入史：從未學過的 current 卡為 new，其他卡恢復 review 並到期，不復活舊會話項。填空必須另走預覽入口，失效目標不能藉此復用。

揭示交易新增 Term.reviewExposedUntil，與卡片/會話一同保存；這是答案曝光邊界，不是 mastery、legacy 計數或正式作答。單獨刪卡/刪來源保留它，刪 Term 才級聯消失。新建/啟用方向繼承未到期邊界及更晚 sibling burial；舊原型沒有邊界時，當日已呈現項/有效事件作保守依據。這可能延後尚未實際揭示但已呈現的 sibling，避免崩潰丟失內存揭示狀態後照抄；未呈現 pending 不算曝光。

`reviseOccurrenceText` 比對來源快照/Term revision，不改原 InputRecord；依賴目標保存 sourceChangedAt、清除舊 hash/答案/範圍、停用卡並標記 item unavailable。修改後 snapshot 不再是已驗證捕獲副本，不能直接重新建填空；需選擇或新增另一份有證據的原文。V3 備份與修復證據 format=4 保護曝光邊界及來源改動標記，1/2/3 僅在不含新字段時可讀。V1/V2 不變，未發布 V3 SQLite 跨模型直開仍未承諾。

詳見 [B06 核心證據](qa/2026-10-08-b06-question-content.md)。當時尚未接入的內容 writer/queue 核心由下節補齊；後續隔離 runtime、Review/Settings/建卡 UI 接入見「V3 隔離 App」，不把核心通過視為 B 階段出口。

### V3 內容與分析流水線（B03、B04）

`WordNoteV3ContentService` 現在承接分析任務、候選確認/批量預覽、手動加詞、內容/課程編輯、membership/tag 整理及安全撤銷。模型綁定的入口獨立於 V2；純值草稿、selection、confirmation/organization plan 繼續復用現有 `WordNoteV2*` 名稱，並不代表把 V2 writer 附在 V3 容器。

手動、單候選和批量新建均同交易插入 Term、來源/課程關聯及一張 new 英文識別卡。Term.nextReviewAt 明確為 nil，舊學習計數為零；新卡不複製其他方向能力，也不直接取得 introducedAt。關聯已有詞不追加卡片、不製造復習事件。內容編輯拒絕改變 legacy mastery；已處理/忽略的來源不能再通過手動加詞入口保存。

`WordNoteV3AnalysisAttempt` 帶不可變 request、store ticket、record revision/generation/attemptID，以及完整 InputRecord/RecordState 值。回調比較全部依賴，遺漏 revision 的來源改動亦拒絕；請求發出後課程改名不重寫其已凍結 courseName。分析保存只追加未出現的候選名，保留人工內容、已保存關聯和忽略狀態，不自動入庫。

`WordNoteV3AnalysisQueue` 一個實例持有一個 worker，重用已驗證的退避/持久預算/取消 epoch 規則。保存或世代錯誤先暫停，不自動重發已付費請求。App runtime 接入時必須共享同一個實例，不能每個窗口自行建立 worker。`WordNoteDataProtection` 已有 V3 queue adapter、十一實體備份/預覽/切庫和待分析數；取消恢復或備份失敗保持暫停，新的 generation 要明確恢復分析，舊回調不落庫。

V3 撤銷收據除內容/關聯外還記錄範圍內 TermHistory、卡片、正式事件、會話與項。開始會話、揭示、作答、精確重查、新增方向/填空或新增來源引用後，舊撤銷拒絕而不刪除學習資料；新建課程的凍結 session 引用也算依賴。關聯會話內其他項的變動可能保守地阻止撤銷，並明確報錯。無關詞的獨立復習不阻止內容撤銷。撤銷只恢復內容、推進 revision；從不恢復 legacy 排程/計數。撤銷確切新詞時，一併刪除收據保護下尚未使用的新卡，不做一般級聯。

實作和兩次合成 live 的完整鏈路證據見 [V3 內容流水線](qa/2026-10-08-b03-v3-content-pipeline.md)。普通 App/V2 QA 尚未改用 V3，沒有正式詞庫升級，性能和原生 UI 仍待驗收。

### V3 隔離 App（B03-B06）

`script/build_and_run.sh --ui-v3-fixture` 使用獨立 scratch path 和 `WORDNOTE_V3_VALIDATION`。普通/V2 入口不變，兩個 validation 標記同時存在會編譯報錯。App-only `VersionedAppConfiguration` 選擇 schema/內容服務/Undo/queue；共用純值 plan 保留既有名稱，不影響核心模型別名。`VersionedValidationRuntime` 只在 QA bundle/fixture 下啟動，透過共用受保護 coordinator 先建立完整 V3 session，再建立唯一 queue 和共享 capture、備份及 Undo 依賴。恢復/遷移的顯式分析暫停規則保持。

每個 Review surface 自持 `V3ReviewController`，持久資料仍全部經 `WordNoteV3ReviewService`。主窗口只持有 lease、正面、揭示後背面、typed answer 和 feedback preview；離頁/失焦/關閉/恢復不可用時清掉並 release，不結束持久組或重新抽題。失焦回來明確 Continue，再揭示；服務共享 ownership 防止另一窗口搶答。等待時計只呈現本組已到時項。確認結束可以從 sheet 執行，仍須重新取得 lease，但不要求 host 當刻是 key window，避免把模態失焦誤當拒絕結束的理由。

`V3ReviewWindowBridge` 是窄 AppKit local event/窗口通知適配器，不替換 delegate。非本窗口、文字 responder、sheet/modal、修飾鍵及 autorepeat 不攔截；空格揭示、1-4 自評，Return 不評分。事件在同步回調內，跨 MainActor 邊界僅返回 Bool。UI 正面只用 `ReviewQuestionFront`，背面要正式 reveal；答案比對不自動生成 feedback。

V3 詞库撤下 Term mastery 編輯/篩選，改為獨立卡片閱讀、方向啟用/停用及原句填空預覽；歷史 mixed counters 單獨收合。Dashboard 用共同 `ReviewStatisticsBuilder` 的卡片工作量和新事件統計，不再呼叫舊 Term queue policy。Settings 組大小/新卡限額目前為本機偏好，建立會話時凍結；偏好備份和統一設定窗口仍是 B08，不冒充完成。首次原生端到端與工具限制见 [V3 UI 證據](qa/2026-10-08-b03-v3-app-review.md)。

### 學習概覽與窗口導航（B07）

`LearningOverviewBuilder` 從完整已驗證 V3 快照產生只讀概覽。`ReviewCardLearningIndex` 統一現在可答、新卡、等待、關聯延期、停用、缺答案及未到期的分類，首頁/課程的數值和實際卡片列表使用同一次分類，Review 的工作量亦復用它。課程詞表按當前 membership 去重，最近遇見則按 occurrence 的凍結 courseID/occurredAt 過濾；待整理列表復用 Inbox 的純值投影及 active 規則，不另定一套狀態。薄弱詞僅由有效新語義 Again 或未消費優先請求推導。

`LearningWorkspace` 屬於每個 `ContentView`，不是全局 runtime。它保存各列表查詢、批量選中、焦點、獨立閱讀目標、行級滾動錨點、課程标签/方向、新組預選及最多 30 個返回狀態。深鏈不破壞原搜索；Back/側欄切換和課程捕獲前置動作經同一編輯保護，取消或準備失敗不移頁。明確的「查看全部卡片」則建立新的可見範圍，返回恢復之前的詞庫狀態。沒有像素級滾動或重啟後保留完整導航歷史的承諾。

卡片深鏈只在詞庫閱讀指定 term/card，失效 ID 顯示不可用，不替換成鄰近項、不作答。課程復習僅預選新組參數，已有持久組保持原範圍；加詞在保護通過後只更改當前 capture course，不改持久預設、source/intent 或已排隊請求。`RememberingList`/`RememberingScrollView` 記錄最上方可見行，窗口各自恢復。V3 詞庫的方向/mastery/state 必須同時匹配同一張卡；無卡片條件時仍可閱讀無卡詞條，不能以 Term 的 legacy mastery 代替卡片能力。新增 `learning` 合成 fixture 供長列表驗證，原 `populated` fixture 不變。證據及原生限制見 [B07](qa/2026-10-08-b07-learning-navigation.md)。

### 備份、恢復與啟動

備份取得一致、不可變的 DTO 後才序列化及原子寫文件，不跨 executor 共用可變 ModelContext/model。A01 大庫測量發現 MainActor 全量捕獲會阻塞，因此日常/手動備份改用樂觀一致性讀取：V1 先保存當前已修改 context；V2 若存在直接模型的未提交修改則拒絕捕獲，不代替 revision 交易提交或丟棄表單。后台 worker 建自己的唯讀 context，讀取前後同步比較同容器的 willSave/didSave 計數；有任何保存或主 context 待保存修改就丟棄整次讀取並重試，最多三次，仍不穩定則保留舊備份並明確報錯。V2 重試時仍檢查未提交修改。不能把混合版本或只截取部分實體的結果當成成功快照。

前提是 App 的正式寫入仍由 MainActor 服務串行處理；通知不得延後排入主隊列才計數。新增後台寫入者或另一個寫庫進程時必須重新設計此一致性邊界，不能沿用上述假設。快照 DTO 的同步 adapter 不再強制 MainActor，但呼叫方必須在其 context 所屬 executor 完成全部模型訪問。

恢復仍需要全窗口寫入屏障，按照 [08](08-security-privacy.md) 的 staged store + 恢復日誌實施。建庫、持久化重開驗證和校驗碼計算在后台使用獨立 context，不把它們的模型傳回 UI。worker 完成後回 MainActor 重新讀取 active/pending 日誌，拒絕過期或相競爭的恢復，再寫 prepared；取消不提交 prepared。受控退出後在下一次 ModelContainer 建立前切換，成功後才解除寫入屏障。

每次 schema 改變同時更新 migration、snapshot adapter、刪除/完整性檢查與測試 fixture；先凍結 V1 真實類型形狀，不能讓 V1 指向持續改動的最新類型。V2/V3/V4 的主要寫入切換點見 [05](05-data-model.md)。

V3 沿用隔離純值轉換，不修改原 SQLite：`WordNoteV2ToV3Migration` 驗證 V2 DTO，按最後事件決定唯一主卡。第二批明確把本次已驗證保護備份的 createdAt 作為遷移時間；恢复舊快照亦使用當次 beforeRestore 的時間，不用被導入舊備份的建立時間或 worker 臨時 now。`WordNoteSnapshotV3Payload` 擁有完整十一實體及元資料，校驗後只能寫入 V3 空庫，全部插入後單次保存，失敗 rollback。普通 App 及 V2 QA writer 未切至 V3，因此不存在活動的 Term/Card 雙寫者；第三批刪除/完整性交易已提供核心入口，B04 新排程及完整寫入/UI 仍須共同接入，不能直接開正式 V3 庫。

B03 第二批共用 reader/VersionedPayload/capture/vault 已支持完整 V3；checksum 包含卡片、會話、游標、會話項及事件前後狀態，僅這些字段變動也能觸發備份。V1/V2 codec 不接受 V3，App 導入預覽按現有 session 的最高能力拒絕未支持 schema，在暫停隊列、建立保護備份或更改日誌之前停止。

V3 使用 version 3 切庫日誌及十一類 counts；V1/V2 各自保持五/八類編碼。counts 字段缺失、跨版混入、越界或持久重開不符均不啟用新庫。取消/回退不把 journal 降版，舊入口不能繼續寫入它。`WordNoteStartupCoordinator` 按 store 的顯式 targetSchema 復用既有保護流程；原 `WordNoteV2StartupCoordinator` 保留兼容 typealias，V2 QA 仍指定 V2。V1 可經 V2 純值 adapter 直達 V3，只保護一次原始 V1，不先選中中間 V2 store。V3 啟動先完整校驗，失敗不返回 ready。第三批新增 `inspectV3Repair` 和版本化 repair 路由；V2 專用 inspectRepair/plan 仍拒絕 V3，不能只修 nested content 而丟掉新實體。見 [B03 第二批](qa/2026-10-08-b03-protected-recovery.md) 及 [第三批](qa/2026-10-08-b03-deletion-integrity.md)。

`ReviewCardSchedule` 是卡片和事件前後快照的共用值型；SwiftData 仍持有明確標量排程字段，cloze/scope/事件快照以嚴格 JSON adapter 保存。新 event.originalCardID 是歷史身份，cardID 是可解除的現存引用。`WordNoteV3ContentService` 已實作 record/occurrence/term/course/card 刪除及停卡，寫入屏障、草稿檢查、revision 和前後完整校驗後單次保存；失敗回滾。刪來源寫明確 sourceDeletedAt，停用卡並解除會話引用，不偽造作答或改寫 Term 兼容排程。尚未接 UI，且啟用前須驗證全圖校驗的大詞庫延遲。

`WordNoteV3IntegrityService` 的報告與預覽只讀；必需卡/會話/歷史關聯不猜測、不刪除。V3 原始證據使用獨立 `WordNoteV3RepairEvidenceVault`，保留十一實體、元資料、失效引用和白名單偏好，重讀核對 counts/checksum/摘要後才能 staging。證據文件不是正常 backup，舊 evidence reader 不接受它。嚴格 JSON 解碼失敗時保留原 SQLite 並停止，不用空對象替代來產生不完整證據。修復方案綁定全 payload；任何卡/會話/偏好變動即過期，取消只撤本次 pending。缺來源或無法確定的 legacy cloze 不靠 AI/字符串替換補齊。

2026-10-08 的隔離 V2 基礎不使用在原庫上直接執行的 lightweight migration。`WordNoteV1ToV2Migration` 先檢查完整 V1 DTO，再產生確定性的 V2 值；`WordNoteSnapshotV2Payload` 只允許写入 schema 為 V2 的空庫。隔離 `WordNoteV2StartupCoordinator` 已串接 A01 保護快照、后台建庫/重開比對和共用日誌，但正式 App 尚未接入，不能單獨改 typealias 就啟用。

V2 邏輯快照沿用 formatVersion 1 的 checksum envelope，sourceSchemaVersion 為 2.0.0。payload.content 復用凍結的 V1 字段定義，另有按實體 ID 一對一匹配的 revision/捕獲/候選/計數語義元資料表，以及 occurrence、courseLink、lookupEvent 三類實體。缺行、多行、重複業務鍵和錯誤關聯均拒絕恢復。`WordNoteSnapshotReader` 按 schema 路由 V1/V2 讀取器；`WordNoteVersionedPayload` 共用捕獲、校驗、checksum 與編碼入口，不改兩版既有文件格式。

2026-10-08 的 vault 已能列出、生成及導出 V1/V2，摘要含 schema 與全部八類計數；跨版本保留最新七份自動備份，手動/遷移前/恢復前快照均不自動刪除。只改 V2 關係或元資料也會改變備份 checksum。按 ID 導出使用同一次讀取的驗證 bytes，不能省略新增資料。舊 `readSnapshot`/`capture` 入口繼續拒絕 V2；只有顯式版本化入口接受兩版。見 [版本化備份證據](qa/2026-10-08-a02-versioned-backups.md)。App 的 `WordNoteDataProtection` 現可按 session schema 路由捕獲、預覽、備份、恢復和待分析數；V1 runtime 在暫停/備份之前拒絕 V2 導入，V2 runtime 拒絕未提交模型修改。V2 恢復分析由 queue 先正規化中斷工作，再解除日誌暫停，不能由 UI 提前清除標記。

共用 `WordNoteRestoreStore` 現可顯式指定 targetSchema V2，在后台升級舊快照、建八實體 store、重開逐值核對，並在下次啟動驗證後選中它。未指定時仍為 V1，不能隱式激活 V2。`store-generations.json` 的 version 1 和五類 counts 保持兼容；首次準備 V2 時寫 version 2，active/previous/pending 均帶明確 schema，pending 帶八類 counts。回退依 active 的 schema 打開原庫，不重試中斷的 activating。version 2 即使取消/回退仍保留，舊入口直接拒絕，不降版重寫日誌。見 [版本化恢復證據](qa/2026-10-08-a02-versioned-restore.md)。

低層 V2-capable `WordNoteRestoreStore.open` 遇無待恢復的 V1 庫仍返回 V1 session，不自行原地遷移。`WordNoteV2StartupCoordinator.open` 則須在 UI、表單及 worker 建立前執行：持有原容器寫入屏障、拒絕未保存修改，先持久化 migration 意圖及分析暫停，再建立/重讀校驗 beforeMigration 快照。staging 前後重新捕獲全部源資料比較，使用同一日誌準備與啟用 V2；不接觸原 SQLite，也不把源 context 交给頁面。已有 V2 session 先通過完整捕獲校驗才返回 ready。

version 2 日誌的 pending.operation 區分 restore/migration，缺值兼容既有 restore；recoveryRequired 在失敗或 activating 中斷後保留。已寫入遷移意圖的失敗不因重啟自動重試，必須顯式 retryMigration；未完成遷移不能直接恢復分析。取消只匹配本次 pending generation，不撤銷競爭操作。原容器保留的 context 仍被屏障阻擋，不能在新庫 ready 後繼續寫舊庫。成功切換清除 recovery 標記，有未完成分析時仍需明確恢復；已有 V2 的 restore 失敗可明確恢復原庫分析。見 [啟動遷移證據](qa/2026-10-08-a02-startup-migration.md)。

以上啟動流程已接入 V2 QA App：先檢查測試 bundle 身份，僅使用臨時 fixture 目錄，再由異步 coordinator 返回 ready，最後建立頁面、唯一 queue、資料保護和浮窗。普通編譯仍走 V1；QA 二進制沒有非 QA bundle 的生產回退路徑。V2 中 queued/running/failed 工作從備份恢復後持久標記待顯式恢復；恢復和遷移本身不發送網絡請求。QA 預設使用離線分析替身，真實網絡測試仍顯式 opt-in，不能把核心或啟動證據當作三入口 UI 驗收。

`WordNoteV2IntegrityService` 提供值層檢查及修復預覽：涵蓋全部八實體、四份元資料、業務唯一鍵、來源對應與候選狀態。唯一自動提出的修復是解除指向已不存在記錄的 Term.sourceRecordID、Occurrence.sourceRecordID、LookupEvent.occurrenceID；缺課程、缺詞、孤立內容、跨 capture 關聯及重複關係均要求人工處理。修復方案保留完整來源值，stage 前後比較最新資料與偏好，變動即拒絕舊方案。只產生新 payload、更新受影響 Term.revision，不寫原庫。見 [完整性與啟動防護證據](qa/2026-10-08-a02-integrity.md)。

隔離啟動協調器現提供 inspectRepair/repair 兩個分開的入口，open 失敗不代表同意修復。前者只讀、後者消耗當前預覽，持有原庫屏障並寫 recoveryRequired=repair，再將非法關係仍完整保留的 DTO 存入 `WordNoteRepairEvidenceVault`。這是帶獨立 purpose/version、原 generation、八類 counts 和 checksum 的證據文件，不是放寬驗證的備份；普通 snapshot reader 一律拒絕。保存及重讀比對後，合法的修復結果交給同一后台 staging/切庫日誌，pending.operation=repair，sourceSnapshotID/protectionSnapshotID 都指向證據 ID；原庫不動。已有 prepared 可跨啟動完成，activating 中斷則退回原庫、保留修復標記，不自動再做一次。修復標記下恢復分析必須先重新完整校驗當前庫，允許已完成人工修正的原庫在明確確認後解除暫停。見 [受保護修復證據](qa/2026-10-08-a02-startup-repair.md)。此入口仍只用於建立 UI/worker 前的隔離啟動，正式恢復界面未接入。

### 窗口與性能

全局快捷鍵封裝在單一 AppKit 適配器，只接受已註冊組合鍵；先验证 macOS 14 的可用機制，不預先要求輔助功能或全鍵盤監聽。保持 SwiftUI 命令、菜單欄和浮窗路由一致。

2026-10-08 B02 第一批：`CaptureShortcutController` 管理值配置、持久化、活動註冊 ID、按下/釋放去重與暫停；可注入 backend 和 UserDefaults。`CarbonCaptureShortcutBackend` 在 MainActor 使用 `CopySymbolicHotKeys` 檢查已啟用系統鍵，再以 `RegisterEventHotKey` 的 exclusive 選項註冊。不安裝全鍵盤監聽，也不要求 Input Monitoring 或 Accessibility 權限；不能據此聲稱能識別所有 App 內部快捷鍵。

改綁先註冊新鍵，再釋放舊鍵；衝突保留舊設定，釋放失敗則回滾新註冊。回滾清理失敗的 ID 留待下一次重試，永不觸發捕獲。每個原生 backend 只有一個 Application event handler，native ID 在本進程唯一；C 回調上下文持有獨立狀態直到 handler 成功移除，已釋放鍵的遲到事件無法找到活動映射。退出、runtime 替換和停用顯式清理，backend 析構的兜底也回 MainActor，不依賴 `isolated deinit` 或假設析構必在主線程。

快捷鍵配置以 `captureShortcut.v1` 保存在本機 UserDefaults，不進 SwiftData/邏輯快照，恢復詞庫不改本機組合鍵。損壞或未知配置 fail closed，保留原值供重新設定。`WordNoteDataProtection.restoreStateDidChange` 由 runtime 單一持有，立即同步當前恢復狀態，之後只在是否可捕獲改變時通知；不依賴主窗口的 SwiftUI `.onChange`。恢復取消或可恢復失敗後重新註冊，recoveryRequired 保持暫停；分析是否恢復仍遵循 A01/A02 的顯式授權，不因恢復快捷鍵而自動發送請求。

`VocabularyCompletionEditor` 新增可選 Command-Return 回調。僅活動編輯框攔截，先把已提交文字同步 binding，再保存並分析；marked text 交回原生 text system，同次事件不執行應用提交。普通 Return 的多行換行/單行提交、Tab 本地補全及未配置回調的 V1 路徑保留。`WordNoteAppTests` 對 AppKit 控件及原生註冊作組件測試，不能當成跨 App 焦點/中文 IME 的完整 UI 驗收。見 [B02 測試記錄](qa/2026-10-08-b02-capture-shortcut.md)。

### 共享捕獲上下文（B02 第二批）

`VersionedValidationRuntime.Ready` 每個 runtime 僅建立一個 MainActor `CaptureContextController`，透過 Environment 注入所有主窗口、Settings 和 AppKit panel 的 hosting root。只保存 `CaptureContextSelection` 值和課程 ID 集合，不持有 SwiftData model。`CaptureContextFields` 復用同一套課程/來源/方向菜單；V1 不注入控制器，沿用既有選擇與提交行為。

控制器區分 `defaultContext`、`current` 和按字段的手動覆寫集合；覆寫即使恰好等於預設，也不隱式重新跟隨。reset 才清空覆寫。預設來源仍以既有 `defaultSourceType` 為唯一持久化值，重啟時尊重恢復後的來源；新增課程/方向以帶 version 的 `captureContextDefaults.v1` 保存。非法類型/未知枚舉/未知版本顯示警告並使用安全回退，啟動不覆寫損壞原值，使用者明確更新 Settings 後才替換。

可見表單按課程 ID 集合變更 reconcile；保存前再次從當前 ModelContext 取得課程 ID，不依賴 popover 是否開啟。消失的引用清為 nil 並保留可見警告，不選第一個同名或相鄰課程。保存前才發現 current 課程刪除則拋錯，不在使用者不知情時改成另一份上下文提交。Domain 交易仍作最終課程存在性與寫入屏障校驗。

`request` 同步複製原文、note、courseID、sourceType、LookupIntent 和 CaptureSurface，產生新的 captureID；主/浮窗都把不可變 request 交給唯一 queue。解析方向由 `LookupIntent.resolvedDirection` 集中路由到凍結的 `LookupDirectionDetectorV1` 或顯式方向，畫面提示與保存不使用兩套規則。既有記錄/草稿、解析嘗試和備份均沿用 A02 的持久化捕獲字段；修改當前值或預設不能回寫排隊內容。

這批不修改 V1/V2 快照 bytes/checksum 契約。新增 defaultCourse/intent 尚不隨邏輯備份恢復，current 永不備份；B08 要用顯式版本化 adapter 擴充偏好白名單並驗證舊快照，未完成前禁止宣称最終偏好恢復驗收。細節和測試見 [B02 共享上下文證據](qa/2026-10-08-b02-capture-context.md)。

### 捕獲結果與窗口路由（B02 第三批）

V2 queue 在本地命中或完成分析的交易保存成功後，發出不可變 `CaptureFeedbackEvent`，包括 preview、保存時方向、captureID、入口及 `inputRecord(UUID)`/`vocabulary(UUID)` 目標。冪等提交重送、失敗保存、過期/取消的分析不發新成功事件。`latestAIExplanation` 僅為兼容保留，V2 畫面不再直接讀它。

`CaptureFeedbackHub` 弱持有每個窗口的 `CaptureResultPresentation`，沒有事件快取。主窗口按視圖生命週期訂閱，panel 由 controller 持有 presentation；兩者都用窄 AppKit bridge 觀察可見、最小化、關閉和鍵盤焦點，popover 只貢獻焦點、不擁有父面板可見性。隱藏時清結果及焦點，恢復/暫停清理在 queue 層執行，不依賴主窗口是否存在。浮窗以 systemUptime 和可注入 sleep 實作剩餘時計，token 拒絕遲到回調；取消 Task 之外仍檢查可見性/焦點及單調期限。

`CaptureResultActions` 每個浮窗一份，由 QuickAddPanelController 持有，英文投影來自實際結果行。Pasteboard 只在点击時寫入；`SystemCaptureSpeech` 使用 AVSpeechSynthesizer 和可用 Apple 英文 voice，排除 Personal Voice 與第三方 provider。每次朗讀有獨立 request UUID 及 delegate，不將非 Sendable AVSpeechUtterance 傳過 executor；遲到完成不能停止新一筆。presentation 的 onResultChange 在替換/隱藏/到期清理時同步 reset，立即停止舊音頻，不依賴 SwiftUI 是否重繪。聲音列表與合成只在點擊後使用，沒有下載或錄音入口。

`CaptureResultNavigator` 弱持有主窗口 endpoint，按最近活動順序選一個；沒有 endpoint 才透過已註冊的 SwiftUI openWindow action 建立主窗口。待開請求不能被第二次点击取代，恢復開始時取消。每個 ContentView 自持 `CaptureNavigationState`，進入前先走原有 WordNoteEditProtection；Inbox/Vocabulary 只消費一次對應 ID，固定詳情與原列表選擇分開，因此當前已打開目標頁的搜尋及 Handled 篩選不會把目標替換成鄰居。不新增已銷毀頁面的歷史篩選持久化。缺失 ID 顯式呈現不可用。此橋接不接管 NSWindowDelegate，避免覆蓋 A04 關窗保護。

浮窗最大高度取目前 NSScreen.visibleFrame 減 36 pt 邊距；測量內容仍完整，超限使用內部滾動。跨螢幕/螢幕可用區變更重新限制 frame，保留右上錨點並避免底部越界。原生 completion 容器保留未挂載時的焦點請求，控制器在顯示時同步設置 initialFirstResponder/firstResponder；不以固定 sleep 修補焦點競態。詳見 [第三批驗證](qa/2026-10-08-b02-capture-feedback.md)。

搜索 matcher、補全與精確去重仍分開；列表按穩定 ID 更新，不因篩選改變錯配選中項。性能先測現有查詢與生成資料，再決定索引/分頁/搜索快取；不能為預估大資料量先引入向量庫。時計、Calendar、網絡、store 路徑和偏好可注入，測試不用 sleep 等待真實 10 分鐘。
