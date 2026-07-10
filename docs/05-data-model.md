# 05. Data Model

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
| sentenceMeaning | String? | no | AI 對整句或整段的中文含義 |
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
- 正式 store 固定在 `~/Library/Application Support/WordNote/WordNote.store`。
- 若只存在歷史 `~/Library/Application Support/default.store`，首次啟動先完整複製 store、WAL、SHM 到 `WordNote/Backups/`，再複製到新位置；舊檔保留不刪除。
- App 啟動後清理沒有 InputRecord 的 CandidateTerm、沒有 Term 的 ReviewEvent，並清空指向不存在 Course/InputRecord 的可空外鍵。
- `WordNote` 和 `Backups` 目錄使用 `0700`，store 與 sidecar 文件使用 `0600`。

## 刪除與重試一致性

- 刪除 InputRecord 時，刪除它的全部 CandidateTerm，並把仍存在 Term 的 `sourceRecordID` 清空；不刪除已確認 Term。
- 刪除 Term 時，級聯刪除對應 ReviewEvent。
- 刪除 Course 仍採引用保護，不自動清空關聯。
- 重試 AI 分析時，保留已保存 CandidateTerm，刪除其餘舊候選，再寫入新的去重候選，避免同一記錄反覆累積結果。
- 批量確認 CandidateTerm 必須全量預驗證並單次保存，禁止部分成功。
