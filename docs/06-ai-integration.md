# 06. AI Integration

版本說明：原有 schema/prompt 為当前基線；文末「2026-10 補充契約」定義 B02 的方向持久化與 C02 的 analysis schema v2，尚未上線。資料 schema 與 AI schema 是不同版本體系。

## 目標

AI 集成的目標是把用戶輸入的英文內容，或中文查英文意圖，轉換成可確認、可編輯、可保存的英文候選詞條。AI 不直接決定最終詞庫內容。

## DeepSeek 集成原則

- 使用服務抽象，不把 DeepSeek API 細節散落在 UI。
- API Key 存在本機 env 文件，並可從進程環境變量兜底讀取。
- 請求超時必須可配置。
- 所有 response 必須經過 schema validation。
- JSON 解析失敗時不丟失 InputRecord。
- 實施前應核對 DeepSeek 官方當前 API 文檔；本文件只定義 App 內部契約。

目前客戶端使用 `deepseek-v4-flash`，並顯式發送 `thinking.type = disabled`。查詞是結構化抽取任務，預設關閉思考以降低延遲；若後續切換模型或開啟思考，必須更新請求契約測試與 live smoke test。

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
| lookupDirection | 本地識別的 englishToChinese / chineseToEnglish；默認由 rawText 推導 |

### AIAnalysisResult

| 字段 | 說明 |
|---|---|
| inputType | word/phrase/sentence/paragraph/unknown |
| sentenceMeaning | 英文查中文時為中文含義；中文查英文句子/段落時為完整英文表達 |
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
| term | 非空；中文查英文時必須含英文字母且不能含漢字 |
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
9. 中文查英文時，中文輸入是 source meaning，所有 `items[].term` 必須是英文，`chinese_meaning` 解釋英文候選。
10. 多個英文候選只在語義、語域或專業用法確有差異時返回，最自然常用的候選排第一。

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
- Lookup direction: {{lookupDirection}}
- Course: {{courseName}}
- Source: {{sourceType}}
- User note: {{userNote}}
```

## 本地預處理

發送前可做輕量預處理：

- trim。
- 限制最大長度。
- 偵測空輸入。
- 按 Han scalar 與 ASCII 字母數量識別查詢方向。
- 查詢 Term.normalizedTerm 是否精確命中既有正式詞條。
- 偵測過長段落並提示用戶縮短。

目前 rawText 上限為 8,000 個字符；超過上限在網絡請求前返回 typed error。

不要在本地做複雜 NLP 拆詞，避免與 AI 判斷衝突。

### DeepSeek 跳過條件

Save & Analyze 前必須先執行正式詞庫精確命中檢查：

```text
normalized(rawText) == Term.normalizedTerm
```

只有英文查中文執行此精確命中。中文查英文必須建立 Inbox 記錄，不以中文釋義模糊命中正式詞庫。

若英文輸入命中：

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

## 非阻塞分析佇列

- 點擊 Save & Analyze 或在浮窗回車後，先持久化 `InputRecord.status = analyzing`，UI 立即恢復可輸入狀態。
- 佇列按建立時間依序處理，一筆失敗只把該記錄設為 failed，後續記錄繼續。
- App 啟動時恢復所有 analyzing 記錄，避免重啟後丟失待處理請求。
- 同一 normalizedText 已處於 analyzing 時返回 `alreadyQueued`，不建立第二筆記錄、不發第二個請求。
- 分析完成後寫入 Inbox 候選，主窗口與浮窗都使用同一個臨時釋義 preview。

## 去重策略

候選層：

- 同一次 response 中相同 normalizedTerm 只保留一個。
- 優先保留 needToLearn=true 或 confidence 更高者。

詞庫層：

- 英文查中文 Save & Analyze 前優先查正式 Term，精確命中則跳過 AI；中文查英文不短路。
- 保存 CandidateTerm 為 Term 前檢查現有 Term.normalizedTerm。
- MVP 提示已存在，不強制合併。
- P1 增加合併流程；但 Quick Add 的精確命中短路不等待合併功能。

重複命中後的釋義 preview 應復用 AI preview 結構，使主 Quick Add、浮窗 Quick Add 和菜單欄入口顯示一致。

### 中文查英文結果校驗

AI JSON 解析完成後執行方向校驗：

- `term` 至少包含一個 ASCII 英文字母。
- `term` 不得包含 Han scalar，禁止 `overfitting（過擬合）` 這類中英混合主體。
- `chinese_meaning` 必須非空。
- 不合格候選可被移除；全部不合格時返回 schemaMismatch，原 InputRecord 標記 failed 並保留在 Inbox。
- Candidate Review 保存前由 VocabularyService 再次執行英文主體校驗。

## 成本控制

目前策略：

- 支持連續快速提交，但 worker 依序發送請求，避免無上限併發。
- 不在用戶未確認時反覆重新生成。
- 已存在詞條精確命中時不調用 DeepSeek。

P1 可加入：

- 可配置的佇列併發與退避策略。
- 每日 token 使用估算。

## Live 測試閘門

`swift test` 默認不發真實 DeepSeek 請求。只有設置 `RUN_LIVE_DEEPSEEK_TESTS=1` 時，`LiveDeepSeekSmokeTests` 才會執行付費網絡測試；其餘 URLSession 契約測試使用本地 mock。

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

## 2026-10 補充契約

### V2 隔離隊列已實作的錯誤邊界（A02、B01）

- HTTP 客戶端繼續請求 `deepseek-v4-flash`、關閉 thinking，未在此批更換 prompt/分析 schema。服務回傳 model 另記，不把請求別名當作實際回傳值。
- HTTP 429/5xx 讀取 Retry-After 的非負整數秒或 HTTP-date；兼容舊 HTTP-date 格式及兩位年份規則。格式依據：[RFC 9110 Retry-After](https://www.rfc-editor.org/rfc/rfc9110.html#name-retry-after)。超大秒數保留為很晚的人工重試期限，不溢出成即時重試。
- 連線/超時/429/5xx 在持久化預算內最多自動重試兩次，基準 2/4 秒，絕不縮短有效服務端等待。超過 60 秒不自動等待重發，failed 保存最早人工重試時間。
- 401/403/缺 key、其他 4xx、錯誤 envelope/JSON/schema/空結果不自動重試。成功 HTTP 的 envelope 解碼失敗不再誤分為 network。URLSession 取消保持取消語義，不進入網絡退避。
- 不保存或展示原始 HTTP 錯誤 body、URLSession 診斷內容；保存靜態分類摘要和 HTTP 狀態碼。資料保存/世代檢查失敗暫停隊列，保留原輸入及中斷狀態，需要明確恢復。
- 重新分析不覆寫同名既有候選的內容，臨時預覽顯示實際保留/新增的候選值，而非展示未被接受的新字段。完整差異採納仍屬 C02。

此隊列已接到隔離 V2 QA 的三個入口，普通 App 仍是 V1，不把隔離結果描述成正式 UI 已完成。V2 付費 smoke 使用獨立 `RUN_LIVE_DEEPSEEK_V2_TESTS=1`，每輪上限兩次請求，固定公開輸入，內存庫驗證候選持久化、人工確認及重查本地命中；不觸碰真實詞庫。見 [隊列證據](qa/2026-10-08-a02-analysis-queue.md) 與 [QA App 接入](qa/2026-10-08-a02-app-integration.md)。

### V3 分析與正式復習隔離

V3 有獨立內容 writer/queue，沿用上面的持久預算和錯誤分類，不改 provider/prompt。attempt 額外核對完整 InputRecord/RecordState，防止來源被修改但 revision 未推進時仍保存舊回答。AI 分析只產生候選；人工確認才建立英文 Term 和一張 new 卡。精確重查只產生 lookup/priority，正式復習才產生 version=2 事件，不再增加 Term 混合 wrongCount。

`RUN_LIVE_DEEPSEEK_V3_TESTS=1` 是獨立 opt-in；測試在隔離內存庫使用 `latent representation`、`過擬合`，handler 最多發兩次真實請求。2026-10-08 這一輪通過分析、雙向人工確認、重送/本地命中、正式復習和完整備份往返。請求配置仍為 `deepseek-v4-flash`，本次 provider 回報 `deepseek-flash`，兩次合計約 6.44 秒；不據此推斷其他模型品質/價格或 60 例語義評測通過。token usage 沒有在本測試暴露，費用不估算。詳見 [V3 流水線證據](qa/2026-10-08-b03-v3-content-pipeline.md)。

### 方向和輸入邊界（A03、B02）

請求新增 lookupIntent（auto/englishToChinese/chineseToEnglish）、已解析 lookupDirection、detectorVersion、analysisGeneration。方向提交時解析並落庫；重試使用凍結值。用戶改方向屬顯式重新分析，增加 generation、保留已保存候選，不能把正在執行的請求悄悄改向。

自動識別不宣稱能準確理解所有中英混合內容；主/浮窗提供手動覆寫。中文查英文仍產出英文 term；整句英文答案獨立於候選。只查中文含義時不做中文子串匹配後自動認定為某個既有英文，避免一個中文概念錯配多個英文。候選英文確認時才走 A05 的精確關聯。

AI 請求只包含當次原文、必要的課程/備註和用戶選定內容。文字、來源 URL 和例句均是資料，不能當作系統指令；不因輸入含 URL 自動訪問網頁或外部服務。字符/請求大小沿用明確限制，超限先本地提示，不暗中截斷。

### Analysis Schema v2（C01、C02）

仍使用 input_type、sentence_meaning、items 外層，增加顯式版本、方向及義項陣列。以下只是結構示例，不限定每詞只能有一個義項：

```json
{
  "analysis_schema_version": 2,
  "lookup_direction": "englishToChinese",
  "input_type": "word",
  "sentence_meaning": null,
  "items": [
    {
      "term": "pixel",
      "term_type": "word",
      "need_to_learn": true,
      "importance": "medium",
      "category": "CV",
      "reason": "An image representation term.",
      "should_auto_select": true,
      "context_sense_key": null,
      "senses": [
        {
          "sense_key": "s1",
          "kind": "technical",
          "part_of_speech": "noun",
          "chinese_meaning": "像素，數碼影像中可獨立表示顏色或亮度的圖像單元。",
          "english_definition": "A picture element in a digital image.",
          "example_sentence": "Each pixel stores color information.",
          "collocations": ["pixel value", "pixel density"]
        }
      ]
    }
  ]
}
```

義項契約：

- 覆蓋真正常用本義；有詞性差異或不同常用意思時分項，不限定一兩項，不為湊數拆同一意思。
- kind=general 或 technical；legacy 只由本地遷移產生，模型不可產出。天生專業詞可只含 technical，不虛構普通義。
- AI/CS 義與普通義實質不同才新增，不能每個詞都以「在 AI 語境中」開頭。上下文對某義的應用不必另造一義。
- 每義 chinese_meaning 非空；英文定義、詞性、例句可空，不知道不編造；搭配陣列可空。原句與模型例句不得混作同一字段。
- sense_key 只在單次 item 內唯一，context_sense_key 必須指向該 item 的有效 key；本地保存時分配正式 UUID。
- 有可靠英文原句才選 context_sense_key；查單個詞、中文意圖不明或多義皆可時保留 null，不能假裝語境已知。
- term 必須含英文字母且無漢字，允许專業符號；各寫入路徑重复校驗，不能以 should_auto_select 代替人工確認。
- request 與 response direction 不符、缺必要字段、非法枚舉、重複 key、引用不存在或超出資源限制時整個結果失敗，不把局部殘缺響應當成功。
- 不用小固定義項數限制語義。仍設總字節/解析深度安全上限；輸出被 token 限制截斷時明示不完整、保留原輸入並允許用戶重試，不靜默省略含義。

舊 schema v1 只由版本化解析器/快照適配器處理，不能把 v1 任意字串按分號猜成 v2。資料 V4 可以先閱讀 legacy 義項，再逐步啟用 v2；持久化遷移本身不調用 AI。

### 重新生成與人工修訂（C02）

1. 用戶明確選擇詞條/義項與重新生成的字段，展示將發送的範圍。
2. 請求使用當時 baseRevision；結果保存為 proposed ContentRevision，不直接寫正式內容。
3. 差異界面區分保留、增加、修改、刪除建議。人工字段預設保留，補空字段也需接受；不可把每個同義表述都新增成義項。
4. 預覽期間正式內容變動時重新比較，不把 stale proposal 覆寫過去。
5. 接受後原子更新內容、兼容摘要和修訂狀態；拒絕/取消/超時不改正式字段。不自動改 mastery、卡片啟用或排程。

每個生成記錄 model ID、promptVersion、analysisSchemaVersion、生成時間與來源類型。模型自報 confidence 不顯示成「準確率」，也不作繞過人工確認的閘門。

### 固定品質評測（C02）

建立可提交的去私人化 fixture 與人工審定期望，每組可包含多個合理答案；不能只用當前模型輸出當標準答案，也不能以完全相同措辭判分。

| 分組 | 數量 | 核心檢查 |
|---|---:|---|
| 常見多義詞 | 10 | 如 stage、class、state、issue；本義覆蓋而非只說技術義 |
| 主要單義詞 | 8 | 無實質多義時不硬湊，不為每詞附加 AI 段落 |
| 專業義與普通義 | 8 | 如 attention、token、regularization；技術區分正確 |
| 短語與自然表達 | 8 | 如 all sorts of、in terms of；不機械拆詞 |
| 中文查英文 | 8 | 單詞、短語、一對多；英文主體與自然表達 |
| 中英混合與歧義 | 8 | 自動方向、手動覆寫、未知語境保留不確定 |
| 句子/段落 | 10 | 整句含義、上下文命中義項、不提取大量功能詞 |
| 合計 | 60 | 固定 ID、來源說明、期望常用義與不可接受項 |

分兩個閘門：

1. 硬性契約：全部固定 mock 用例的 schema、英文主體、方向、冪等與人工內容保護 100% 通過；live 有任一中文主體或污染人工內容即阻塞切換。
2. 語義品質：每例按常用義覆蓋、正確性、專業義必要性、自然英文、上下文忠實度五項評 0/1/2（不適用項標 N/A）；正確性及常用義適用時必須 2，其餘適用項至少 1，才算該例通過。至少 54/60 通過，每組不低於 80%；相同固定樣本相比基線，核心錯義/漏常用義的修正比例不得增加。

來源答案由可信詞典/課程上下文核對並記錄來源，不大量複製受版權保護的釋義。主觀項至少一輪盲評，爭議標出後人工裁決；不把单次模型偏好評分當成客觀勝出。60 例只能用作回歸和小樣本對照，不能宣稱覆蓋所有單詞或確定優於基線。

在同一模型和生成參數下先比較 prompt/schema；評估換模型再固定同一題集與流程。記錄測試日期、實际模型、配置、失敗數、p50/p95 延遲、可用 token usage 與人工修正量。服務未提供用量時記 unavailable，不猜價格或費用。

日常測試全部 mock。付費 smoke 維持 `RUN_LIVE_DEEPSEEK_TESTS=1` 顯式閘門；60 例批評測另需明確樣本範圍、請求/金額預算和 opt-in，不能因機器已有 key 自動跑。未達標保留舊模型/prompt 為預設，修訂後重跑；不批量更新用戶現有詞庫。

### 按需練習與連接測試（B08、C04）

連接測試是用戶觸發的獨立小請求，明示會發送網絡請求；不夾帶私人詞庫，返回實際模型、時間及可理解的錯誤類型，不顯示鑰匙。配置變更後舊「成功」標為歷史結果，不能冒充新配置已驗證。

近義辨析、自然表達及單題填空/造句只發選定內容，生成結果清楚標 AI 建議。不完整答案或多種合理表達交由用戶判斷，模型不自動累加錯題。取消、失敗及忽略不改正式詞庫或排程。離線時既有詞庫、確定性填空與普通復習繼續可用。
