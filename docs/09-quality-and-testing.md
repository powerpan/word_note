# 09. Quality And Testing

## 質量目標

MVP 的質量重點：

- 原始輸入不丟失。
- AI 失敗不阻塞手動整理。
- 保存到詞庫的資料可持久化。
- 復習排程可預測。
- API Key 不泄漏。

## 測試分層

### Unit Tests

覆蓋純邏輯：

- normalizedTerm。
- InputRecord 狀態流轉。
- CandidateTerm 到 Term 的轉換。
- duplicate detection。
- duplicate Quick Add hit priority bump。
- review scheduler。
- adaptive review scheduler。
- AI response parser。
- validation rules。

### Integration Tests

覆蓋服務協作：

- Save & Analyze 成功。
- Save & Analyze 失敗。
- Save & Analyze 精確命中既有 Term 時不調用 AI。
- Candidate save to Term。
- Term delete。
- Review feedback update。
- duplicate hit 後 Term 進入今日待復習。
- Settings API Key 存取可用臨時 env 文件。

### UI Tests

首版最少覆蓋：

- Quick Add 保存 draft。
- Save & Analyze mock 成功後進入 Candidate Review。
- 保存候選後 Vocabulary 出現詞條。
- 完成一張 Review 卡片。

### Manual QA

每個 milestone 完成後執行手動回歸清單。

## 核心測試用例

### AI Parser

#### Word

Input:

```text
regularization
```

Expected:

- inputType = word。
- 至少一個 candidate。
- candidate.term = regularization。
- needToLearn = true。

#### Phrase

Input:

```text
latent representation
```

Expected:

- inputType = phrase。
- 第一候選為完整短語。
- 不把 latent 作為主要高優先級候選。

#### Sentence

Input:

```text
The model learns a latent representation of the input data.
```

Expected:

- inputType = sentence。
- sentenceMeaning 非空。
- 包含 latent representation。
- 不包含 the、a、of。

#### Invalid JSON

Input:

```text
Malformed response containing non-JSON text, for example: "json block marker followed by invalid content"
```

Expected:

- parser throws schemaMismatch 或 invalidResponse。
- InputRecord 可標記 failed。
- App 不崩潰。

## Review Scheduler Tests

| feedback | expected mastery | expected interval |
|---|---|---|
| again | vague | 1 day |
| hard | vague | 3 days |
| good | familiar | 7 days |
| easy | mastered | 14 days |

還要測：

- reviewCount + 1。
- wrongCount 在 again/hard 時 + 1。
- lastReviewedAt 更新。
- ReviewEvent 建立。

P1 自適應排程還要測：

- good 連續答對時 correctStreak + 1。
- good/easy 根據 correctStreak 拉長 reviewIntervalDays。
- again/hard 重置 correctStreak。
- mastered 詞條 again 後降為 vague。
- nextReviewAt 不會早於 tomorrow，除非是 duplicate hit 主動加入今日復習。

## Duplicate Quick Add Hit Tests

輸入既有詞：

```text
regularization
```

前置：Term.normalizedTerm = `regularization`。

Expected：

- 不建立新的 InputRecord。
- 不建立 CandidateTerm。
- 不調用 AICompletionClient。
- UI preview 使用既有 Term.chineseMeaning。
- Term.nextReviewAt = now。
- Term.importance 最多提升一級。
- familiar/mastered 命中後降為 vague，new/vague 命中後不被提高。
- duplicateHitCount + 1。
- 超過冷卻窗口時 wrongCount + 1。
- 冷卻窗口內重複命中不重複增加 wrongCount。

## Persistence Tests

要求：

- 建立 Course 後可查詢。
- 建立 InputRecord 後重啟 store 仍存在。
- CandidateTerm 與 InputRecord 關聯正確。
- Term 與 Course 關聯正確。
- 刪除 Course 被引用時被阻止。
- 刪除 Term 時 ReviewEvent 按策略處理。

## Security Tests

手工和自動檢查：

- API Key 不存在於 SwiftData store。
- API Key 不存在於導出 JSON/CSV。
- 錯誤日誌不包含 API Key。
- AI request debug log 不包含完整 rawText。

## 手動回歸清單

### Quick Add

- 空輸入時 Save disabled。
- 只填 raw text 可保存。
- 選課程後保存關聯正確。
- Save 後輸入框清空。
- Save & Analyze 在 API Key 缺失時提示設置。
- 輸入既有 Term 時直接顯示既有釋義。
- 輸入既有 Term 時不新增 Inbox 記錄。
- 輸入既有 Term 時該詞出現在今日 Review。

### AI

- 成功解析 word。
- 成功解析 phrase。
- 成功解析 sentence。
- 網絡失敗後 InputRecord 保留。
- Retry 可再次請求。

### Candidate Review

- 默認勾選合理。
- 可取消候選。
- 可編輯候選字段。
- 保存後生成 Term。
- 忽略後不生成 Term。

### Vocabulary

- 搜索可找到詞條。
- 編輯後更新。
- 刪除後列表移除。
- 按 course 篩選正確。

### Review

- due term 出現在今日待復習。
- Show Answer 展示背面。
- 四種反饋均能完成。
- nextReviewAt 更新。
- 中文 -> 英文模式展示中文提示並在背面展示英文答案。
- 空格和 1/2/3/4 快捷鍵可用。
- 完成頁展示本輪統計。

## Definition Of Done

一個功能完成需要滿足：

1. 有對應文檔或文檔已更新。
2. 主要成功路徑可用。
3. 至少一個失敗路徑被處理。
4. 核心邏輯有單元測試。
5. 本地資料不會因錯誤操作丟失。
6. UI 有 loading、empty、error state。

## MVP Release Gate

MVP 可以交付前必須通過：

- 所有 unit tests。
- Save & Analyze 三個標準樣例。
- AI failure regression。
- persistence restart test。
- API Key leakage check。
- 手動完整閉環：Quick Add -> AI -> Candidate Review -> Term -> Review。
