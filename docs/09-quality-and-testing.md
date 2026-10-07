# 09. Quality And Testing

版本說明：原有用例對應 V1/P1；2026-10 新任務用文末 QA-01 至 QA-38 追蹤。實施中的新證據見 [G00/A03 執行記錄](qa/2026-10-07-g00-a03.md)、[A01 核心資料保護](qa/2026-10-08-a01-persistence.md) 和 [A01 App 接入](qa/2026-10-08-a01-app-integration.md)，自動化通過不等於 UI 項已驗收。舊版 82 項結果是歷史證據，不能用作補充計劃已通過的證明。

A01 后台與性能證據：[后台資料工作](qa/2026-10-08-a01-background-persistence.md)，含當批 188 項嚴格離線回歸、獨立 live 與 1,000/10,000 詞各 30 輪 Release 測量；不代替後續 V2 性能或實機驗收。

A02 最新隔離證據：[原始證據保護與啟動修復](qa/2026-10-08-a02-startup-repair.md)，全套 348 項中 346 通過、2 跳過，Release 定向 145 項通過。V2 核心可測不代表 App 已切換。Computer Use 最近重試回報 cgWindowNotFound；實機閘門仍未通過，不能沿用歷史鎖屏診斷。

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
| QA-09 | WN2-A04 | 交易 + 多窗口 | stale revision 阻止覆寫；編輯/確認撤銷可回到前值，後續依賴存在時不刪新資料；不承諾刪除/復習撤銷 |
| QA-10 | WN2-A05 | 單元 + 集成 | 批內/庫內同詞 new/link/fill/ignore 分類與記錄數/候選數/詞數正確，無未解決衝突才允許提交 |
| QA-11 | WN2-A05 | 故障注入 | 中途保存失敗全部回滾；雙擊/重啟後重試不再建詞，savedTermID、來源與關聯一致；過期預覽拒絕 |
| QA-12 | WN2-A06 | matcher + UI | 英文/簡繁中文搜索、18 字 Inbox 摘要保留、詞庫雙行與閱讀模式、長詞頭、空結果、排序選中項穩定 |
| QA-13 | WN2-A06 | 服務 + UI | 批量加/解除課程、標籤預覽數正確且原子保存；不修改詞義，取消不留下半個批次 |
| QA-14 | WN2-B01 | UI | 全選只選可處理篩選項、切篩選不殘留隱藏選擇、Confirmed 收起、確認後到下一條且焦點穩定 |
| QA-15 | WN2-B01 | queue + 集成 | 三入口共用隊列；離線/429/超時/格式錯誤分類；退避與最多 2 次自動重試跨重啟保持；取消不誤稱免計費 |
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
