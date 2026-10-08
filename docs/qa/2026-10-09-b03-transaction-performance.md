# B03：V3 交易性能

日期：2026-10-09（Asia/Hong_Kong）。範圍為 B03/B04 的大詞庫交易風險，不是整個 B 階段的完成記錄。

## 測量方法

本機 Apple M4、16 GiB RAM、macOS 27.0.1（26A434），Swift Release、完整並發檢查及 warnings-as-errors。資料由已有備份性能 fixture 轉成 V3，再寫入臨時 SQLite、關閉並重開。1,000／10,000 詞分別有 7,002／70,002 個初始實體，包含課程、來源、已處理候選、歷史事件及卡片。

每輪執行新輸入持久排隊、精確本地命中、建立固定復習組、呈現、揭示與四種評分預覽、Good 評分並移到下一張。每輪結束會話，避免前一組影響下一輪；核對最終詞數、查詢事件和正式答題數。沒有建立 provider，沒有付費請求或真實詞庫操作。

第一輪預熱不計入分布。正式測量每種規模 30 輪，記錄 p50/p95/max。範圍包括同步 MainActor 服務及磁盤保存，不包括 SwiftUI 重繪、文字框接收下一次輸入或 AI 延遲。不能用這組數字替代 300 ms 連續輸入及 200 ms 搜索的端到端閘門。

```sh
RUN_V3_PERFORMANCE_TESTS=1 swift test --scratch-path .build-v3-qa -c release \
  -Xswiftc -DWORDNOTE_V3_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors \
  --filter WordNoteV3PerformanceTests
```

定位時可設定 `V3_PERFORMANCE_ITERATIONS=1`，或用 `V3_PERFORMANCE_SIZE=1000` 限定規模。短測不能當正式分布。

## 修正前

先跑預熱後各一輪，以免對已明顯阻塞的版本做無意義的 30 輪重複。下表是單輪毫秒值，不是 p95。

| 操作 | 1,000 詞 | 10,000 詞 |
|---|---:|---:|
| 新輸入排隊 | 495.29 | 4,880.94 |
| 本地命中 | 514.90 | 5,112.45 |
| 開始復習組 | 668.54 | 6,735.68 |
| 呈現及更新統計 | 1,448.72 | 14,279.49 |
| 揭示、四種預覽及統計 | 2,515.96 | 25,408.37 |
| 評分並移至下一張 | 2,197.13 | 21,825.18 |

兩秒原生栈採樣定位到 `captureForIntegrityInspection` 的模型讀取／值轉換和 canonical sort；當次 `sessionStatistics` 在交易前後又重复抓取整庫。即使資料沒有變，四種評分預覽亦各自重做全量工作。這不是網絡慢，也不是增加 debounce 能解決的問題。

## 實作邊界

`WordNoteV3TransactionState` 按主 context 共用已校驗的值及 persistent-ID 映射。首次完整讀取後，變更只重新投影受影響模型；提交前仍驗證完整圖，並保留單次 save/rollback。讀取服務、預覽和詞庫卡片篩選使用同一份資料版本。

首輪優化後，10,000 詞的揭示 p95 仍有 3,574.78 ms。第二步把 captureID、業務 ID、詞頭、卡片所屬詞及會話 ID 查找改成 SwiftData predicate；評分序號用降序、limit=1 的查詢，不把所有舊事件實例化。predicate 構造復用既有安全撤銷查詢方式，不拼接 SQL，也不修改 schema 或增加遷移。

直接保存、同容器另一 context 保存會同步使值失效；失敗回滾清掉推測值。改業務 ID、刪除、插入後再刪除均由 persistent ID 對回舊記錄，不靠當前业务 ID 猜測要替換哪一行。原有恢復屏障和未提交模型編輯檢查在快照入口之前執行。備份／修復／遷移仍自行完整讀庫，V1/V2 格式不改。

## 結果與出口

最終 Release，每格為 **p50 / p95 / max，單位 ms**；兩種規模各 30 輪。

| 操作 | 1,000 詞 | 10,000 詞 |
|---|---:|---:|
| 新輸入排隊 | 9.08 / 9.73 / 9.99 | 100.43 / 104.86 / 140.56 |
| 本地命中 | 10.39 / 11.20 / 14.56 | 108.14 / 113.32 / 148.89 |
| 開始復習組 | 17.24 / 18.08 / 23.97 | 180.84 / 192.74 / 259.10 |
| 呈現及更新統計 | 18.75 / 19.89 / 19.89 | 190.66 / 212.18 / 237.01 |
| 揭示、四種預覽及統計 | 20.79 / 21.69 / 28.01 | 195.81 / 211.36 / 243.53 |
| 評分並移至下一張 | 29.81 / 32.67 / 33.48 | 290.83 / 321.72 / 327.56 |

新增 11 項功能回歸及 1 項 opt-in 性能組。功能覆蓋快照重用、十一實體投影、級聯刪除、ID 衝突、直接保存失效、不同容器隔離、保存失敗重試、未保存編輯保護、插入後刪除及提交前額外保存。嚴格 Debug 定向 408 項中 407 通過、1 個性能組跳過；最終 Release 定向 12 項全通過，包含上述 60 個測量輪次。

最終 V3 嚴格 Debug 全套：Core 1,155 項、App 96 項，共 **1,243 通過、8 個 opt-in 跳過、0 失敗**，沒有編譯警告。不為未改動的 provider 路徑重複付費測試。

原生 QA 使用 `learning` 新隔離會話 `6F3A4CC7-2B12-4ABB-9FEC-B23159088975`，英文／淺色、44 詞。Computer Use 已核對：

- 主 Quick Add 輸入 `quick` 並 Command-Return，本地釋義顯示、輸入清空；接著提交 `second isolated capture`，仍可立即保存。
- 新輸入在 Inbox 獨立 Analysis Tasks 中為 Queued；fixture 的既有失敗仍保留。沒有按 Resume Analysis，不宣稱本輪完成模型分析。
- 詞庫 Ready now 與中文 `迅速` 的交集為 1／44，能閱讀 `quick`。搜索由 AX setValue 核對，不把它當中文 IME 或鍵盤焦點驗收。
- 建立 20 張固定組，首張為剛重查的 `quick`；揭示後四個間隔為 10 min、1 day、4 days、7 days。按 Good 後為 1／20、1 reviewed、1 answer，移至 `overfitting`。
- 回到詞庫仍保留原中文搜索及 Ready now，但結果變為 0／44，確認評分後的卡片索引沒有沿用舊值。

日志：`/tmp/wordnote-b03-performance-baseline.log`、`/tmp/wordnote-b03-performance-optimized.log`（只重用快照）、`/tmp/wordnote-b03-performance-final.log`（最終數值）、`/tmp/wordnote-b03-transaction-regression.log`、`/tmp/wordnote-b03-transaction-full.log`、`/tmp/wordnote-b03-performance-qa-launch.log`。採樣文件為 `/tmp/wordnote-b03-performance-sample.txt`；僅用於定位，不是性能分布來源。

完整原生輸入／搜索、首次開頁、三尺寸／主題及生命周期仍按原計劃驗收。普通 App 仍是 V1；本批不升級真實詞庫，不修改 README，不執行 C06 的完整敏感資訊審查。
