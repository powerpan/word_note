# 11. Engineering Decisions

本文件記錄已做出的工程決策。後續若改變方向，應新增決策條目，不直接覆蓋歷史原因。

## Decision 001: 原始需求文檔降級為背景資料

日期：2026-07-07

決策：

`ai_vocab_mac_app_requirements.md` 保留為原始想法和背景資料。後續開發以 `docs/` 為工程源文檔。

原因：

- 原始文檔更像完整想法集合，不適合作為直接開發 backlog。
- 其中 P0 範圍偏大，需要工程收斂。
- `docs/` 可以把產品、架構、資料、AI、測試和實施分開維護。

## Decision 002: P0 收斂為核心閉環

日期：2026-07-07

決策：

P0 只保留 Quick Add、AI Analysis、Candidate Review、Vocabulary、Courses、Review、Persistence、Settings 的最小可用能力。菜單欄、全局快捷鍵、剪貼板導入、導出和複雜統計放到 P1。

原因：

- 產品價值取決於記錄 -> 解析 -> 保存 -> 復習的閉環是否順暢。
- 全局快捷鍵和菜單欄是效率增強，不是閉環本身。
- 太大的 P0 會降低首版完成概率。

## Decision 003: InputRecord、CandidateTerm、Term 分離

日期：2026-07-07

決策：

資料模型分成三層：

- InputRecord：用戶原始輸入。
- CandidateTerm：AI 生成候選。
- Term：用戶確認後的正式詞條。

原因：

- 保留上下文。
- AI 失敗不影響原始輸入。
- 用戶可以選擇保存部分候選。
- 避免把整句錯誤保存為詞條。

## Decision 004: AI 不能自動寫入正式詞庫

日期：2026-07-07

決策：

AI 只生成候選，不直接自動保存為 Term。`should_auto_select` 只影響 UI 默認勾選。

原因：

- AI 可能誤判或解釋不準。
- 詞庫是長期學習資產，需要用戶確認。
- 這能降低錯誤資料污染。

## Decision 005: 首版復習算法保持簡單

日期：2026-07-07

決策：

MVP 不實作完整 spaced repetition algorithm，只用固定間隔：

- 完全不會：1 天後。
- 模糊：3 天後。
- 記得：7 天後。
- 很熟：14 天後。

原因：

- 首版重點是閉環而非算法。
- 固定規則可預測、可測試、易調整。
- 等用戶有真實使用資料後再優化更合理。

## Decision 006: 本地優先，API Key 使用本機 env 文件

日期：2026-07-07

決策：

首版所有學習資料保存在本地。DeepSeek API Key 存入本機 env 文件，不進入 SwiftData、日誌、導出文件或 Git 倉庫。App 不讀寫 macOS Keychain，避免頻繁觸發系統密碼授權彈窗。

原因：

- 詞庫和課程資料屬於個人學習資料。
- 首版不需要後端。
- 用戶希望避免 Keychain 密碼彈窗。
- env 文件便於本地調試、遷移和命令行測試。

實施：

- Settings 寫入 `~/Library/Application Support/WordNote/deepseek.env`。
- 可用 `WORD_NOTE_ENV_FILE` 指定其他 env 文件。
- 倉庫內 `.env*` 和 `key.md` 必須保持忽略。

## Decision 007: 推薦 SwiftUI + SwiftData，最低 macOS 14

日期：2026-07-07

決策：

首版推薦使用 SwiftUI + SwiftData，最低 macOS 14。

原因：

- 快速建立原生 macOS App。
- SwiftData 足夠支持 MVP 的本地資料模型。
- 避免首版過早引入自建 SQLite 層。

備註：

如果需要支持 macOS 13 或更早版本，應新增 ADR，評估 Core Data 或 SQLite/GRDB。

## Decision 008: P1 Review 優先做學習回路，不直接引入完整 SM-2 / FSRS

日期：2026-07-09

決策：

P1 Review 先做三件事：

- Quick Add 精確命中既有詞條時跳過 DeepSeek，直接顯示已有釋義。
- 重複輸入既有詞條時，把該詞視為薄弱詞，提升重要度並加入今日復習。
- Review 排程從固定 1/3/7/14 天升級為簡化自適應規則，但不直接引入完整 SM-2 / FSRS。

原因：

- 再次輸入同一詞通常說明用戶又遇到且沒有掌握，應立即回到復習隊列。
- 精確命中正式詞庫時重新調用 DeepSeek 沒有必要，會增加等待和 API 成本。
- 目前數據量不足以支撐複雜算法調參，透明規則更容易驗證和修正。
- Review 產品體驗的短板不只在算法，也包括模式、快捷鍵、完成統計和錯題入口。

約束：

- 只做 `normalized(rawText) == Term.normalizedTerm` 的精確匹配，不做包含匹配或模糊匹配。
- 命中時不創建 InputRecord，避免 Inbox 被重複查詞污染。
- duplicate hit 不等同於正式 Review feedback，P1 首版可不寫 ReviewEvent。
- wrongCount 需要冷卻窗口，避免短時間重複輸入刷高錯題統計。

## Decision 009: 使用版本化私有 store，保守遷移歷史資料

日期：2026-07-10

決策：

- SwiftData 使用顯式 `VersionedSchema` 和 `SchemaMigrationPlan`。
- store 固定在 `~/Library/Application Support/WordNote/WordNote.store`。
- 首次發現舊 `default.store` 時，先複製主檔及 WAL/SHM 到唯一備份目錄，再複製到新位置。
- 遷移器永不刪除舊 store；啟動後執行孤兒資料修復和私有權限校正。
- 持久化容器無法打開時顯示啟動錯誤頁，禁止在記憶體 fallback 中繼續新增學習資料。

原因：

- 直接沿用 SwiftData 默認位置和隱式 schema 會讓後續模型變更難以驗證。
- 詞庫是不可替代的用戶資產，遷移必須可回退且不能覆寫已有新 store。
- 啟動修復能清理由早期不完整級聯規則留下的孤兒記錄。

## Decision 010: 分析佇列以持久化 InputRecord 為恢復來源

日期：2026-07-10

決策：

- Save & Analyze 先建立 `status = analyzing` 的 InputRecord，再立即把輸入控制權還給 UI。
- 進程內使用單一 `QuickAddAnalysisQueue` 依序處理主窗口與浮窗提交。
- App 啟動時重新入隊所有 analyzing 記錄；同 normalizedText 已排隊時不重複建立或發送。
- 單筆失敗只標記該記錄為 failed，不阻塞後續請求。
- DeepSeek 查詞默認使用 `deepseek-v4-flash` 並顯式關閉 thinking；live 測試必須顯式 opt-in。

原因：

- 網絡請求不能阻塞連續捕獲詞句。
- 僅存在記憶體的 Task 在 App 退出時會丟失，持久化狀態可在重啟後恢復。
- 順序 worker 能控制請求壓力，也讓狀態流轉和錯誤隔離更易測試。
- 結構化查詞不需要默認思考模式，關閉後延遲與輸出契約更可控。

## Decision 011: 跨實體寫入必須原子化並定義級聯規則

日期：2026-07-10

決策：

- 批量確認候選先驗證全部輸入，再一次保存；任一錯誤整批回滾。
- 刪除 InputRecord 級聯 CandidateTerm，保留 Term 但清空 `sourceRecordID`。
- 刪除 Term 級聯 ReviewEvent；刪除被引用 Course 仍被阻止。
- AI 重試保留 saved 候選、替換其餘候選，不追加歷史失敗結果。
- 新建和編輯 Term 都執行全局 normalizedTerm 去重。

原因：

- SwiftData model 關聯目前以 UUID 表示，不能依賴資料庫自動維護引用完整性。
- 部分保存和孤兒事件會使 Inbox、Vocabulary、Dashboard 和 Review 對同一資料得出不同結果。
