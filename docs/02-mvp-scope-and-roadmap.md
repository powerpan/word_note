# 02. MVP Scope And Roadmap

## 範圍調整說明

早期需求文檔中的 P0 範圍偏大，將詞庫、課程、復習、統計和多種入口一次性放入首版，會增加實施風險。新的工程範圍採用「先跑通核心閉環，再擴展入口和效率功能」。

## MVP 定義

MVP 只驗證一件事：

> 用戶能快速記錄 AI / CS 英文內容，通過 AI 得到專業語境解釋，選擇保存到本地詞庫，並進入簡單復習。

## P0 必須實現

### Quick Add

- 主窗口內快速輸入 raw text。
- 支持 word、phrase、sentence，paragraph 可保存但不保證最佳解析。
- 可選 course。
- 可選 source type。
- 可選 note。
- 保存原始 InputRecord。
- 支持 Save。
- 支持 Save & Analyze。

### AI Analysis

- 調用 DeepSeek 兼容服務。
- 輸入類型判斷：word、phrase、sentence、paragraph。
- 單詞直接解釋。
- 短語優先整體解釋。
- 句子先解釋整句，再提取候選詞條。
- 不機械解釋簡單功能詞。
- 普通詞在 AI / CS 語境有特殊含義時可被提取。
- 返回結構化 JSON。
- 解析失敗時保留 InputRecord，狀態標記為 failed。

### Candidate Review

- 顯示原始輸入。
- 顯示整句含義。
- 顯示候選詞條。
- 默認勾選 `need_to_learn = true` 且重要度不低的候選。
- 支持編輯候選內容。
- 支持保存選中候選到 Term。
- 支持忽略候選。
- 支持重新解析。

### Vocabulary

- 詞條列表。
- 詞條詳情。
- 搜索 term。
- 編輯詞條。
- 刪除詞條。
- 按課程篩選。
- 按掌握程度篩選。

### Courses

- 新增課程。
- 編輯課程。
- 刪除未被引用的課程。
- 詞條和原始記錄可綁定課程。

### Review

- 今日待復習列表。
- 基礎卡片：英文 -> 中文。
- 查看答案。
- 選擇反饋：完全不會、模糊、記得、很熟。
- 更新 masteryLevel、reviewCount、wrongCount、nextReviewAt。

### Persistence

- 本地持久化 InputRecord、CandidateTerm、Term、Course、ReviewEvent。
- 關閉 App 後再次打開資料不丟失。
- API Key 存入本機 env 文件，不存入 SwiftData 或提交到 Git。

### Settings

- 配置 DeepSeek API Key。
- 測試 API Key 是否可用。
- 設置默認課程，可選。

## P0 明確不做

- 菜單欄常駐入口。
- 全局快捷鍵。
- 剪貼板監聽和自動導入。
- PDF 內選詞。
- Slides 導入。
- 錄音轉文字。
- 复杂統計圖表。
- CSV / JSON 導出。
- iCloud 同步。
- iOS / iPadOS 版本。
- Anki / Notion / Obsidian 導出。

## P1 應該實現

P1 目標是提升記錄效率和整理效率。

- 菜單欄入口。
- 全局快捷鍵打開 Quick Add。
- 剪貼板導入當前文本。
- 去重提醒。
- 候選合併到已有詞條。
- 未整理 InputRecord 列表。
- 今日新增。
- 錯誤次數排序。
- JSON / CSV 導出。
- 複習模式增加中文 -> 英文。
- 基礎統計：總詞條、本周新增、今日待復習、未整理數量。

## P2 後續擴展

P2 只在 P0/P1 穩定後評估：

- PDF 選詞導入。
- Lecture slides 導入。
- 課堂錄音轉文字。
- 從轉錄文本自動提取詞條。
- 發音播放。
- 跟讀練習。
- iCloud 同步。
- iPhone / iPad 版本。
- Anki 導出。
- Notion / Obsidian 導出。
- 專業詞彙知識圖譜。

## MVP 驗收標準

### AI 輸入類型

1. 輸入 `regularization`，App 能生成專業中文解釋、英文定義、AI / CS 語境說明和例句。
2. 輸入 `latent representation`，App 優先把短語作為整體解釋，不拆成兩個獨立詞條。
3. 輸入 `The model learns a latent representation of the input data.`，App 能解釋整句並提取 `latent representation`。

### 候選保存

4. 用戶可以勾選候選詞條保存到詞庫。
5. 用戶可以取消不需要的候選。
6. 用戶可以在保存前編輯 AI 生成內容。

### 本地可靠性

7. AI 請求失敗時，原始輸入仍然保存在未整理記錄中。
8. 關閉並重新打開 App 後，InputRecord、Term、Course、ReviewEvent 仍然存在。
9. API Key 不出現在資料導出文件或調試日誌中。

### 詞庫與復習

10. 保存後的詞條可以被搜索、查看、編輯和刪除。
11. 詞條可以綁定課程。
12. 詞條可以出現在今日待復習中。
13. 完成復習反饋後，App 更新下一次復習時間。

## 里程碑

| 里程碑 | 目標 | 完成標準 |
|---|---|---|
| M1 | App shell + persistence | 可啟動 App，建立本地資料模型，完成課程和詞條 CRUD |
| M2 | Quick Add + InputRecord | 可保存原始輸入，可查看未整理記錄 |
| M3 | DeepSeek analysis | 可調用 AI，解析並持久化候選結果 |
| M4 | Candidate review | 可編輯、勾選、保存候選到詞庫 |
| M5 | Review loop | 可完成今日復習和排程更新 |
| M6 | Polish + QA | 完成錯誤處理、空狀態、基礎測試和驗收清單 |
