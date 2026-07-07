# 08. Security And Privacy

## 資料分類

| 類型 | 敏感度 | 存儲位置 |
|---|---|---|
| DeepSeek API Key | 高 | 本機 env 文件 |
| 原始輸入 rawText | 中 | 本地資料庫 |
| AI 解釋和詞條 | 中 | 本地資料庫 |
| 課程信息 | 中 | 本地資料庫 |
| 復習記錄 | 低到中 | 本地資料庫 |
| 日誌 | 低 | 本地日誌 |

## API Key

要求：

- 不存入 SwiftData。
- 不寫入 UserDefaults 明文。
- 不寫入日志。
- 不包含在導出文件中。
- Settings 中只展示 masked key。

可接受展示：

```text
sk-****abcd
```

## 本地資料

首版所有學習資料默認只保存在本機。

要求：

- 不做遠端同步。
- 不做 analytics。
- 不做 crash report 上傳，除非後續明確引入並更新文檔。
- 不在 App 外部寫入散落文件，導出除外。

## AI 請求隱私

發送給 AI 服務的內容：

- rawText。
- 可選 courseName。
- sourceType。
- userNote。

不發送：

- 本地完整詞庫。
- 全部課程列表。
- API Key 以外的本機識別信息。
- 用戶文件路徑。

## 日誌安全

可以記錄：

- request latency。
- status code。
- error type。
- candidate count。
- input length。

不能記錄：

- API Key。
- 完整 rawText。
- 完整 AI response。
- 完整 userNote。

Debug build 如需更詳細日誌，必須由開發者顯式開啟，且不可默認啟用。

## 導出

P1 JSON/CSV 導出要求：

- 不包含 API Key。
- 不包含內部錯誤堆棧。
- 可以包含 Term、Course、ReviewEvent。
- 是否包含 InputRecord 由用戶選擇。

## 刪除

用戶刪除詞條：

- Term 從詞庫移除。
- 相關 ReviewEvent MVP 可級聯刪除。
- 原始 InputRecord 不一定刪除，因為一條 InputRecord 可能生成多個 Term。

用戶刪除 InputRecord：

- 若其候選尚未保存，可刪除 CandidateTerm。
- 若已生成 Term，不自動刪除 Term。

## 網絡安全

要求：

- 只使用 HTTPS。
- 不禁用 TLS 校驗。
- timeout 必須配置。
- 不在錯誤信息中展示 API Key。

## 備份策略

MVP：

- 不自動備份。
- SwiftData 使用系統應用容器。

P1：

- 增加手動 JSON 導出。
- 增加導入前備份。

## 權限

MVP 不需要：

- 麥克風。
- 通訊錄。
- 文件全盤訪問。
- 螢幕錄製。
- 輔助功能。

P1 如果做全局快捷鍵或剪貼板增強，需要單獨評估權限。

## 威脅模型摘要

主要風險：

1. API Key 泄漏。
2. 原始學習內容被寫入日誌。
3. AI response 格式異常導致 App 崩潰或資料污染。
4. 未經確認的 AI 內容被當成可靠知識。

緩解：

- 本機 env 文件。
- 日誌脫敏。
- JSON schema validation。
- AI 候選必須經用戶確認。
- 錯誤狀態可重試，不覆蓋原始輸入。
