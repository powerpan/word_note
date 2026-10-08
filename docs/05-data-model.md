# 05. Data Model

版本說明：原章節為 V1 現行模型；文末「2026-10 補充契約」定義 V2/V3/V4 目標，尚未遷移。任務與啟用時機見 [13](13-supplemental-development-plan.md)。

## 設計原則

1. 原始輸入和詞條分離。
2. AI 候選和最終詞條分離。
3. 所有可復習內容都落到 Term。
4. AI 失敗不能破壞 InputRecord。
5. 所有用戶可編輯內容都應有 updatedAt。
6. 儘量保存上下文，避免只留下孤立單詞。

## 實體總覽

```text
Course 1 --- n InputRecord
Course 1 --- n Term
InputRecord 1 --- n CandidateTerm
InputRecord 1 --- n Term
Term 1 --- n ReviewEvent
```

## InputRecord

記錄用戶最初輸入的英文內容。

| 字段 | 類型 | 必填 | 說明 |
|---|---|---|---|
| id | UUID | yes | 主鍵 |
| rawText | String | yes | 用戶原始輸入 |
| normalizedText | String | yes | 去空格和大小寫規範化後文本 |
| inputType | InputType? | no | AI 或本地判斷結果 |
| status | InputRecordStatus | yes | draft/analyzing/analyzed/completed/failed/ignored |
| sentenceMeaning | String? | no | 英文查中文時為整句中文含義；中文查英文時為完整英文表達 |
| courseID | UUID? | no | 所屬課程 |
| sourceType | SourceType | yes | class/paper/slides/assignment/book/other |
| note | String? | no | 用戶備註 |
| aiErrorSummary | String? | no | AI 失敗摘要 |
| analyzedAt | Date? | no | 最近一次解析時間 |
| createdAt | Date | yes | 建立時間 |
| updatedAt | Date | yes | 更新時間 |

### InputRecordStatus

| 狀態 | 說明 |
|---|---|
| draft | 已保存，尚未解析 |
| analyzing | 正在解析 |
| analyzed | 已生成候選，等待處理 |
| completed | 候選已全部保存或忽略 |
| failed | 解析失敗，可重試 |
| ignored | 用戶忽略，不再出現在 Inbox |

## CandidateTerm

保存 AI 返回的候選結果。CandidateTerm 不是正式詞條，只有被用戶保存後才生成 Term。

| 字段 | 類型 | 必填 | 說明 |
|---|---|---|---|
| id | UUID | yes | 主鍵 |
| inputRecordID | UUID | yes | 所屬原始輸入 |
| term | String | yes | 候選詞條 |
| normalizedTerm | String | yes | 規範化 term，用於去重 |
| termType | TermType | yes | word/phrase/expression/sentencePattern |
| needToLearn | Bool | yes | AI 是否建議學習 |
| importance | Importance | yes | low/medium/high |
| category | TermCategory | yes | general/academic/aiML/dl/nlp/cv/math/programming |
| reason | String? | no | 建議學習或不學習原因 |
| chineseMeaning | String? | no | 中文解釋 |
| englishDefinition | String? | no | 英文定義 |
| aiContextExplanation | String? | no | AI / CS 語境說明 |
| exampleSentence | String? | no | 例句 |
| relatedTerms | [String] | yes | 相關詞 |
| confidence | Double | yes | 0 到 1 |
| status | CandidateStatus | yes | pending/saved/ignored |
| createdAt | Date | yes | 建立時間 |
| updatedAt | Date | yes | 更新時間 |

### CandidateStatus

| 狀態 | 說明 |
|---|---|
| pending | 等待用戶處理 |
| saved | 已保存為 Term |
| ignored | 已忽略 |

## Term

正式詞條，進入詞庫和復習系統。

| 字段 | 類型 | 必填 | 說明 |
|---|---|---|---|
| id | UUID | yes | 主鍵 |
| term | String | yes | 詞、短語、表達或句型 |
| normalizedTerm | String | yes | 用於搜索和去重 |
| termType | TermType | yes | 詞條類型 |
| chineseMeaning | String? | no | 中文解釋 |
| englishDefinition | String? | no | 英文定義 |
| aiContextExplanation | String? | no | AI / CS 語境說明 |
| exampleSentence | String? | no | 英文例句 |
| contextSentence | String? | no | 原始上下文 |
| courseID | UUID? | no | 所屬課程 |
| sourceRecordID | UUID? | no | 來源 InputRecord |
| sourceType | SourceType | yes | 來源 |
| tags | [String] | yes | 標籤 |
| category | TermCategory | yes | 類別 |
| importance | Importance | yes | 重要度 |
| masteryLevel | MasteryLevel | yes | new/vague/familiar/mastered |
| reviewIntervalDays | Int | yes | 當前復習間隔，P1 自適應排程使用 |
| correctStreak | Int | yes | 連續答對次數，P1 自適應排程使用 |
| reviewCount | Int | yes | 復習次數 |
| wrongCount | Int | yes | 錯誤次數 |
| duplicateHitCount | Int | yes | Quick Add 精確命中既有詞條次數 |
| lastDuplicateHitAt | Date? | no | 最近一次重複輸入命中時間 |
| lastReviewedAt | Date? | no | 上次復習時間 |
| nextReviewAt | Date? | no | 下次復習時間 |
| createdAt | Date | yes | 建立時間 |
| updatedAt | Date | yes | 更新時間 |

Term 最低要求：

- `term` 必填。
- `chineseMeaning` 和 `englishDefinition` 至少一個非空。

P1 遷移要求：

- `reviewIntervalDays` 默認 0。
- `correctStreak` 默認 0。
- `duplicateHitCount` 默認 0。
- `lastDuplicateHitAt` 默認 nil。
- 遷移後現有 Term 的 `nextReviewAt` 不應被改動。

## Course

| 字段 | 類型 | 必填 | 說明 |
|---|---|---|---|
| id | UUID | yes | 主鍵 |
| courseName | String | yes | 課程名稱 |
| courseCode | String? | no | 課程代碼 |
| instructor | String? | no | 老師 |
| semester | String? | no | 學期 |
| description | String? | no | 說明 |
| createdAt | Date | yes | 建立時間 |
| updatedAt | Date | yes | 更新時間 |

刪除規則：

- 若課程已被 InputRecord 或 Term 引用，MVP 不允許直接刪除。
- P1 可以加入「刪除並清空引用」或「合併到其他課程」。

## ReviewEvent

每次復習都記錄一條事件，便於後續統計。

| 字段 | 類型 | 必填 | 說明 |
|---|---|---|---|
| id | UUID | yes | 主鍵 |
| termID | UUID | yes | 詞條 |
| mode | ReviewMode | yes | englishToChinese/chineseToEnglish/contextCloze |
| feedback | ReviewFeedback | yes | again/hard/good/easy |
| previousMasteryLevel | MasteryLevel | yes | 復習前掌握程度 |
| newMasteryLevel | MasteryLevel | yes | 復習後掌握程度 |
| previousNextReviewAt | Date? | no | 復習前排程 |
| newNextReviewAt | Date? | no | 復習後排程 |
| reviewedAt | Date | yes | 復習時間 |

Duplicate Quick Add hit 不等同於一次正式 Review。P1 首版可以只更新 Term 統計和排程，不強制寫 ReviewEvent；若後續需要審計來源，再增加 `ReviewEventSource` 或獨立 `TermActivityEvent`。

## 枚舉

### InputType

```text
word
phrase
sentence
paragraph
unknown
```

### TermType

```text
word
phrase
expression
sentencePattern
```

### SourceType

```text
class
paper
slides
assignment
book
other
```

### Importance

```text
low
medium
high
```

### MasteryLevel

```text
new
vague
familiar
mastered
```

### ReviewFeedback

```text
again   // 完全不會
hard    // 模糊
good    // 記得
easy    // 很熟
```

## 規範化規則

`normalizedTerm` 和 `normalizedText`：

- trim 前後空白。
- 合併連續空白為一個空格。
- lowercased。
- 保留必要符號，例如 `L1`, `L2`, `self-attention`。

不應做過度 stemming，避免把專業術語錯誤合併。

## 重複輸入命中規則

Quick Add / 浮窗 Quick Add 的本地命中只使用精確 normalizedTerm：

```text
normalized(rawText) == Term.normalizedTerm
```

命中後：

- 不創建 InputRecord。
- 不創建 CandidateTerm。
- 不調用 DeepSeek。
- 使用既有 Term 的 `chineseMeaning`、`englishDefinition`、`aiContextExplanation` 組裝臨時釋義 preview。
- `nextReviewAt = now`，使詞條進入今日待復習。
- `importance` 最多提升一級：low -> medium -> high。
- 若 `masteryLevel` 為 familiar/mastered，降為 vague；new/vague 保持不提高，表示用戶再次遇到且需要復習。
- `duplicateHitCount + 1`。
- 若距離 `lastDuplicateHitAt` 超過冷卻窗口，`wrongCount + 1`；冷卻窗口建議 10 分鐘。

## 索引建議

首版建議優化：

- Term.normalizedTerm。
- Term.courseID。
- Term.masteryLevel。
- Term.nextReviewAt。
- InputRecord.status。
- CandidateTerm.inputRecordID。

## 遷移原則

資料模型使用 `WordNoteSchemaV1` 和 `WordNoteMigrationPlan` 顯式版本化。當增加、重命名或刪除持久化字段時，必須新增 schema version 和可測試的 migration stage，不能直接修改既有版本的語義。

遷移要求：

- 新字段優先可空或有默認值。
- 不在小版本中刪除用戶資料。
- 任何破壞性遷移前先做導出或備份。
- 無分代清單時沿用 `~/Library/Application Support/WordNote/WordNote.store`。A01 恢復接入後由 `store-generations.json` 選擇受控 `Stores/<UUID>/WordNote.store`；原庫與上一代保留，不能固定打開舊路徑繞過恢復日誌。
- 若只存在歷史 `~/Library/Application Support/default.store`，首次啟動先完整複製 store、WAL、SHM 到 `WordNote/Backups/`，再複製到新位置；舊檔保留不刪除。
- App 啟動後清理沒有 InputRecord 的 CandidateTerm、沒有 Term 的 ReviewEvent，並清空指向不存在 Course/InputRecord 的可空外鍵。
- `WordNote` 和 `Backups` 目錄使用 `0700`，store 與 sidecar 文件使用 `0600`。

## 刪除與重試一致性

- 刪除 InputRecord 時，刪除它的全部 CandidateTerm，並把仍存在 Term 的 `sourceRecordID` 清空；不刪除已確認 Term。
- 刪除 Term 時，級聯刪除對應 ReviewEvent。
- 刪除 Course 仍採引用保護，不自動清空關聯。
- 重試 AI 分析時，保留已保存 CandidateTerm，刪除其餘舊候選，再寫入新的去重候選，避免同一記錄反覆累積結果。
- 批量確認 CandidateTerm 必須全量預驗證並單次保存，禁止部分成功。

## 2026-10 補充契約

### 版本與唯一資料來源

| 版本 | 主要任務 | 新增/調整 | 讀寫切換 |
|---|---|---|---|
| V1 | A01 | 不改模型，先提供完整邏輯快照 | 仍用現有模型 |
| V2 | A02 | 來源、課程關聯、查詢事件、方向與 revision | 課程/來源新写入使用關聯表；舊復習規則暫留 |
| V3 | B03/B04 | ReviewCard、會話、事件語義版本 | B03 遷移與 B04 新規則一同啟用，禁止 Term/Card 雙排程寫入 |
| V4 | C01/C02 | 義項、候選義項、內容修訂 | 義項為內容權威，舊字串成兼容投影；AI schema 升級分開驗證 |

先凍結 `WordNoteSchemaV1` 的真實模型定義。每版持有自己的歷史類型形狀；不能只改版本號卻讓所有版本指向最新類別。V1 fixture 必須由基線版本產生，不能由新模型現造「舊庫」。遷移只讀本地，不發 AI 請求。

2026-10-08 隔離實施：五個既有模型已收進 `WordNoteSchemaV1` 命名空間，頂層別名仍指向 V1；字段和既有業務方法不變。`WordNoteSchemaV2` 另持有八個模型，尚未接入 App。原始 V1 SQLite fixture 的校驗碼不變，完整字段對比和 V2 臨時庫重開測試見 [A02 記錄](qa/2026-10-08-a02-isolated-foundation.md)。

### V2：捕獲與關聯

下表為必需字段；所有新實體另有 UUID 主鍵及必要建立時間。業務唯一鍵在單一寫入協調器內校驗，採用存儲層唯一限制前須驗證最低系統兼容性。

| 實體/字段 | 契約 |
|---|---|
| InputRecord.captureID | 一次用戶提交的穩定 UUID；重試分析不換 ID，不同提交即使字串相同也不同 |
| InputRecord.capturedViaRaw | legacy / mainQuickAdd / floatingQuickAdd / manual；提交時保存，建立 occurrence 時複製，不能在重啟後猜測來源窗口 |
| InputRecord.lookupIntentRaw | auto / englishToChinese / chineseToEnglish，記錄用戶選擇 |
| InputRecord.resolvedLookupDirectionRaw | 實際發送方向，與 detectorVersion 一起凍結；重試不能因新版偵測規則改方向 |
| InputRecord.directionDetectorVersion | 本地規則版本；顯式方向也保留解析來源標記 |
| InputRecord.analysisGeneration / attemptID / queueState | 重分析世代、單次網絡嘗試 ID、none/queued/running/failed/cancelled；與整理 status 分開 |
| InputRecord.autoRetryCount / nextAttemptAt | 跨重啟保留自動重試次數與退避；中斷恢復使 generation 失效但不重置次數。取消後仍可保留等待期限，避免重新排隊繞過 Retry-After |
| InputRecord / Candidate / Term / Course.revision | 從 0 開始的整數，服務成功修改後 +1，作草稿/預覽 optimistic concurrency 檢查 |
| Candidate.savedTermID | 保存/關聯到的 Term ID；pending/ignored 為 nil，saved 可因後續明確刪詞而置 nil 並標記目標已刪除 |
| Candidate.savedLinkState / confirmationOperationID | none/resolved/unresolvedLegacy/targetDeleted；最近成功確認操作 ID。重試同一已完成操作返回既有結果，不再次寫入 |
| Candidate.analysisGeneration | 候選所屬分析世代，保護已保存候選不被重試清空 |
| TermOccurrence | termID、captureID、sourceRecordID?、rawTextSnapshot、note?、courseID?、sourceType、occurredAt、capturedVia、legacy；來源 title/url/page 皆可空 |
| TermCourseLink | termID、courseID、createdAt；唯一 `(termID, courseID)`，表示当前整理關係 |
| LookupEvent | termID、captureID、occurrenceID?、occurredAt、kind=exactRepeat；唯一 `(termID, captureID)`，不保存憑據或網絡 response |
| Term.counterSemanticsVersion | 遷移先標 legacyMixed；B04 才切換新統計，不能在 A 階段改變現行反饋 |

Occurrence 的業務唯一鍵為 `(termID, captureID)`。一條原句生成兩個詞時各有一個 occurrence；同一提交因重試或雙擊不能重複建關聯。已存候選重新分析不代表再次遇見，不增加 occurrence。主動再查同詞是新 capture，允許新增一次 LookupEvent 和來源。

精確命中仍不建立 InputRecord/Candidate、不進 Inbox、不調用 AI；直接保存 occurrence、查詢事件及必要課程關聯。候選確認只是關聯已有詞時新增 occurrence，不把它再虛構成一次 exactRepeat。預覽、朗讀、打開詳情及補全均不是查詢事件。

2026-10-08 隔離服務已實作上述捕獲和單項確認交易，詳見 [內容交易記錄](qa/2026-10-08-a02-content-transactions.md)。捕獲入口標記現亦保存在 InputRecord 及 V2 快照元資料；來源有 sourceRecordID 時，其 captureID/capturedVia 必須與記錄一致。歷史轉換一律 legacy；新提交不允許自行偽裝成 legacy。V2 尚未正式啟用，這次補充不改凍結的 V1 類型或 fixture。

版本化備份入口現已保留完整八實體與元資料；`WordNoteBackupCounts` 用於混合版本摘要及 version 2 切庫日誌，不取代 V1/V2 快照各自凍結的 on-disk counts。V1 reader 明確拒絕 V2，不能用 `payload.content` 當作完整備份或恢复。后台 V2 捕獲亦不會自動保存未經服務 revision 校驗的直接模型修改。詳見 [版本化備份記錄](qa/2026-10-08-a02-versioned-backups.md)。共用日誌/staging 已完成隔離 [版本化恢復](qa/2026-10-08-a02-versioned-restore.md) 及 [受保護啟動遷移](qa/2026-10-08-a02-startup-migration.md)，正式 App 接入仍待完成。遷移意圖與失敗恢復標記屬於 version 2 日誌，不修改歷史實體或復習語義。

相同 captureID 的重送必須保留原文、note、課程、來源類型和入口；已有 InputRecord 還須保持原查詢意圖，返回當前任務狀態而不自動重新分析。已刪 occurrence 但仍有 LookupEvent 的重送被拒絕，不恢復被明確刪掉的來源。此保護基於仍在庫中的記錄/事件，不承諾在全部相關資料明確刪除後永久保存提交收據。

舊 Term.courseID 只保留為兼容/遷移快照，V2 起頁面篩選與批量操作讀 TermCourseLink，不再兩處獨立編輯。舊 contextSentence/sourceRecordID 保留原值但新來源讀 occurrence。歷史來源課程與當前 membership 是兩個概念，解除 membership 不刪歷史 occurrence。

V1 回填規則：

1. 有合法 courseID 則建立一條 membership；無效外鍵產生修復報告，不猜另一門課。
2. 來源仍存在時用原 InputRecord 作快照；僅有 contextSentence 時生成 legacy occurrence 並標記時間/來源來自歷史字段；沒有任何來源則不偽造遇見記錄。
3. legacy captureID 根據既有來源 ID 或 Term ID 的固定映射一次產生並持久化，重跑不增加記錄。
4. 舊 InputRecord 用基線偵測規則回填方向，意圖為 auto，保留算法版本；重試時使用已保存值。
5. saved 候選只有在來源/規範化詞頭能唯一對應時回填 savedTermID；有歧義保留 unresolvedLegacy 狀態與報告，不能任意選一個 Term。
6. Term ID、Candidate ID、ReviewEvent ID 及原始文本不改寫；舊 wrongCount 繼續保留，直到 V3 啟用時凍結歷史快照。

隔離轉換的具體規則：

- 遷移 UUID 用固定 `wordnote/v1-to-v2/1` 命名空間、實體用途及原有 ID 作域分隔 SHA-256 映射；結果取 16 bytes 並設 UUID version 8/variant bits。此規則只用於 legacy 回填，新提交仍用新 captureID。沒有可還原到每次提交的歷史證據時，不從 `duplicateHitCount` 偽造 LookupEvent。
- 自動方向固定為 `han-latin-v1`；顯式方向的解析來源為 `explicit-v1`。`capturedViaRaw` 支持 legacy/mainQuickAdd/floatingQuickAdd/manual，遷移來源一律 legacy。
- 原 `analyzing` 轉成整理狀態 draft + queueState queued，原 `failed` 轉成 draft + failed；錯誤摘要和原始文字保留，沒有網絡 attemptID。已有候選、analyzedAt 或 analyzing/failed 記錄的 generation 初始化為 1，其餘為 0；這不代表重建歷史嘗試次數。啟動接入時仍必須遵守恢復/遷移後暫停分析的閘門。
- 歷史 confirmed operationID 沒有證據，保持 nil；唯一來源/詞頭匹配才填 savedTermID。來源的歷史課程來自 InputRecord，當前 membership 來自 Term.courseID，不因兩者不同而覆寫。
- dangling course/source、孤立 Candidate/ReviewEvent 產生帶 ID 的阻塞報告，不先調用破壞性 repair，也不猜外鍵；此版本不自動繞過這些問題。`sourceRecordID == nil` 且有非空 contextSentence 才可直接使用 legacy context fallback，原文空白字符仍保留。
- 轉換為純值運算，同一輸入不受 fetch 順序影響；寫庫只能到空的 V2 目標庫，重複寫入同一非空庫被拒絕。這是隔離轉換的冪等保護，尚不是已接入正式啟動的完整遷移流程。

### 確認與內容保護

ConfirmationPlan 是非持久化值，包含 operationID、選中記錄/候選 ID、預期 revision、規範化詞頭及 new/link/fill/ignore/conflict 分類。重新預覽可產生新方案，但一次提交 operationID 保持不變。

既有重複詞默認 link，只增加來源/課程；fill 顯示逐字段差異並由用戶選擇。批內同 normalizedTerm 建一個 Term，只有所有衝突已解決才提交。同音異義等不同意思在 C 階段成同一詞頭的不同義項，在 A/B 不自動以拼接文字「合併」，需要用戶指定內容。

Term、Candidate 狀態、savedTermID、membership、occurrence 單次保存；失敗全部回滾。英文字母、必要符號及數字可存在詞頭（如 C++、L2），不允許純中文主體；旧不合格 Term 提示人工修正，不因遷移被刪除。

A02 的單項 link 保留已有正式字段及復習統計，只在新增來源/課程時增加 Term.revision；同一 capture 的第二個同詞候選不重建 occurrence。候選和其 InputRecord 的整理狀態/revision 隨確認保存；queued/running 記錄不允許同時確認。英文主體及中文查英文所需中文釋義的校驗使用記錄已凍結的方向，不重新偵測原文。

A05 已在隔離 V2 核心與 QA 界面接入 ConfirmationPlan，不新增 schema 或快照字段。newTerms 計唯一新 Term；linkedCandidates 計連向既有詞及同批新詞的其餘候選，不是 occurrence 數；ignoredCandidates 是正式轉為 ignored，不是保留 pending。已解決方案中 `newTerms + linkedCandidates + ignoredCandidates == candidates`，存在衝突時差額為 unresolvedCandidates。supplementedTerms 計至少一個顯式字段真正改變的既有詞，與 links 有重疊，不可相加當總量。

fill 只支持中文、英文、技術釋義和例句；每字段選一個非空候選值，未選字段、主體、人工標籤、分類、重要度及復習排程/統計完全保留。新詞衝突的主候選同時決定詞型、分類、重要度及主要來源；所有被納入候選的獨立來源與課程仍保存。同 capture 同詞只一個 occurrence。

批次 saved 候選的 confirmationOperationID 實際存放 SHA-256 派生的 UUID token，綁定 plan.operationID、穩定排序的目標/候選/最終字段/忽略集合；相同語義重送不二次建詞，更改選擇不冒充原操作。ignored 的 savedTermID、confirmationOperationID 仍為 nil，savedLinkState 仍為 none；精確終態重試可零寫入返回，但不作持久操作所有權聲明。方案本身不跨 App 重啟持久化；恢復後候選 saved/ignored 狀態和 token 保留，不能重新作為 pending 建詞。證據見 [A05](qa/2026-10-08-a05-confirmation-preview.md)。

A04 [運行期撤銷](qa/2026-10-08-a04-safe-undo.md) 不新增持久表或改 schema：receipt 只留受影響實體的局部 DTO、操作 ID 和前後引用狀態。只可刪本次新建且之後未改/未被引用的 Term/Course/關係；舊詞和原始輸入不因撤銷確認被級聯刪除。還原值時 revision 繼續增加，lookup/review 事件不得反向清除；重啟後不保留 receipt，亦不能把局部 DTO 當完整快照恢復。

A06 的批量整理沿用 V2 schema，不新增表或快照字段。課程關係以 `(termID, courseID)` 唯一，當前 membership 與 `Term.courseID` 的捕獲來源快照分開；解除課程不清除 occurrence 或來源歷史。標籤匹配鍵只做去首尾、合併空白和大小寫不敏感；既有拼寫、順序及未改的重複值不被整批規範化重寫。新增標籤合併空白、保留大小寫，每個 1 至 80 個 Swift Character，不含非空白控制字符；逗號是標籤內容，不自動拆分。既有較長標籤仍可讀取/移除；結果陣列不超過既有快照的 10,000 項上限。

預覽的 changedTerms 計唯一實際改動詞，課程增減按 membership 數，標籤增減按每詞的規範鍵數，不能把 legacy 同鍵重複陣列元素算多次。移除同鍵時清掉該鍵的所有拼寫，加入已存在鍵不重寫舊值；同一鍵同批增減拒絕。一次提交每個實際改動詞只增一次 revision，no-op 不改 updatedAt。近期/反復活動只由有效 exactRepeat LookupEvent 投影，對同詞同 captureID 去重，不借用 legacyWrongCount/duplicateHitCount 偽造事件。見 [A06](qa/2026-10-08-a06-vocabulary-reading.md)。

隔離 V2 分析交易已新增：running 必須有 attemptID；nextAttemptAt 只允許 queued/failed/cancelled，cancelled 中的值只約束下一次人工重試，不代表仍有自動工作。完成清除 attemptID/deadline，queueState 回到 none，整理 status 按候選是否尚待處理設 analyzed/completed；失敗不抹除既有整理狀態。全部字段和候選同次保存，存儲失敗回滾。

重新分析保留所有同 normalizedTerm 的既有候選，不覆寫人工內容、不改 savedTermID/confirmationOperationID，也不復活 targetDeleted；只有新主體新增候選。pending 候選在完成/失敗/取消/中斷恢復後帶到當前 analysisGeneration 並增加 revision，避免保留的候選無法再確認。這是 C02 差異採納前的保守行為，不沿用上文 V1「刪除其餘舊候選」策略。資料證據見 [V2 分析隊列](qa/2026-10-08-a02-analysis-queue.md)。

### V3：卡片與會話

| 實體 | 核心字段與約束 |
|---|---|
| ReviewCard | termID、mode、contentScopeKey、phase、masteryLevel、intervalDays、confidentStreak、lapseCount、nextReviewAt?、priorityRequestedAt?、introducedAt?、lastReviewedAt?、relearningDayKey?、relearningRepeatCount、buriedUntil?、clozeTarget?、revision、schedulerVersion；唯一 `(termID, mode, contentScopeKey)` |
| ReviewSession | scopeSnapshot（課程/模式/隊列）、targetCardCount、newCardLimitSnapshot、status、currentItemID?、createdAt、updatedAt、endedAt?、revision；只保留一個可恢復的活動會話 |
| ReviewSessionItem | sessionID、cardID?、originalCardID、position、status、attemptCount、availableAt?、lastActionID?、completionOutcome?；唯一 `(sessionID, originalCardID)`，目標刪除時保留不可用項但解除 cardID |
| ReviewEvent 擴展 | cardID?、sessionID?、actionID?、feedbackSemanticsVersion、schedulerVersion、studyDayKey、studyTimeZoneID、before/after 排程快照、clockAnomaly?、invalidatedAt?；新事件的 actionID 必填且唯一 |
| Term 歷史快照 | legacyWrongCount、legacyReviewCount、legacyDuplicateHitCount、legacySnapshotAt；完整保留切換前混合計數，不標成新版實際錯題 |

phase 為 new/review/relearning/suspended；contentScopeKey 在 V3 為 wholeTerm 或 cloze:<穩定目標 ID>，V4 才增加 sense:<UUID>。B06 的 clozeTarget 包括 occurrenceID、原文 hash、Unicode 安全範圍與答案形式；不能等到 V4 才補 B06 所需字段。新事件由正式反饋產生；Later/Skip/Lookup 不建 ReviewEvent。`introducedAt` 在第一次正式展示新卡時與會話項狀態一起保存，使切換會話不能繞過新卡配額。

揭示答案時將已啟用 sibling 的 buriedUntil 保存為次日本地日開始，並把本組相應項標為 siblingDeferred；此為防洩題狀態，不寫作答事件。重學中的同一卡不視為自己的 sibling。暫時埋藏不改原間隔，次日自動恢復資格。

V1/V2 -> V3：每個 Term 的舊排程只複製至一張主卡，方向取最後有效事件，無事件則 englishToChinese。nextReviewAt 為 nil 的主卡保持 suspended；不要自動激活。其他方向歷史事件保留原 mode/ID，cardID 可為 nil 並標 legacy；不為補齊外鍵建立一批到期卡。未見過的方向按新卡啟用，不借用另一方向 streak 或掌握程度。

舊 ReviewEvent 不補造 actionID、會話、作答時間或語義；feedbackSemanticsVersion=1。新版統計只採 version=2。Term 舊排程字段只作遷移快照，不再參與 due/filter；詞條層的 UI 摘要從各已啟用卡計算並顯示方向，不把一張卡的 easy 宣稱為整詞全部掌握。

持久化會話只保存 ID 和必要快照，不複製整份詞義。單窗口寫入租約為進程內協調狀態，App 重啟可重新取得，不能因舊 PID 永久鎖住。正式評分、卡片排程、session item 與游標在同一交易提交。

### V4：義項與版本

| 實體 | 核心字段與約束 |
|---|---|
| TermSense | termID、displayOrder、kind（general/technical/legacy）、partOfSpeech?、chineseMeaning、englishDefinition?、exampleSentence?、collocations、revision、provenance、archivedAt?；ID 不因排序改變 |
| CandidateSense | candidateID、以上內容字段、responseLocalKey、matchedByContext；正式確認後複製內容至 TermSense，不把外部 key 當正式 UUID |
| ContentRevision | termID、senseID?、baseRevision、fieldChanges、origin（manual/ai/legacy）、status（proposed/accepted/rejected）、modelID?、promptVersion?、analysisSchemaVersion?、createdAt、acceptedAt? |
| ReviewCard 擴展 | senseID?；既有 wholeTerm/cloze 卡保留原 contentScopeKey，新的 sense 卡按義項 ID 唯一 |

原 Term 的 chineseMeaning、englishDefinition、aiContextExplanation、exampleSentence 完整保存在 legacy 修訂快照；原中文文本不拆分，包為一個 legacy sense。無任何釋義內容時不建立空 sense；僅有英文定義等舊內容時允許 legacy sense 的中文為空，新建 general/technical sense 則中文必填。空字段保持空，不用 AI 補齊。舊技術說明也原樣留在快照及兼容閱讀區，不假裝已拆成驗證過的新義項。

接受新版義項後，Term 的摘要字段只能由統一投影函數更新，不允許 UI 同時編輯兩份內容。新 AI 建議帶 baseRevision，已有人工改動時重新比較；接受、拒絕和逐字段選擇均可追溯。歷史全文只保存在本地，禁止進入日誌。

舊 wholeTerm 卡 ID、排程和歷史不變，多義項不自動生成多張卡。用戶明確啟用 sense/cloze 卡後才受新卡配額管理。原句變動導致 hash/範圍失效時停用該填空目標並要求修正，不用錯位片段繼續出題。

### 刪除、遷移與恢復不變量

- 刪 InputRecord：刪其候選/候選義項，清空外鍵；已確認詞和 occurrence 的原文快照保留。UI 必須說明這不是刪除所有已入庫來源內容。
- 刪 occurrence：刪該來源並解除 LookupEvent.occurrenceID，可保留無原文的查詢事實；依賴它的 cloze 卡停用，不改人工釋義。
- 刪 Term：級聯其義項、卡片、ReviewEvent、ContentRevision、來源、membership、LookupEvent；清空對應 savedTermID，活動會話項標 targetDeleted 並解除 cardID，不計作完成。
- 刪 sense：有活動卡或會話引用時阻止直接刪除，先停用卡並明確處理引用；不要把 sense 級歷史偷偷轉為另一個意思。允許封存代替刪除，保留歷史可讀內容。
- 刪 Course：對 membership、InputRecord 和歷史 occurrence 均顯示引用數；必須先解除或保留可讀的課程快照，不能默默改成另一課程。本輪默認延續引用保護。
- 所有版本的快照包含當時全部實體及相應關係；只有白名單非機密偏好，無 Key/env。
- 每次遷移先做保護快照、預檢、隔離副本轉換和完整性比對；遇衝突或不足磁碟停在舊庫，不先跑「清理」刪掉可恢復資料。
- 下行回退使用舊版可讀的遷移前快照，不能让舊二進制直接讀新 schema；回退會丟失快照後改動，必須先導出目前庫並提示差異。

### 完整性報告與修復預覽

V2 檢查不沿用 V1 的刪孤兒行策略，依 [完整性實施記錄](qa/2026-10-08-a02-integrity.md) 分三類處理：

| 問題 | 行為 |
|---|---|
| Term/Occurrence 的可選來源記錄不存在；LookupEvent 的可選 occurrence 不存在 | 可產生解除該外鍵的副本方案；保留詞義、原文、筆記、事件、課程、ID 和行數；同一受影響 Term 只增加一次 revision |
| 必需目標/課程缺失、孤立候選/事件、重複 ID/業務鍵、元資料缺失、來源對應衝突、候選 saved 狀態衝突 | 列 ID/字段/問題類別並阻止自動修復，不刪行、不猜另一個目標，不把缺失詞條偽裝成用戶已刪除 |
| legacy 中文主體、unresolvedLegacy 候選、同規範詞頭的多個歷史詞 | 保留並警告；不憑空修改內容或解決歧義，結構合法時仍可備份 |

先在副本上模擬允許的外鍵解除，再做完整字段校驗，避免第一個 missingReference 掩蓋非法日期、計數或未知狀態。仍有任何阻塞項時不生成半修復資料。預覽後的任何內容/關係/revision/非機密偏好變化均使方案過期，不只檢查時間戳。

修復結果只允許交給隔離空庫及共用切庫機制；[隔離啟動修復](qa/2026-10-08-a02-startup-repair.md) 已接入原始證據保護、staging 與 journal，仍沒有在原容器上套用修復的方法，沒有正式修復 UI 或自動執行入口。非法引用連同八實體及元資料保存在獨立 evidence 文件，不冒充可直接恢復的 backup；普通 reader 仍拒絕它。原庫和證據文件保留、不自動輪替。V1 App 啟動現改為只讀引用檢查，發現斷鏈即停止正常寫入並保留資料，不再靜默清理。
