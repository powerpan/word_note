# 09. Quality And Testing

版本說明：原有用例對應 V1/P1；2026-10 新任務用文末 QA-01 至 QA-38 追蹤。實施中的新證據見 [G00/A03 執行記錄](qa/2026-10-07-g00-a03.md)、[A01 核心資料保護](qa/2026-10-08-a01-persistence.md) 和 [A01 App 接入](qa/2026-10-08-a01-app-integration.md)，自動化通過不等於 UI 項已驗收。舊版 82 項結果是歷史證據，不能用作補充計劃已通過的證明。

A01 后台與性能證據：[后台資料工作](qa/2026-10-08-a01-background-persistence.md)，含當批 188 項嚴格離線回歸、獨立 live 與 1,000/10,000 詞各 30 輪 Release 測量；不代替後續 V2 性能或實機驗收。

A02 最新隔離證據：[V2 QA App 接入](qa/2026-10-08-a02-app-integration.md)，普通及 V2 QA 嚴格 Debug 全套均為 415 項中 412 通過、3 跳過，Release 定向 249 項通過；受控雙向 live 另行通過，僅兩次真實請求。新增 25 項覆蓋值草稿、revision、原子批量處理、版本化資料保護及旧復習兼容。隊列核心歷史證據見 [持久分析隊列](qa/2026-10-08-a02-analysis-queue.md)。QA 的 V1 -> V2 啟動已核對日誌和進程；普通 App 仍為 V1。Computer Use 仍回報 cgWindowNotFound，沒有本批 UI 驗收證據，不能沿用歷史鎖屏診斷。

A04 編輯保護證據：[未保存編輯與多窗口退出](qa/2026-10-08-a04-edit-protection.md)。新增 23 項：窗口草稿 13、多窗口退出 6、候選批量編輯 4。普通 Debug 及 V2 Debug/Release 完整回歸均為 438 項中 435 通過、3 跳過、0 失敗。涵蓋最後一次輸入、保存失敗、部分保存、外部刪除後草稿存活、取消不導航、新窗口加入退出檢查、同來源一次 revision 更新及失敗整批回滾。未重跑付費 live；本批不改 AI 協議。Computer Use 仍失敗，QA-02 的真實窗口/焦點/輸入法測試，以及 QA-09 的 undo/字段差異仍未驗收。

A04 撤銷子里程碑：[安全撤銷記錄](qa/2026-10-08-a04-safe-undo.md)。新增 31 項測試，覆蓋局部回退、revision 單調增加、單/批次確認、後續引用/查詢/復習拒絕、保存失敗回滾、舊操作 ID 拒絕及 SQLite 重開一致性。普通 Debug 及 V2 Debug/Release 完整回歸均為 469 項中 466 通過、3 跳過、0 失敗。該輪 Computer Use 仍為 cgWindowNotFound，不能把核心測試算成 QA-02/QA-09 實機通過。

A04 字段比較子里程碑：[三方比較與草稿回填](qa/2026-10-08-a04-field-comparison.md)。新增 29 項測試：16 項比較/字段覆蓋、13 項 V2 交易整合。涵蓋空字串、相同顯示名的不同課程、顯式衝突選擇、最後輸入/外部再次修改、只讀元資料、回填不寫庫、之後保存/撤銷保留先前外部改動、已處理/分析中的候選和手動來源保護。普通 Debug 及 V2 Debug/Release 全套均為 498 項中 495 通過、3 跳過、0 失敗；QA-02/QA-09 仍需實機驗收。

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
- vocabulary prefix completion matching and ranking。
- vocabulary English and normalized Chinese meaning search。
- appearance preference raw values and unknown-value fallback。
- Chinese/English lookup direction detection and English-subject validation。
- review scheduler。
- adaptive review scheduler。
- AI response parser。
- validation rules。

### Integration Tests

覆蓋服務協作：

- Save & Analyze 成功。
- Save & Analyze 失敗。
- Save & Analyze 精確命中既有 Term 時不調用 AI。
- 中文查英文不走英文 term 精確命中，建立 Inbox 記錄並保存英文候選。
- 中文查英文確認入詞本時 Term.term 為英文，中文原文只保留為 contextSentence。
- Candidate save to Term。
- Term delete。
- Review feedback update。
- duplicate hit 後 Term 進入今日待復習。
- Settings API Key 存取可用臨時 env 文件。
- analyzing 記錄在 App 重啟後恢復入隊。
- 同一輸入已排隊時不建立第二筆記錄。
- 一筆 AI 失敗後佇列繼續處理下一筆。
- AI 重試替換未保存舊候選，不累積重複資料。
- AI 重試數量只計實際新增待確認候選，不把已保存的歷史候選重算；臨時釋義仍可顯示本次分析結果。
- 同一 ModelContainer 的所有 context 在恢復期間拒絕寫入，其他隔離庫不受影響；取消恢復後舊 AI ticket 仍失效。
- 已排入 Task 但尚未開始的請求、延遲成功/失敗、忽略取消的 handler 均不能跨恢復屏障提交。
- 自動備份不依賴視圖存活，保存事件可觸發首次快照；恢復前保護備份失敗保留原庫，日誌狀態不明時保持寫入鎖定。
- 后台快照在同容器任意 context 保存/未保存修改時整次重試；其他容器保存不誤觸發，連續修改最多三次停止，取消不返回成功快照，每次讀取用新 context。
- 后台 staging 期間 MainActor 可處理其他工作；返回前重新核對日誌，取消或另一恢復先完成時不覆寫有效 pending/active 狀態。
- 批量確認先全量驗證，任一錯誤時不部分寫入。
- 刪除 InputRecord/Term 時按規則級聯或清空外鍵。

新增 V2 隔離覆蓋（不替代以上 V1 用例）：

- captureID 重送不重複發送，不同提交保留各自來源；輸入保存不等待前一筆 AI，正常單 worker 執行。
- 重新分析保留所有既有候選內容及 savedTermID；pending 在失敗/取消後仍可確認，不套用 V1 刪除未保存候選策略。
- begin/complete/fail/cancel 各自原子保存；保存故障回滾，暫停隊列，不為保存失敗重複付費；未提交人工修改不被回滾。
- record revision/generation/attemptID、恢復 ticket 及 store active/pending 檢查拒絕延遲回調；刪除或取消不復活記錄。
- 2/4 秒退避、兩次自動重試預算、60 秒自動等待上限；取消後仍遵守未到期 Retry-After，次數和 deadline 跨 SQLite 重開保留。
- 中斷先持久暫停再正規化，二次重啟仍不自動重放；暫停日誌/恢复授权保存失敗不發請求；新即時任務可喚醒退避中的 worker。
- HTTP envelope 格式失敗不歸為 network；取消/超時/離線分開處理，HTTP 錯誤 body 不出現在用戶錯誤摘要。
- V2 live 僅用兩個公開測試輸入和內存库；API 完成只進候選區，人工確認後再次精確查詢顯示本地釋義，請求數不增加。
- V2 QA 條件編譯復用全部頁面；唯一 queue 的捕獲/確認/精確重查與八實體備份串接。候選值草稿不改 context；批量新詞/忽略、課程/詞條編輯、feedback/postpone 在失敗時全量回滾。
- V1 controller 的版本化預覽仍拒絕 V2；V2 controller 不能代替未提交編輯保存，恢復前保護快照必須為 V2，導入 V1 後仍保持 V2，明確恢復前不自動發送 pending 工作。

### UI Tests

SwiftPM 目前沒有獨立 XCUITest target。以下流程由服務層整合測試、App 啟動驗證和發版前手動回歸共同覆蓋；若改用 Xcode project，應把它們升級為自動化 UI smoke tests：

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

| feedback | expected mastery | first expected interval |
|---|---|---|
| again | vague | 1 day |
| hard | vague | 1 day |
| good | familiar | 2 days |
| easy | mastered | 4 days |

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

## Vocabulary Completion Tests

核心 matcher 必須覆蓋：

- 少於 2 個字符時不提示。
- `qu` 可從 `quick` 得到灰色後綴 `ick`。
- 匹配大小寫不敏感，但接受後保留用戶已輸入的大小寫。
- 同時存在 `quick`、`quickly`、`quick sort` 時優先 `quick`。
- 後綴長度相同時使用穩定字母排序。
- 完整輸入、換行輸入、非前綴 substring 和空詞庫均不提示。
- 短語前綴可以補全，例如 `machine le` -> `machine learning`。

UI 手動回歸必須覆蓋：

- 主 Quick Add 和浮窗 Quick Add 都顯示相同補全。
- Tab 有建議時接受但不提交；無建議時移動到下一個焦點。
- Enter 仍按原有入口提交。
- Escape、光標移動、文字選區和輸入框失焦會隱藏灰色後綴。
- 中文輸入法輸入 `qui` 時，第一次 Enter 先提交 marked text 到輸入框，不觸發 Quick Add；組合結束後再次 Enter 才提交。
- 接受完整既有詞後提交，仍走精確重複命中，不調用 DeepSeek。

## Chinese-To-English Lookup Tests

核心與整合測試必須覆蓋：

- 純簡體、繁體中文識別為 `chineseToEnglish`，純英文識別為 `englishToChinese`。
- 中英混合輸入按 Han scalar 與 ASCII 英文字母數量穩定判斷。
- 中文查英文 prompt 明確要求所有 `items[].term` 為英文，`chinese_meaning` 為中文解釋。
- 模型返回中文 term 或中英混合 term 時不寫入 CandidateTerm；全部不合格時原 InputRecord 標記 failed。
- 中文輸入不走正式英文詞庫的 duplicate short circuit，先建立 analyzing InputRecord，完成後出現在 Inbox。
- 確認中文查英文候選時，Term.term 保存英文、Term.chineseMeaning 保存中文釋義、contextSentence 保留中文原文。
- Candidate Review 把 term 改成中文後，VocabularyService 拒絕保存且不部分寫入。
- Candidate Review 清空中文釋義後，即使仍有英文 definition，VocabularyService 也拒絕保存。

## Persistence Tests

要求：

- 建立 Course 後可查詢。
- 建立 InputRecord 後重啟 store 仍存在。
- CandidateTerm 與 InputRecord 關聯正確。
- Term 與 Course 關聯正確。
- 刪除 Course 被引用時被阻止。
- 刪除 Term 時 ReviewEvent 按策略處理。
- 舊 unversioned store 複製後可由 versioned schema 打開且資料保留。
- 遷移前建立備份，既有新 store 不被覆寫。
- 孤兒 CandidateTerm/ReviewEvent 被清理，懸空可空外鍵被清空。
- store 目錄和文件權限分別為 `0700` / `0600`。

## DeepSeek Contract Tests

- URL、Bearer header、model、`response_format` 與 `thinking.type = disabled` 使用 mock URLProtocol 驗證。
- 429 映射到 typed rate-limit error。
- rawText 超過 8,000 字符時不調用 client。
- `swift test` 不執行付費網絡請求；live smoke test 必須顯式設置 `RUN_LIVE_DEEPSEEK_TESTS=1`。

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
- 輸入正式詞條前綴時顯示灰色後綴，Tab 只補全不提交。
- 主 Quick Add 和浮窗 Quick Add 的候選與排序一致。
- 輸入 `過擬合` 時方向提示為 Chinese to English，提交後立即清空並建立 Inbox 記錄。
- 中文查英文不因詞庫已有相同中文釋義而跳過 DeepSeek。

### AI

- 成功解析 word。
- 成功解析 phrase。
- 成功解析 sentence。
- 網絡失敗後 InputRecord 保留。
- Retry 可再次請求。
- 中文查英文返回英文候選，第一候選為最自然常用表達；沒有真正差異時不硬湊多個候選。
- 中文查英文沒有合格英文 term 時顯示 failed，允許 Retry。

### Candidate Review

- 默認勾選合理。
- 可取消候選。
- 可編輯候選字段。
- 保存後生成 Term。
- 忽略後不生成 Term。
- 中文查英文時 term 編輯框預設為英文；改成中文後保存顯示英文主體校驗錯誤。

### Vocabulary

- 英文 term 和英文定義搜索可找到詞條。
- 簡體查詢可命中繁體中文釋義，繁體查詢也可命中簡體釋義。
- 中文搜索忽略釋義中的標點與空白，但不匹配無關詞條或只有標點的查詢。
- 編輯後更新。
- 刪除後列表移除。
- 按 course 篩選正確。
- 中文查英文確認後，詞條標題為英文，中文原文只出現在 context，中文釋義仍正常展示。

### Review

- due term 出現在今日待復習。
- Show Answer 展示背面。
- 四種反饋均能完成。
- nextReviewAt 更新。
- 中文 -> 英文模式展示中文提示並在背面展示英文答案。
- 空格和 1/2/3/4 快捷鍵可用。
- 完成頁展示本輪統計。

### Settings

- 跟隨系統、淺色、深色三種外觀均可選擇並在重啟後保留。
- 主窗口、獨立 Settings 窗口和 Quick Add 浮窗同步使用選定外觀。
- 切換外觀不影響當前導航、輸入內容、分析隊列或本地詞庫資料。

## Definition Of Done

一個功能完成需要滿足：

1. 有對應文檔或文檔已更新。
2. 主要成功路徑可用。
3. 至少一個失敗路徑被處理。
4. 核心邏輯有單元測試。
5. 本地資料不會因錯誤操作丟失。
6. UI 有 loading、empty、error state。

## 歷史驗證基線

2026-07-13 完整功能與文檔同步驗證：

- `swift test`：82 tests，0 failures；付費 live 測試按預設閘門跳過 1 項。
- `RUN_LIVE_DEEPSEEK_TESTS=1 swift test --filter LiveDeepSeekSmokeTests`：1 test，0 failures；同一閘門覆蓋英文查中文與中文查英文。
- `swift build -Xswiftc -warnings-as-errors`：通過。
- 全新 scratch path 的 `strict-concurrency=complete` + `warn-concurrency` + `warnings-as-errors`：通過。
- App bundle 啟動、首屏可訪問性樹、舊 store 備份/遷移、SQLite `quick_check`、孤兒資料修復與 `0700/0600` 權限：通過。

## MVP Release Gate

MVP 可以交付前必須通過：

- 所有 unit tests。
- Save & Analyze 三個標準樣例。
- AI failure regression。
- persistence restart test。
- API Key leakage check。
- 手動完整閉環：Quick Add -> AI -> Candidate Review -> Term -> Review。

## 2026-10 補充契約

### 測試環境與材料

- G00 記錄 commit、macOS、硬件、Swift/Xcode、locale、時區和 store schema；支持下限為 macOS 14。下限機器不可用時留待驗證，不宣稱覆蓋。
- 核心規則用 XCTest + 注入 Clock/Calendar/網絡/store 路徑；UI/焦點/全局快捷鍵用獨立 App 測試資料，加入可重現的自動化或實機腳本。現有 Core test target 不等於已有完整 UI 測試能力。
- 資料集包括空庫、由原版產生的 V1 fixture、V2/V3 遷移 fixture、人工修訂、重複候選、部分確認、無效關係、簡繁混合、長文本及 1,000/10,000 詞生成庫。真實用戶庫只在明確選擇的副本驗證，不上傳 fixture。
- UI 至少驗證 980x680、1320x800、1920x1080；淺/深色、繁/簡/英文、Retina、長課程名、中文 IME、VoiceOver、鍵盤導航。主窗口和浮窗分開覆蓋，不能只看首頁截圖。
- 所有新 schema 都有遷移前後逐 ID/字段/關係對照及 JSON 往返；保留可重跑故障注入點，而不只驗證 happy path。

### 需求測試矩陣

以下每行是測試組，不是單一測試函數數量；初始狀態全部為待執行。實施時在對應任務追蹤表鏈接具體測試、commit 和結果。

| QA | 任務 | 層級 | 必須驗證的結果 |
|---|---|---|---|
| QA-01 | WN2-G00、WN2-A03 | 展示模型 + UI | 中文單候選過擬合顯示 overfitting；英查中、多候選、整句、空結果和長句不隱藏英文答案 |
| QA-02 | WN2-G00、WN2-A04 | UI + 服務 | 編輯詞/課程/候選後切換、導航、關窗、退出；保存/放棄/取消各正確，取消不換選中項 |
| QA-03 | WN2-A01 | 集成 | V1 全量快照往返 ID、文本、狀態、關係、ReviewEvent 完全一致；API Key 不在快照 |
| QA-04 | WN2-A01 | 故障注入 | 損壞 checksum、未知新版、缺關係、磁碟滿及各切庫中斷點不破壞原庫；舊 AI 回調不能寫新庫 |
| QA-05 | WN2-A01 | 單元 + UI | 24 小時/變更條件/下次啟動補做、7 份輪替、保護快照不清除、導出範圍及 CSV 公式安全 |
| QA-06 | WN2-A02 | 遷移 | 真 V1 -> V2，course/context 保留，模糊 savedTermID 不亂連，第二次回填冪等 |
| QA-07 | WN2-A02 | 集成 | capture/lookup/occurrence/course 唯一鍵、方向凍結、刪除引用規則、V2 備份恢復及 legacy 計數不變 |
| QA-08 | WN2-A03 | 單元 + UI | 建詞、手動新增、改候選、編輯 Term 都拒絕中文主體；合法 C++/L2 可用；浮窗自適應與 10 秒失焦計時不回歸 |
| QA-09 | WN2-A04 | 交易 + 多窗口 | stale revision 阻止覆寫；三方字段比較、顯式衝突選擇與過期比較保護，回填不保存；編輯/確認撤銷可回到前值，後續依賴存在時不刪新資料；不承諾刪除/復習撤銷 |
| QA-10 | WN2-A05 | 單元 + 集成 | 批內/庫內同詞 new/link/fill/ignore 分類與記錄數/候選數/詞數正確，無未解決衝突才允許提交 |
| QA-11 | WN2-A05 | 故障注入 | 中途保存失敗全部回滾；雙擊/重啟後重試不再建詞，savedTermID、來源與關聯一致；過期預覽拒絕 |
| QA-12 | WN2-A06 | matcher + UI | 英文/簡繁中文搜索、18 字 Inbox 摘要保留、詞庫雙行與全文閱讀、來源/備註分離、長詞頭、空結果；交集篩選、近期/反復事件口徑、排序選中項穩定、切篩選清批選 |
| QA-13 | WN2-A06 | 服務 + UI | 批量加/解除課程及標籤的實際影響預覽；原子保存，不改詞義/來源/復習；取消無寫入、過期拒絕、保存故障回滾、no-op、單步撤銷 |
| QA-14 | WN2-B01 | 值投影 + 交易 + UI | 搜索/來源/課程/狀態交集；全選僅可見可處理項、換範圍清選、輸入/候選分計數；Handled 默認收起，推薦選擇不重置；部分處理留原項、全部處理選舊鄰項；忽略與撤銷保留既有關係 |
| QA-15 | WN2-B01 | queue + 集成 + UI | 三入口共用隊列；離線/429/超時/格式錯誤分類；退避與最多 2 次自動重試跨重啟保持；分析/整理狀態分離，忽略撤銷保留失敗/取消與 provider deadline；取消 running 使用凍結 revision 並提示可能計費 |
| QA-16 | WN2-B02 | 實機 | 其他 App 前台可用全局快捷鍵，重按切換隱藏；註冊衝突/停用可見，主/浮窗共用且凍結課程/來源/方向 |
| QA-17 | WN2-B02 | AppKit + UI | IME marked text 優先，Tab/Return/Command-Return 的語義、光標中間/選區/滾動、連續入隊及錯誤保留文字 |
| QA-18 | WN2-B02 | UI + 時計 | 複製英文、按需朗讀/停止/無聲音、跳轉正確記錄；聚焦暫停結果計時、舊結果不重播、無結果無空白 |
| QA-19 | WN2-B03 | 遷移 | 只遷一張主卡、其他方向不複製能力、nil 排程不激活；舊 event ID/mode 保留，新舊統計隔離 |
| QA-20 | WN2-B03 | 集成 | V3 快照包含卡/會話/事件，恢复不增加到期數；Term 排程只讀兼容，不存在雙寫者 |
| QA-21 | WN2-B04 | 純 scheduler | Again/Hard/Good/Easy 新語義、分鐘與日級 due、2 次再呈現上限、跨日/DST/時鐘倒退、預覽與保存一致 |
| QA-22 | WN2-B04 | 服務 | 重複查詢零 AI、保存 lookup/來源/優先請求，但不加 lapse/降 mastery/清 streak/抬 importance；不突破停用、重學及 sibling 限制 |
| QA-23 | WN2-B05 | 會話 + 故障注入 | 切頁/重啟/評分保存前後中斷可恢復，actionID 不重算；active/waiting/paused/completed/ended 狀態正確 |
| QA-24 | WN2-B05 | 多窗口 + 單元 | 每組 20 不同卡、每日新卡10上限、單寫入窗口；Skip/Later/刪詞不偽造完成，組外新詞不無限擴容 |
| QA-25 | WN2-B06 | 卡片 + UI | 方向獨立、正面不洩露英文、輸入焦點不触發評分；sibling 不當日照抄答案、無釋義禁用中文回憶 |
| QA-26 | WN2-B06 | 單元 + UI | cloze 的 Unicode 範圍、連字符/屈折/多處出現、原文改動停用、中文查詢不當英文原句、同義答案自行確認 |
| QA-27 | WN2-B07 | 統計單元 | 首事件成功率 n/N、0 樣本空值、重學答題/不同卡/完成量不混計、legacy/作廢事件排除、跨日/時區一致 |
| QA-28 | WN2-B07 | 路由 + UI | 首頁/課程/Review 同範圍同時計數一致，多課程全局去重；深鏈返回保留搜索/篩選/滾動 |
| QA-29 | WN2-B08 | 多窗口 UI | 單一 Settings、偏好同步、可拖列表/折疊側欄、三個窗口尺寸均無遮擋；恢復備份狀態可讀 |
| QA-30 | WN2-B08 | UI + 可訪問性 | 三語無漏 key、外觀中性深色/對比、長文本/大字體、tooltip/VoiceOver/鍵盤鏈可達全部主操作 |
| QA-31 | WN2-C01 | 遷移 | V3 -> V4 舊全文逐字保留、不拆分/調 AI/加卡；已有卡 ID/排程與歷史不變 |
| QA-32 | WN2-C01 | 集成 | sense ID 排序不變、引用保護、修訂/摘要單一來源、V4 快照完整往返、stale proposal 不覆寫 |
| QA-33 | WN2-C02 | mock 契約 | schema v2、方向、英文主體、sense key/引用、缺字段/截斷/超限/指令注入文本、人工字段100%保護 |
| QA-34 | WN2-C02 | opt-in live + 人工 | 60例固定分組品質與基線對照達06門檻；實際模型、延遲、失敗、usage/預算記錄；未達標不切預設 |
| QA-35 | WN2-C03 | 集成 + UI | 同詞兩課程仍一 Term，多次來源可見；解除 membership 不抹歷史，刪來源不改詞義，URL 不背景請求 |
| QA-36 | WN2-C04 | mock + UI | 辨析/表達/造句多合理答案不自判錯，最小資料外傳，失敗取消不改排程，正式反饋需明示及去重 |
| QA-37 | WN2-C05 | 離線評估 | 固定實作/授權與可重跑回放，新語義資料才用；不足明示、Go/No-Go 有依據，不自動改算法 |
| QA-38 | WN2-C06 | 端到端 + 交付核對 | V1/V2/V3 -> V4 + 恢復，捕獲到復習全路徑、多窗口/斷網/磁碟故障；代碼與測試完成後更新 README/實機截圖，再檢查最終待交付內容及本地可達 Git 歷史中的敏感資訊；各階段未過項不冒充完成 |

### 建置與性能閘門

A05 的 QA-10/QA-11 核心證據見 [確認預覽與原子提交](qa/2026-10-08-a05-confirmation-preview.md)：40 項新增測試覆蓋 new/link/fill/ignore、精確匹配及同名歧義、切換目標清除舊覆蓋選擇、計數、凍結方向、全量依賴預檢、零寫入重試、快照恢复、保存故障回滾及安全撤銷。這不等於多窗口彈窗、焦點和尺寸的 UI 驗收；普通 V1 啟動未切換。

A06 的 QA-12/QA-13 證據見 [詞庫閱讀與批量整理](qa/2026-10-08-a06-vocabulary-reading.md)：47 項功能回歸覆蓋搜索/篩選/排序/選擇、完整閱讀、來源投影、標籤規則、預覽/過期/回滾/no-op/撤銷。另有一項 opt-in 的純值索引性能組，命令為 `RUN_VOCABULARY_PERFORMANCE_TESTS=1 swift test -c release --filter VocabularyBrowsePerformanceTests`，合成 1,000/10,000 詞，預熱後各 30 輪，記錄建索引及英文/簡體中文/標籤排序的 p50/p95/max；不讀用戶庫、不發網絡請求。這組不包含 SwiftData 讀取或 SwiftUI 輸入/渲染，不能替代 200 ms 實機閘門。

B01 的 QA-14/QA-15 新增 34 項測試，見 [Inbox 決策工作流](qa/2026-10-08-b01-inbox-workflow.md)：13 項搜索/篩選/18 字預覽、10 項列表/候選選擇、11 項交易及 Undo 整合。先以失敗測試復現「忽略整條後撤銷遺失失敗/取消狀態與 provider deadline」，再修復還原字段；不允許靠撤銷繞過等待時間。沿用 A02 的三入口隊列/中斷測試，未新增付費 AI 請求。普通/V2 Debug 和 V2 Release 全套各 620 項中 616 通過、4 跳過；原生已核對全選/中文搜索清選、草稿 Cancel、單條/批量預覽、部分處理留項、最後一項處理後相鄰焦點及忽略 Undo。修正更多菜單拉伸和重複失敗提示後复查寬/窄窗口；工具後續連線中斷，不能宣稱深色、完整尺寸、慢網絡競態和其餘窗口交互已通過。

B02 第一批的 QA-16/QA-17 部分證據見 [全局快捷鍵與提交](qa/2026-10-08-b02-capture-shortcut.md)：新增 28 項，涵蓋配置/衝突/回滾/去重、恢復狀態的無窗口通知，以及 AppKit marked text、焦點、普通回車和 Tab 補全。原生註冊組必須顯式 `RUN_NATIVE_HOTKEY_TESTS=1`；它短暫註冊四修飾鍵加 F12，測同進程兩個 backend 的排他衝突、釋放及析構清理，不合成系統按鍵、不等同另一 App 前台的端到端驗收。Computer Use 本批在讀取 QA 首頁後中斷，設置及快捷鍵操作仍待驗證；共享捕獲上下文與 QA-18 尚未在這批實作。

B02 第二批的共享上下文證據見 [共享課程、來源與方向](qa/2026-10-08-b02-capture-context.md)：新增 17 項控制器測試與 6 項整合測試。包含按字段跟隨/覆寫、明確 No Course、重啟預設、損壞偏好不覆寫、刪課程回退/保存競態、兩入口連續入隊、草稿延後分析、精確命中不發 AI，以及 snapshot 和實際磁盤重開後的凍結元資料。Computer Use 已核對主窗口到浮窗、浮窗回主窗口的選擇同步、360x60 pt 收合和 Return 入隊；Settings 讀取時再次中斷，未驗證的尺寸、主題、實際 IME 和跨 App 操作不算通過。

B02 第三批的 QA-18 證據見 [結果生命週期與操作](qa/2026-10-08-b02-capture-feedback.md)：新增 59 項，涵蓋可見投遞/不重播、保存失敗不展示、凍結方向與目標 ID、單調失焦時計、popover 焦點持有、複製英文、朗讀/停止/無聲音/過期回調、隱藏結果同步停止音頻、單窗口路由與編輯保護，以及屏幕高度和同步首焦點。實機已核對連續排隊、主/浮窗臨時結果、英文複製粘貼、播放狀態、跨篩選的精確 Inbox/詞庫定位、關閉主窗口後重開及深色浮窗立即輸入不丟首字母；未完成的編輯頁/系統配置/多顯示器/IME 不能由替身測試推斷通過。Computer Use 崩潰診斷與應用狀態分開記錄。

B03 第一批 QA-19/部分 QA-20 證據見 [隔離 V3 模型與快照](qa/2026-10-08-b03-isolated-foundation.md)：新增 37 項，覆盖原版 V1 fixture 接續 V2 -> V3、最後事件/同時戳 tie-break、唯一主卡及 nil 排程、混合計數不推斷、十一實體磁盤重開、活動游標/已刪卡身份、完整元資料及 checksum、損壞引用/actionID/日桶/Unicode 填空、保存前故障回滾。此為第一批時點，不代表當時已接入 staged restore 或啟動流程。

B03 第二批新增 36 項，見 [完整備份與受保護恢復](qa/2026-10-08-b03-protected-recovery.md)：8 項備份/capture、14 項恢復、13 項啟動及 1 項 V2 App 資料保護邊界。覆蓋原版 V1 SQLite 直達 V3、V2 受保護升級、遷移時鐘來自保護備份、完整卡/會話恢復、舊版本導入拒絕、十一類日誌 counts、備份/建庫/準備/啟用失敗、取消/競爭/源變動、缺失數據庫與損壞會話阻止啟用。V1/V2 codec 仍拒絕 V3，共用 reader 已完整讀取 V3；真正評分/刪除/多窗口寫入與正式 UI 啟用尚未驗收。ENOSPC 等使用故障注入，不聲稱已填滿磁碟；没有新增付費網絡呼叫。

B03 第三批新增 47 項，見 [V3 刪除與受保護修復](qa/2026-10-08-b03-deletion-integrity.md)：15 項刪除/停卡交易、13 項完整性、6 項原始證據及 13 項受保護啟動修復。覆蓋來源 tombstone、會話 unavailable 不計成功、順序/嘗試次數/歷史身份保留、課程引用保護、全交易回滾、舊 JSON 兼容、壞資料不藉刪除清理、完整證據權限/篡改、前後 source/preference 檢查、故障/取消/競爭與重啟恢复。普通/V2 QA App schema 未切換；仍待 B04 及完整 writer/queue/UI 接入、大詞庫刪除延遲與實機驗收，不把新增單元測試當作 QA-20 全部完成。

B04 第一批新增 54 項，見 [純排程與查詢信號](qa/2026-10-08-b04-scheduler-signals.md)：23 項 scheduler、9 項到期分類、22 項 V3 capture。覆蓋呈現/反饋分離、Again/Hard 語義、兩次重學上限、跨午夜等待及作答配額/DST/倒退/時區、公元/民用日期邊界、優先請求不繞過等待/新卡/埋藏、零 AI 本地命中不改 legacy/能力、重送與真實磁盤恢復、保存故障全回滾。QA-21 的正式預覽/保存一致性、QA-22 的 V3 UI 集成及大庫延遲仍待完成；不將纯 plan 當已提交事件，也不以 opt-in 測試跳過推定網絡/性能/原生快捷鍵通過。

B04 第二批新增 35 項，見 [正式作答交易](qa/2026-10-08-b04-answer-transactions.md)：15 項 feedback、14 項寫入保護、6 項 reveal。驗證真正保存的 version=2 事件/卡片/項/游標、同源預覽與提交時間、跨午夜、跨服務/恢復重送、不同 action 二次點擊、下一張揭示不被舊回調清除、共享租約/恢復失效、完整內容依賴、保存失敗重試、introducedAt 缺失阻止、sibling 延期及非當前會話不改。QA-21 值層預覽/保存與 QA-24 部分寫入邊界已有核心證據，完整會話、V3 UI/新卡配額與原生窗口生命周期仍待後續驗收。

B05 第一批新增 34 項，見 [固定會話與首次呈現](qa/2026-10-08-b05-session-presentation.md)：10 項選組、13 項呈現/控制、11 項配額/格式保護。覆蓋無隱式新卡、固定 target/排序/membership、有效 Again 與 legacy 分離、同 sessionID 重試、單一可恢復組、首次呈現原子扣額度、暫停/重開/恢復不重扣、完整重學循環、刪卡不補位/不退配額、時鐘/時區/DST、故障/溢出/草稿/屏障、真實磁盤恢復及普通備份/修復證據的向後格式閘門。QA-23/QA-24 增加核心證據，但 Skip/Later、统计、窗口交互與大庫性能未因此標為完成。

B05 第二批新增 32 項，見 [控制與可信統計](qa/2026-10-08-b05-controls-statistics.md)：10 項 Skip/Later 交易、4 項純延期計算、11 項統計、7 項持久化/版本保護。覆蓋整輪略過暫停/隊首恢復、到時重學接手與禁止重交過渡項、重送不清除新揭示、控制/評分 actionID 衝突、失敗回滾、刪詞及磁盤恢復收據、記錄上限、DST/時鐘/時區、真實序號/缺省估計、跨會話首答去重、Hard 與 Again 區分、各類終態/實際分母、當前 membership、刪卡歷史、凍結日桶及 format=1/2/3 矩陣。QA-23/24/27 增加核心證據；原生 UI、性能和完整 V3 runtime 的階段出口仍未因此通過。

B06 第一批新增 45 項，見 [題型內容與明確建卡](qa/2026-10-08-b06-question-content.md)：14 項 Unicode/邊界/輸入比較、12 項填空交易/來源/格式、13 項方向啟用/曝光邊界、6 項正背面與資格。先復現引號洩露與刪除已揭示卡後繞過當日保護，再修復；覆蓋長原文多命中、屈折需明選、只詞頭/中文來源/無原始證據拒絕、源改動停用、完整回滾、卡片/來源刪除差異、本地命中重建卡繼承曝光、磁盤恢復及 format=1/2/3/4 能力閘門。QA-25/26 的核心證據增加，IME/快捷鍵、建卡面板、正式 UI 與大庫性能仍未完成。

B03/B04 內容流水線新增 84 項離線測試及一項有獨立 opt-in 的真實調用測試，見 [V3 內容流水線](qa/2026-10-08-b03-v3-content-pipeline.md)。覆蓋持久隊列/重啟、候選确认/編輯、三種建詞入口的一張 new 卡、完整十一實體回滾/備份、內容撤銷與學習狀態隔離，以及資料保護協調器的實際切庫/取消/遲到回調。live 僅兩次公開合成查詢；確認後精確重查不增發請求，正式復習不回寫 legacy 計數。這是服務集成證據，不是原生界面或語義評測完成聲明。

B03-B06 隔離 UI 已接入，新增 25 項控制器/Inbox adapter/填空恢復測試，原生核對固定組、重啟恢復、揭示/評分、Later、候選確認、原句填空及停卡/再啟用閉環；確認 sheet 失焦令 End 無效的實機問題已修復並補兩項回歸。詳細測試矩陣、明暗截圖觀察與未驗證項見 [V3 隔離 App 和復習界面](qa/2026-10-08-b03-v3-app-review.md)。這增加 QA-20 至 QA-27 證據，不代表 B 階段性能、真正多窗口或中文 IME 閘門已通過。

每個代碼任務先跑相關單測，再跑完整非 live 套件與嚴格建置；確切測試數、跳過項及命令輸出摘要記入交付證據。建議命令沿用現有工具鏈：

```bash
swift test
swift build -Xswiftc -warnings-as-errors
swift build --scratch-path /tmp/wordnote-strict-qa -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

scratch path 每輪使用獨立目錄，不能為了通過測試清除生產 store。App bundle 啟動驗證與 UI 截圖/交互是另外一道閘門，單純編譯成功或進程存在不能替代。工具不可用則記為未驗證，提供人工步驟與剩餘风险。

性能測試記錄硬件與 Release 配置，預熱後至少 30 次測量並列 p50/p95/max：1,000 詞時保存到可再輸入 p95 <= 300 ms；10,000 詞時輸入停止到搜索列表穩定（含 debounce）p95 <= 200 ms。超出先定位，不能降低門檻後宣稱原目標通過。AI 延遲獨立量測，不含在本地保存指標中。

A01 另有顯式 opt-in 的備份/恢復性能組，不混入快速單測，也不調 API 或讀真實詞庫：`RUN_BACKUP_PERFORMANCE_TESTS=1 swift test -c release --filter WordNoteBackupPerformanceTests`。默認使用 1,000/10,000 詞、每詞一筆來源/候選/事件的合成庫，預熱後各 30 次；記錄同步捕獲參考、后台捕獲、編解碼、staging、啟動驗證及快照寫入的 p50/p95/max。10 ms MainActor probe 的最大調度間隔只作卡頓代理指標，不等同真實界面的輸入/渲染延遲，也不替代上述保存/搜索門檻。探測可指定 `BACKUP_PERFORMANCE_ITERATIONS` / `BACKUP_PERFORMANCE_SIZE`；少於 30 次不能宣稱正式性能驗收。

### 階段驗收與證據

每個任務的證據至少含：commit、環境、fixture/schema、適用 QA ID、測試命令/結果、成功與失敗路徑、UI 圖或可重跑腳本、未驗證項和回退方式。日誌不得附私人詞句或密鑰。

G 固定基線；A 必須過備份/遷移/不丟編輯/原子入庫；B 必須過事件語義/恢復/統計/捕獲；C 必須過義項/品質/來源/整體回歸。詳見 [階段出口](13-supplemental-development-plan.md#7-階段出口與驗收方法)。任何未解決資料丟失、中文入主體、跨窗口重複計分、不可恢復或機密泄漏均阻止該階段交付。

QA-38 的後置收尾證據必須來自改碼並測試通過後的版本：README 項目簡介與功能描述可對照實作、相對鏈接和圖片可正常打開、實機截圖使用不含私人資訊的演示資料；敏感資訊檢查覆蓋最終工作樹/暫存區和本地可達歷史，報告列出範圍、排除項與處置，不附密鑰原文。倉庫忽略規則與測試占位值需人工核對，不能把運維資訊與可用憑據混為一談。此項目前待執行，不以規劃階段的零散截圖或提前掃描結果代替。

本次文檔補充不等於執行以上測試；文檔本身檢查相對链接、章節錨點、任務/QA 覆蓋、依賴、模型契約與新舊狀態。只有代碼實施後的新證據才能更新完成狀態。
