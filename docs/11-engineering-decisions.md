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
