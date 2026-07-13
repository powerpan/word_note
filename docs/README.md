# Word Note Engineering Docs

## 文檔定位

本目錄是 Word Note 後續設計、開發、驗收和維護的工程源文檔。根目錄中的 `ai_vocab_mac_app_requirements.md` 只作為早期需求背景，不再直接作為開發任務清單。

Word Note 是一個面向 AI / CS 英文授課場景的 macOS 個人詞彙與術語工具。它的核心不是泛用背單詞，而是幫助中文母語的 AI / CS 研究生在上課、閱讀論文、看課件和寫作業時快速記錄英文內容，通過 AI 解析出真正有學習價值的詞、短語、術語和表達，形成可整理、可檢索、可復習的本地知識庫。

## 當前實施狀態

截至 2026-07-13，M1-M7 與主要 P1 學習閉環已完成。當前版本支持英文查中文、中文查英文、正式詞庫本地補全、雙語詞庫搜尋、持久化分析隊列、Inbox 批量確認、簡化自適應復習、菜單欄 Quick Add，以及跟隨系統 / 淺色 / 深色三態外觀。

中文查英文只把中文原文視為查詢上下文；正式 `Term.term` 必須保持英文，中文解釋保存在 `Term.chineseMeaning`。這是跨 AI、Inbox、Vocabulary 和 Review 的資料契約。

## 文檔目錄

| 文件 | 用途 |
|---|---|
| [01-product-requirements.md](01-product-requirements.md) | 產品定位、目標用戶、核心場景、功能邊界 |
| [02-mvp-scope-and-roadmap.md](02-mvp-scope-and-roadmap.md) | 收斂後的 MVP、P1、P2 範圍和驗收標準 |
| [03-ux-flows.md](03-ux-flows.md) | 信息架構、核心頁面、用戶流程、狀態與錯誤體驗 |
| [04-technical-architecture.md](04-technical-architecture.md) | macOS 技術架構、模塊邊界、資料流、依賴策略 |
| [05-data-model.md](05-data-model.md) | 本地資料模型、枚舉、關係、索引和遷移原則 |
| [06-ai-integration.md](06-ai-integration.md) | DeepSeek 集成、提示詞契約、JSON schema、容錯策略 |
| [07-review-system.md](07-review-system.md) | 首版復習模型、排程規則、卡片模式和統計口徑 |
| [08-security-privacy.md](08-security-privacy.md) | API Key、本地資料、網絡請求、隱私和備份要求 |
| [09-quality-and-testing.md](09-quality-and-testing.md) | 測試分層、驗收用例、手工回歸清單、質量門檻 |
| [10-implementation-plan.md](10-implementation-plan.md) | 開發階段、任務拆分、交付順序和里程碑 |
| [11-engineering-decisions.md](11-engineering-decisions.md) | 已確定的工程決策與後續 ADR 記錄 |
| [12-tencent-cloud-server-access.md](12-tencent-cloud-server-access.md) | 騰訊雲服務器的項目內 SSH 登入方法與憑據約束 |

## 開發原則

1. 快速記錄優先於字段完整度。
2. 短語和術語優先於機械拆詞。
3. AI 解析結果必須可被用戶確認、編輯、忽略或重試。
4. 本地資料可靠性優先於雲同步。
5. 首版只做個人學習閉環，不做社交、賬號、多端同步和複雜導入。
6. 任何 AI 失敗都不能阻止用戶保存原始輸入。
7. 文檔中的 MVP 範圍高於早期需求文檔中的 P0 清單。
8. 新功能提交前必須同步更新需求、流程、架構、測試與工程決策中受影響的部分。

## 推薦實施棧

首版建議採用：

- App: native macOS SwiftUI
- Persistence: SwiftData, 最低 macOS 14
- Networking: URLSession + async/await
- Secrets: 本機 env 文件
- State: Observable view models / services with dependency injection
- Tests: XCTest, Swift Testing 可在後續評估

如果需要支持 macOS 13 或更早版本，資料層應改用 SQLite/GRDB 或 Core Data，並在實施前新增 ADR。
