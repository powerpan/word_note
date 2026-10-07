# 10. Implementation Plan

版本說明：M1-M7/P1 為已完成歷史；2026-10 之後以 [13-supplemental-development-plan.md](13-supplemental-development-plan.md) 的任務和依賴為執行入口。歷史勾選項不代表新任務已交付。

## 開發策略

採用垂直切片，而不是先把所有 UI 或所有資料模型一次寫完。每個里程碑都應該能運行、能保存資料、能被手工驗收。

截至 2026-07-13，M1-M7、P1-A 至 P1-G 和下列可靠性加固均已落地。後續變更應維持本文件定義的資料一致性與測試門檻。

## M1: Project Foundation

目標：建立可運行的 macOS App 骨架和基礎資料層。

任務：

- 建立 SwiftUI macOS project。
- 設定 bundle id、最低 macOS 版本。
- 建立 SwiftData container。
- 建立基本 model：Course、InputRecord、CandidateTerm、Term、ReviewEvent。
- 建立 repository protocol 和 SwiftData implementation。
- 建立 app navigation shell。
- 建立基礎錯誤和 loading state。

完成標準：

- App 可啟動。
- 可建立和查詢 Course。
- 可建立和查詢 Term。
- 基礎資料測試通過。

## M2: Quick Add And Inbox

目標：用戶可以保存原始輸入，並在 Inbox 查看。

任務：

- QuickAddView。
- QuickAddViewModel。
- InputRecordService.createDraft。
- course/source/note 選擇。
- Inbox list。
- InputRecord detail。
- draft/ignored/delete 流程。

完成標準：

- 只輸入 raw text 可保存。
- 重啟 App 後 InputRecord 仍存在。
- Inbox 正確展示 draft 和 ignored 以外的記錄。

## M3: AI Integration

目標：接入 DeepSeek 解析並保存候選。

任務：

- Settings API Key UI。
- DeepSeekEnvironmentFileStore。
- DeepSeekClient。
- AIAnalysisService。
- prompt builder。
- response parser。
- CandidateTerm persistence。
- failed status 和 retry。

完成標準：

- 三個標準樣例可解析。
- API Key 缺失時可保存 draft，不崩潰。
- 網絡錯誤時 InputRecord.status = failed。
- JSON 錯誤時可重試。

## M4: Candidate Review To Vocabulary

目標：用戶能從 AI 候選建立正式詞條。

任務：

- CandidateReviewView。
- 候選勾選和編輯。
- VocabularyService.createTerms。
- duplicate detection。
- CandidateStatus saved/ignored。
- InputRecord completion status。
- Vocabulary list/detail/edit/delete。

完成標準：

- 保存候選後 Vocabulary 出現 Term。
- 編輯 Term 後持久化。
- 刪除 Term 後列表更新。
- 重複詞條有提示。

## M5: Courses And Filters

目標：課程管理和基本篩選可用。

任務：

- Courses list。
- Course create/edit。
- Course referenced delete guard。
- Vocabulary course filter。
- Vocabulary mastery filter。
- Dashboard 顯示課程和未整理摘要。

完成標準：

- Term 可綁定課程。
- 課程下詞條數正確。
- 被引用 Course 不能直接刪除。

## M6: Review Loop

目標：完成最小復習閉環。

任務：

- ReviewService。
- review scheduler。
- due terms query。
- ReviewView。
- ReviewEvent persistence。
- Term review counters update。
- Dashboard today due count。

完成標準：

- 新增 Term 出現在今日待復習。
- 完成復習後 nextReviewAt 按規則更新。
- ReviewEvent 被保存。

## M7: QA And Release Polish

目標：達到 MVP 可日常使用。

任務：

- 空狀態。
- 錯誤提示文案。
- loading 狀態。
- API timeout 配置。
- 日誌脫敏。
- 單元測試補齊。
- 手動回歸。
- README 更新。

完成標準：

- MVP Release Gate 全部通過。
- 文檔與實作一致。
- 已知限制記錄清楚。

## P1-A: Duplicate Quick Add Hit

狀態：已完成。

目標：用戶再次輸入已存在詞條時，不再調用 DeepSeek，而是直接進入學習回路。

任務：

- VocabularyService.findExactTerm(normalizedTerm)。
- VocabularyService.bumpDuplicateHit(term, now)。
- QuickAddAnalysisQueue 在 enqueue 前查正式 Term。
- 將 existing Term 組裝成 AIExplanationPreview，復用主窗口和浮窗釋義顯示。
- duplicateHitCount、lastDuplicateHitAt、correctStreak、reviewIntervalDays schema migration。
- 10 分鐘冷卻窗口，防止 wrongCount 被短時間重複輸入刷高。

完成標準：

- 精確命中 Term 時不建立 InputRecord。
- 精確命中 Term 時不調用 DeepSeek。
- 主 Quick Add 和浮窗都立即顯示已有釋義。
- 命中後 Term.nextReviewAt = now。
- importance 最多提升一級。
- wrongCount 冷卻窗口外才 +1。

## P1-B: Review Experience Upgrade

狀態：已完成。

目標：把 Review 從固定間隔卡片升級為可日常使用的學習回路。

任務：

- ReviewMode selector。
- 中文 -> 英文卡片。
- Review keyboard shortcuts：space, 1, 2, 3, 4。
- Skip / Later。
- Review session state。
- 完成頁統計 again/hard/good/easy。
- 錯題 / 薄弱詞入口。

完成標準：

- 用戶可選英文 -> 中文或中文 -> 英文。
- 快捷鍵不干擾文本輸入。
- Skip 不更新 Term。
- Later 將 nextReviewAt 推遲到明天。
- 完成頁能展示本輪統計。

## P1-C: Simplified Adaptive Scheduler

狀態：已完成。

目標：用透明規則替代固定 1/3/7/14 天，但不引入完整 SM-2 / FSRS。

任務：

- ReviewScheduler 支持 correctStreak 和 reviewIntervalDays。
- good/easy 根據 streak 漸進拉長間隔。
- again/hard 重置 streak 並縮短間隔。
- ReviewEvent 保存調整前後 nextReviewAt。
- 補遷移和單元測試。

完成標準：

- 新詞第一次 good 不直接跳到 7 天。
- 連續答對會逐步拉長間隔。
- again/hard 會明確降低掌握度並提前復習。
- 單元測試覆蓋所有 feedback 和 streak 分支。

## P1-D: Local Vocabulary Input Completion

狀態：已完成。

目標：在不發送網絡請求的前提下，使用正式詞庫縮短重複輸入單詞和短語的時間。

任務：

- 在 WordNoteCore 增加純 `VocabularyCompletionMatcher`。
- 主 Quick Add 和浮窗通過 SwiftData `@Query` 提供正式詞條快照。
- 使用共享 AppKit completion editor 繪製灰色後綴並處理 Tab/Escape、選區和焦點。
- 保留 Enter/Save 提交語義與精確 duplicate hit 邏輯。
- 補 matcher 單元測試和兩個入口的手動回歸。

完成標準：

- 至少 2 個字符時可按穩定規則得到至多一個前綴候選。
- Tab 接受補全但不觸發保存或分析。
- 多行文本、光標不在末尾或已有文字選區時不顯示補全。
- 主窗口和浮窗共用同一 matcher，不複製排序規則。
- 補全不讀寫業務資料、不調用 DeepSeek。

## P1-E: Chinese-To-English Lookup

狀態：已完成。

目標：允許用戶用中文詞義、短語或句子查找自然英文表達，並沿用既有 Inbox 確認流程。

任務：

- 增加純 `LookupDirectionDetector`，由原始輸入穩定推導查詢方向。
- 為 DeepSeek request 增加方向契約與中文查英文 prompt。
- 過濾中文或中英混合的候選 term，以及缺少中文釋義的候選。
- 中文查英文不走英文精確重複短路，仍建立可恢復的 InputRecord。
- VocabularyService 保存前再次驗證英文主體與中文釋義。

完成標準：

- 中文輸入可產生一到多個真正有語義差別的英文候選。
- `Term.term` 永遠保存英文，`Term.chineseMeaning` 保存中文解釋，中文原文只保留為上下文。
- 無合格英文候選時記錄轉為 failed 並可重試，不把中文查詢保存成正式詞條。
- live DeepSeek smoke test 同時覆蓋英文查中文與中文查英文。

## P1-F: Bilingual Vocabulary Search

狀態：已完成。

目標：讓用戶可以從英文詞條、英文定義或中文釋義找回正式詞條。

任務：

- 將搜索規則下沉為純 `VocabularySearchMatcher`。
- 英文使用規範化、大小寫不敏感的 contains 搜索。
- 中文釋義使用 ICU 簡繁轉換，移除空白與標點後做子串匹配。
- 保持搜索、Quick Add 補全與 duplicate detection 三套語義彼此獨立。

完成標準：

- 簡體查詢能命中繁體釋義，繁體查詢也能命中簡體釋義。
- 只有標點的查詢不會錯誤匹配全部詞條。
- 搜索不改寫持久化資料，也不觸發 AI。

## P1-G: Appearance Preferences

狀態：已完成。

目標：在保留研究編輯台視覺語言的前提下，支持系統、淺色與深色三種外觀。

任務：

- 使用 `AppAppearancePreference` 定義穩定的 `system | light | dark` 持久化值。
- Settings 提供三態 segmented picker。
- 主窗口、Settings scene 與 Quick Add 浮窗共享同一偏好。
- 深色 token 改為中性黑灰，避免墨綠、藍灰或棕色偏向。

完成標準：

- 三種模式可即時切換並在重啟後保留。
- 所有窗口外觀一致，切換不重置導航、輸入或分析隊列。
- 未知舊偏好安全回退到跟隨系統。

## Reliability Hardening

狀態：已完成。

交付內容：

- SwiftData schema 顯式版本化，舊 `default.store` 安全備份並遷移到私有固定路徑。
- 啟動時修復孤兒記錄與懸空引用，持久化失敗顯示恢復頁而不是直接崩潰。
- AI 佇列以 analyzing InputRecord 作為持久化事實來源，支持重啟恢復、排隊去重和單筆失敗隔離。
- AI 重試候選替換、InputRecord/Term 級聯刪除、Term 全局去重和批量確認原子性。
- DeepSeek 請求契約、輸入上限、live 測試顯式閘門和 strict concurrency build gate。
- Inbox 批量確認、手動建詞、危險刪除確認、響應式三欄佈局與可訪問性標籤。

完成標準：

- 舊 store 遷移測試證明資料保留、備份存在且不覆寫新 store。
- 全部單元與整合測試通過。
- warnings-as-errors 和 Swift 6 complete concurrency warnings-as-errors 建置通過。
- App bundle 啟動及實際本機 store 遷移後資料完整性驗證通過。

## 推薦目錄結構

```text
WordNote/
  WordNoteApp.swift
  Presentation/
    Dashboard/
    QuickAdd/
    Inbox/
    CandidateReview/
    Vocabulary/
    Review/
    Courses/
    Settings/
  Domain/
    Entities/
    Services/
    UseCases/
    Validation/
  Data/
    Models/
    Repositories/
    Migrations/
  Infrastructure/
    AI/
    Configuration/
    Logging/
    Export/
  Shared/
    Components/
    Extensions/
    Errors/
WordNoteTests/
WordNoteUITests/
```

## 開發順序建議

1. 先完成資料模型和 mock repository。
2. 用 mock AI 做 Quick Add -> Candidate Review -> Vocabulary 閉環。
3. 再接入真實 DeepSeek。
4. 最後補 Review 和 polish。
5. P1 先做 Duplicate Quick Add Hit，因為它能立刻降低 AI 成本並提升復習價值。
6. 再做 Review mode / keyboard / session 統計。
7. 最後替換固定排程為簡化自適應排程。
8. 在重複詞短路穩定後增加本地詞庫輸入補全，復用同一正式詞庫資料源。
9. 補全穩定後增加中文查英文，使用服務層雙重校驗守住英文詞條主體。
10. 再把雙語搜索和外觀偏好下沉為可獨立測試的 core 規則。

這樣可以避免一開始被 API 不穩定或本機 secrets 文件細節拖慢。

## 分支策略

在個人項目早期可以簡化：

- `main` 保持可運行。
- 每個里程碑用短分支，例如 `m1-foundation`。
- 合併前跑測試。

如果只有本地個人開發，也可以直接在 `main` 小步提交，但每次提交應保持可回退。

## 提交粒度

建議提交：

- docs: add engineering docs
- chore: create macos project
- feat: add swiftdata models
- feat: add quick add draft flow
- feat: add ai analysis service
- feat: add candidate review
- feat: add vocabulary crud
- feat: add review scheduler
- test: cover ai parser and review scheduler
- feat: skip ai for duplicate quick add terms
- feat: add review mode selector and shortcuts
- feat: add adaptive review scheduler

## 風險與緩解

| 風險 | 影響 | 緩解 |
|---|---|---|
| AI JSON 不穩定 | 候選無法保存 | parser 容錯、schema validation、retry |
| P0 範圍膨脹 | 延期 | 嚴格按 MVP 文檔執行 |
| SwiftData 遷移問題 | 用戶資料風險 | 早期保守模型、遷移前導出 |
| API Key 泄漏 | 安全問題 | env 文件忽略、日誌脫敏、測試 |
| UI 過度設計 | 延誤核心閉環 | 先做密集、清楚的工作台式界面 |

## 歷史 P1 啟動條件

下列條件已滿足並已進入 P1；保留作為後續大階段啟動門檻的參考：

- P0 閉環可日常使用。
- AI 失敗和重試穩定。
- 用戶已累積至少一批真實詞條。
- 已確認最常用入口需要菜單欄快速輸入；系統全局快捷鍵仍未實作。

## 2026-10 補充契約

新的執行入口是 [13-supplemental-development-plan.md](13-supplemental-development-plan.md)，本節只規定交付方式，不複製第二份任務狀態表。

1. G00 建立可重現的代碼、測試、資料和 UI 基線；不沿用歷史測試數作本輪證據。
2. A01 在 V1 完成可恢復快照；A03 可獨立修浮窗和英文主體。之後 A02 關聯模型、A04 編輯保護、A05 確認預覽、A06 閱讀模式依序交付。
3. A 出口通過後進 B。B01/B02 可在各自依賴完成後並行；B03 卡片遷移與 B04 排程切換作一個完整可驗收版本，不能向主分支交付兩個同時活躍的排程寫入者。B05 會話後再交付 B06/B07，B08 收斂設置/窗口。
4. B 出口通過後進 C。C01 義項遷移先於 C02 schema v2；C03 來源與 C04 練習按依賴交付；C05 僅產出算法評估。C06 做整體證據核對。
5. C06 的 README、介紹用截圖及敏感資訊檢查是代碼開發後的收尾工作：先完成本次交付範圍的代碼並通過功能/回歸測試，再更新 README 項目簡介及新版實機截圖，然後檢查最終待交付內容與本地可達 Git 歷史。現在只把要求寫入計劃，不執行這些收尾項；之後提交、推送仍需相應授權。

每個任務開始時在總表記錄負責人、開始基線和工作分支；分支使用 `codex/` 前綴。任務結束填寫交付 commit、QA ID、結果和未驗證項。小步提交可先含測試，再實作和文檔；尚未通過出口的 schema 遷移不得部署到唯一真實庫。

本地驗證、提交、推送、真實資料遷移和用戶驗收是不同階段。2026-10-07 用戶另已授權持續代碼開發、里程碑/重大變更推送和受控真實 DeepSeek 測試，不需逐階段等待確認；這不等於授權用唯一真實庫試遷移、破壞性資料替換或改寫 Git 歷史。未過 UI 閘門的重大變更可先推送開發分支並記錄未驗證項，不能標為已驗收或合入主分支。沒有分發、公證或 App Store 任務。

各階段保留回退快照與已知限制；既有資料安全問題優先於新增功能。G00 後才給日曆工期，不能把相對 S/M/L 直接換成未验证的日期承諾。C04 的減範圍和 C05 的 No-Go 必須記錄，不以無期限擴張延誤 A/B 的日常可用版本。
