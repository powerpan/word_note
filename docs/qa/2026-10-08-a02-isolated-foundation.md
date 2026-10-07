# A02: Isolated V2 Foundation

日期：2026-10-08（Asia/Hong_Kong）。基線：`4dcfe0d`；工作分支：`codex/supplemental-development`。

本記錄對應隔離資料基礎提交 `a1a7d1b`；後續服務及測試進展另見 [V2 內容交易](2026-10-08-a02-content-transactions.md)，以下結果保留為當時驗證，不代表最新整體狀態。

## 狀態與邊界

此批為 A02 的隔離資料基礎，不是 A02 完成，也不是正式詞庫遷移。A01 的實機驗收仍待補；App 啟動、現有服務、主窗口/浮窗及 Settings 恢復入口都仍使用 V1。沒有改寫使用者資料庫，沒有重啟正式 App，沒有合併 main。

README、產品介紹截圖和全倉敏感資訊檢查仍留在 C06，本批未執行。本批也沒有 DeepSeek 請求；它驗證的是完全本地的版本轉換，最近一次 live 證據仍見 [A01 后台與性能記錄](2026-10-08-a01-background-persistence.md)。

## 實施內容

1. 五個既有模型凍結為 `WordNoteSchemaV1` 的獨立歷史類型；只增加命名空間/別名，不改既有字段與方法。V1 snapshot adapter 顯式引用 V1 類型，避免將來別名切換污染舊讀取器。
2. `WordNoteSchemaV2` 另定義八個模型：保留五個既有實體，新增 TermOccurrence、TermCourseLink、LookupEvent，補齊方向、generation、attempt、重試、revision、savedTermID 和 legacy 計數語義。
3. 純值 `WordNoteV1ToV2Migration` 保守回填課程與來源，固定 legacy capture UUID；不改原始文本、ID、Term/ReviewEvent 內容，不把舊查詢次數虛構成事件。saved 候選僅在來源和規範詞頭唯一匹配時关联，否則保留 unresolvedLegacy 與報告。
4. 預檢對 dangling 外鍵和孤立候選/復習事件列出 ID，阻止轉換，不先刪除或修復原庫。缺少 sourceRecordID 但有 contextSentence 時保留歷史上下文；沒有來源不製造記錄。
5. V2 完整邏輯快照、八實體 counts、checksum、格式/版本路由、字段和業務唯一鍵校驗、空庫建庫及持久化重開對比。V1/V2 adapter 都拒絕錯誤版本 context，V1 App 仍拒絕 V2 快照。

具體回填與快照協議同步在 [資料模型](../05-data-model.md) 和 [架構](../04-technical-architecture.md)。

## 測試矩陣

新增 `WordNoteV2PersistenceTests` 22 項，覆蓋：

| 範圍 | 驗證 |
|---|---|
| 真 V1 | 複製原始凍結 fixture，讀取所有字段並與既有人工樣本逐值比對；V2 建库/重開後完整快照相等；V1 副本和原 fixture 保持可讀/不變 |
| 切換閘門 | App 頂層別名及 migration plan 仍只有 V1；不因 V2 編譯進程式便啟動遷移 |
| 確定性 | 重跑與反轉 fetch 順序的 payload/issue/checksum 相同，固定 capture ID 樣本；不同提交即使同文字也不同 captureID |
| 來源 | 同一提交產生兩個詞，各有 occurrence 但共享 capture；原文、筆記、歷史課程/時間不丟失；fallback 保留空白，無來源不偽造 |
| 候選 | 唯一 source+normalizedTerm 才關聯；歧義和只有同詞沒有來源關係均不亂連；saved/targetDeleted/unresolvedLegacy 狀態校驗 |
| 統計 | wrongCount、duplicateHitCount、舊 review history 不改；非英文歷史詞條保留並列報告，不因遷移刪除 |
| 隊列 | 漢字/拉丁字母邊界的凍結規則；中斷分析回 queued，失敗保留摘要，不生成網絡 attempt 或自動重試 |
| 快照 | 所有新增字段用非預設值往返，含多課程、来源 title/url/page、查詢事件、revision、attempt、退避和偏好 |
| 壞輸入 | 缺/多/重複元資料、重複業務鍵、跨 capture 關聯、非法 enum/計數/時間、過長文本、checksum/count/格式/版本不符 |
| 寫入邊界 | 空庫可轉換；非空庫/錯版本拒絕；非法 payload 在插入前失敗；空 V1 不生成任何實體 |

原 V1 fixture SHA-256 仍由 `FrozenV1StoreTests` 驗證為 `92f4003123fb65a7763f7baf646f3558916e74ebe807832ddf51a7f94398b7de`；未重新生成它來配合新類型。

## 命令與結果

主機沿用 A01 已記錄的 Apple M4、16 GiB；本批重新核對 macOS 27.0.1（26A434）、Apple Swift 6.4（swiftlang-6.4.0.34.1）。Swift 5 language mode，最低 target macOS 14；尚未在真正 macOS 14 實機驗證。

```bash
RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test -c release \
  --filter WordNoteV2PersistenceTests -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

swift build -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

| 最終檢查 | 結果 |
|---|---|
| 嚴格離線全套 | 210 項，208 通過、2 跳過、0 失敗；測試耗時 2.590 秒 |
| 跳過項 | live DeepSeek 和 opt-in 大庫性能組；本批不重複付費調用，也不把上批性能數據當作 V2 測量 |
| Release V2 測試 | 22 項全通過，0.151 秒；含 SQLite 新庫保存、重開和完整字段比對 |
| 嚴格 App 建置 | 通過，沒有 warning 被忽略 |
| 文檔/差異 | 本批文檔相對鏈接有效，git diff --check 通過 |

開發中遇到 Swift 6.4 對協議元類型靜態 key path 的編譯器崩潰；測試改用 `ObjectIdentifier` 比較 schema 類型後可編譯，沒有改動正式業務以繞過此問題。其他初始編譯問題（重複 Swift 檔名、初始化器及 helper 可見性）也已修正，並由最終命令重新驗證。

## 尚未完成

- V2 的正式寫入/刪除/完整性服務、revision 更新、精確命中 occurrence/lookup 寫入和多課程查詢。
- App vault/coordinator 的 V1/V2 版本路由、遷移前保護快照、staged V2 store 日誌與啟動切換，以及崩潰/取消端到端測試。
- A01/A02 實機驗收與最低 macOS 相容性；最近一次 Computer Use 明確回報鎖屏，尚未收到解鎖確認，本批沒有反覆重試。

上述接入和回歸完成前，禁止改 App 頂層別名啟用 V2，禁止把本批當成完整 QA-06/QA-07 通過。後續不得繞過 A01 的資料保護與實機驗收閘門。
