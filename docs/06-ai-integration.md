# 06. AI Integration

## 目標

AI 集成的目標是把用戶輸入的英文內容轉換成可確認、可編輯、可保存的候選詞條。AI 不直接決定最終詞庫內容。

## DeepSeek 集成原則

- 使用服務抽象，不把 DeepSeek API 細節散落在 UI。
- API Key 存在本機 env 文件，並可從進程環境變量兜底讀取。
- 請求超時必須可配置。
- 所有 response 必須經過 schema validation。
- JSON 解析失敗時不丟失 InputRecord。
- 實施前應核對 DeepSeek 官方當前 API 文檔；本文件只定義 App 內部契約。

## AIAnalysisService 介面

```swift
protocol AIAnalysisService {
    func analyze(_ request: AIAnalysisRequest) async throws -> AIAnalysisResult
}
```

### AIAnalysisRequest

| 字段 | 說明 |
|---|---|
| rawText | 用戶原始輸入 |
| courseName | 可選課程名 |
| sourceType | 來源 |
| userNote | 用戶備註 |
| preferredLanguage | 解釋語言，MVP 固定 zh-Hant 或 zh-Hans 需統一 |

### AIAnalysisResult

| 字段 | 說明 |
|---|---|
| inputType | word/phrase/sentence/paragraph/unknown |
| sentenceMeaning | 如果輸入是句子或段落，給出中文含義 |
| candidates | CandidateTerm draft |
| model | 使用模型 |
| rawResponseID | 可選 request id，不保存全文 |

## JSON Schema

AI 期望返回：

```json
{
  "input_type": "word",
  "sentence_meaning": "",
  "items": [
    {
      "term": "regularization",
      "term_type": "word",
      "need_to_learn": true,
      "importance": "high",
      "category": "AI/ML",
      "reason": "Core machine learning concept used to reduce overfitting.",
      "chinese_meaning": "正則化，用於限制模型複雜度並降低過擬合風險。",
      "english_definition": "A technique used to reduce overfitting by adding constraints or penalties to a model.",
      "ai_context_explanation": "Commonly appears in L1/L2 regularization and is often added as a penalty term to the loss function.",
      "example_sentence": "L2 regularization penalizes large weights in the model.",
      "related_terms": ["overfitting", "loss function", "L1 regularization", "L2 regularization"],
      "confidence": 0.93,
      "should_auto_select": true
    }
  ]
}
```

## 字段約束

| 字段 | 約束 |
|---|---|
| input_type | word/phrase/sentence/paragraph/unknown |
| sentence_meaning | sentence/paragraph 時建議非空 |
| items | 可以為空，但不能缺失 |
| term | 非空 |
| term_type | word/phrase/expression/sentence_pattern |
| importance | low/medium/high |
| category | general/academic/AI/ML/DL/NLP/CV/math/programming |
| confidence | 0 到 1 |
| should_auto_select | 只影響 UI 默認勾選，不代表自動保存 |

## Prompt 要求

系統提示詞應明確：

1. 你是 AI / CS 研究生英文學習助手。
2. 目標是提取值得學習的詞、短語、術語和固定表達。
3. 不要機械解釋所有單詞。
4. 短語和術語優先作為整體。
5. 普通詞若在 AI / CS 語境有專業含義，應提取。
6. 返回嚴格 JSON，不輸出 Markdown。
7. 候選數量要克制，通常 1 到 5 個。
8. 解釋要適合中文母語的 AI / CS 研究生。

## Prompt 模板

```text
You are an English learning assistant for a Chinese-native AI/CS graduate student.

Analyze the user's input in an AI/CS academic context.

Rules:
- If the input is a word, explain the word directly.
- If the input is a phrase, prioritize the phrase as one complete term.
- If the input is a sentence, explain the sentence meaning and extract only valuable terms, phrases, technical concepts, fixed expressions, or sentence patterns.
- Do not explain simple function words unless they have special AI/CS meaning in context.
- Prefer precise AI/CS explanations over generic dictionary meanings.
- Return strict JSON only. Do not wrap it in Markdown.
- Keep the candidate list concise.

User input:
{{rawText}}

Metadata:
- Course: {{courseName}}
- Source: {{sourceType}}
- User note: {{userNote}}
```

## 本地預處理

發送前可做輕量預處理：

- trim。
- 限制最大長度。
- 偵測空輸入。
- 查詢 Term.normalizedTerm 是否精確命中既有正式詞條。
- 偵測過長段落並提示用戶縮短。

不要在本地做複雜 NLP 拆詞，避免與 AI 判斷衝突。

### DeepSeek 跳過條件

Save & Analyze 前必須先執行正式詞庫精確命中檢查：

```text
normalized(rawText) == Term.normalizedTerm
```

若命中：

- 不發 DeepSeek request。
- 不建立新的 InputRecord。
- 不建立 CandidateTerm。
- 直接使用既有 Term 組裝釋義 preview。
- 更新該 Term 的復習優先級和重複命中統計。

若 rawText 是句子或段落，即使包含既有詞條，也不應使用包含匹配跳過 DeepSeek。只有完整輸入與既有 Term 完全一致才短路。

## 結果後處理

收到 AI response 後：

1. 移除可能的 Markdown code fence。
2. 嘗試 JSON decode。
3. 驗證必要字段。
4. 正規化枚舉值。
5. 補默認值。
6. 去除空 term。
7. 對 normalizedTerm 去重。
8. 保存為 CandidateTerm。

## 容錯策略

### API Key 缺失

- 不發請求。
- InputRecord 可保存為 draft。
- UI 引導到 Settings。

### 網絡錯誤

- status = failed。
- aiErrorSummary = network。
- 提供 Retry。

### Rate Limit

- status = failed。
- 提示稍後重試。
- 不自動循環重試。

### Timeout

- 默認 timeout 建議 30 秒。
- status = failed。
- 保留 Retry。

### Invalid JSON

- status = failed。
- aiErrorSummary = invalid_response。
- 不把完整 response 存入普通資料模型。

### Empty Candidates

- 若 sentenceMeaning 非空，仍保存分析結果。
- UI 提供 Add Term Manually。

## 去重策略

候選層：

- 同一次 response 中相同 normalizedTerm 只保留一個。
- 優先保留 needToLearn=true 或 confidence 更高者。

詞庫層：

- Save & Analyze 前優先查正式 Term，精確命中則跳過 AI。
- 保存 CandidateTerm 為 Term 前檢查現有 Term.normalizedTerm。
- MVP 提示已存在，不強制合併。
- P1 增加合併流程；但 Quick Add 的精確命中短路不等待合併功能。

重複命中後的釋義 preview 應復用 AI preview 結構，使主 Quick Add、浮窗 Quick Add 和菜單欄入口顯示一致。

## 成本控制

MVP：

- 不做自動批量分析。
- 每次 Save & Analyze 只分析當前輸入。
- 不在用戶未確認時反覆重新生成。
- 已存在詞條精確命中時不調用 DeepSeek。

P1 可加入：

- 未整理記錄批量分析。
- 每日 token 使用估算。

## 測試樣例

### Word

Input:

```text
regularization
```

Expected:

- input_type = word。
- items 至少包含 regularization。
- importance = high 或 medium。
- ai_context_explanation 提到 overfitting 或 penalty。

### Phrase

Input:

```text
latent representation
```

Expected:

- input_type = phrase。
- 第一候選 term = latent representation。
- 不把 latent 和 representation 作為主要候選。

### Sentence

Input:

```text
The model learns a latent representation of the input data.
```

Expected:

- input_type = sentence。
- sentence_meaning 非空。
- items 包含 latent representation。
- 不包含 the、a、of。
