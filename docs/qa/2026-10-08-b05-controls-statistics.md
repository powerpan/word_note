# B05 第二批：非評分控制與可信統計

日期：2026-10-08（Asia/Hong_Kong）。基線：`8da598cf19f42797e51e7c9d05dac2b1f0ddbab4`，分支：`codex/supplemental-development`。承接 [B05 會話與呈現](2026-10-08-b05-session-presentation.md)，補 QA-23/24/27 核心證據；不是 V3 runtime 或原生 Review UI 完成聲明。

## 實作

- [控制交易](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewControls.swift) 使用與正式回答相同的完整來源快照、單窗口租約、寫入屏障、草稿保護和 save/rollback。Skip/Later 不必先揭示，不写 ReviewEvent；共用全局 actionID，異操作衝突拒絕。同 actionID/source 重試只返回已保存收據，完成/刪詞/恢復後仍可查回，不清理下一張卡的揭示能力。
- Skip 只輪轉固定 items，保留 presented、卡片排程、引入及重學配額。連續略過所有當前可答項即保存 paused/釋放租約；未到點重學不阻止暫停，已到點重學交由下一次正式呈現。明確繼續從輪轉隊首恢復；正式反饋、Later、明確繼續清空略過輪次。過渡游標若仍指向已略過項，不允許讀成可提交答案。
- [純延期規則](../../Sources/WordNoteCore/Domain/ReviewCardScheduler.swift) 把 due 延到不倒退時鐘的次日本地日界，relearning 不早於原桶日末。new 轉 review 只是為了保存 due，不提升 mastery/streak；relearning 保留 phase。最後作答、lapse、interval 和呈現桶保留，只消費不晚於觀察時間的 priority。Later item 終態不增加 attempt、不改 lastActionID。
- [控制值](../../Sources/WordNoteCore/Domain/ReviewSessionControls.swift) 保存 action/item/originalCard 身份、来源指紋、觀察/有效時間、结果 revision/status/due 和 skippedItemIDs。每組最多 10,000 筆，達限明確失敗、保留舊收據。沒有詞文/答案正文，但 hash 不被宣稱為敏感資料加密。
- [正式反饋](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewFeedback.swift) 在同一交易分配 recordedOrder，按所有現存事件（含 invalidated）最大值遞增，溢出全回滾。原始 reviewedAt/dayKey 不改写，系統時鐘倒退不改變首答先後。
- [共用統計](../../Sources/WordNoteCore/Domain/ReviewStatistics.swift) 僅讀完整快照。有效 semantics=2 事件先全局按凍結日/card 去重首答，再按當前 membership、模式或固定 session 篩選。Hard 算成功回憶，但重學 Hard/Again 上限不是成功完成；零樣本 ratio 為 nil。舊 V3 缺序號按觀察時間/UUID 回退且標估計；legacy 和 invalidated 不混入。
- 會話以實際固定項數為進度分母，分列 reviewed、手動 Later、上限延期、無法確認原因延期、siblingDeferred、unavailable 和無有效成功證據的 completed。回答次數、不同卡、成功完成卡數分開。刪卡後用 originalCardID 保留真實事件；刪詞級聯移除的事件不補造。工作量復用現有 queue policy，區分可答、等待、新卡、埋藏/停用及缺答案。
- [完整快照驗證](../../Sources/WordNoteCore/Infrastructure/Persistence/V3/WordNoteV3ControlValidation.swift) 同時約束控制記錄、來源/種類、全局 actionID、正且唯一的 recordedOrder。新寫 V3 普通備份及修復證據為 format=3；format=1/2 在沒有較新字段時仍可讀，降標不能靜默忽略控制/序號。損壞控制仍能原樣保存為修復證據。

## 驗證

| 新增測試 | 項數 | 主要覆蓋 |
|---|---:|---|
| [WordNoteV3SessionControlTests](../../Tests/WordNoteCoreTests/WordNoteV3SessionControlTests.swift) | 10 | 輪轉/暫停/隊首繼續、不重扣配額、等待/到時重學、Later 新卡/重學、重送不清新揭示、跨種類/評分衝突、完整回滾、草稿/過期/屏障、磁盤恢復/刪詞、10,000 上限/溢出 |
| [ReviewCardPostponementTests](../../Tests/WordNoteCoreTests/ReviewCardPostponementTests.swift) | 4 | 春秋 DST、倒退時鐘與未來 priority、時區切換保留原桶、非法/停用/埋藏拒絕 |
| [WordNoteV3ReviewStatisticsTests](../../Tests/WordNoteCoreTests/WordNoteV3ReviewStatisticsTests.swift) | 11 | 零樣本/legacy、回答與不同卡/完成、Hard、上限/手動延期、作廢/不明終態、倒退保存順序/缺省估計/跨會話首答、凍結日桶、membership/模式/全局去重、刪卡/詞、工作量、序號溢出 |
| [WordNoteV3ControlPersistenceTests](../../Tests/WordNoteCoreTests/WordNoteV3ControlPersistenceTests.swift) | 7 | staged restore/磁盤重開和統計一致、format=1/2/3 矩陣、兩種新字段獨立降標保護、非法收據/混合 actionID、序號約束、損壞證據/舊證據兼容 |

新增合計 32 項，僅使用 [隔離人工資料](../../Tests/WordNoteCoreTests/WordNoteV3SessionTestSupport.swift)。沒有查閱或寫入真實詞庫。保存/恢復測試實際執行 SwiftData save、快照編解碼、staging SQLite 和磁盤重開；beforeSave 注入是保存失敗測試，不冒充實際斷電。時鐘注入，不靠等待 10 分鐘。

| 最終驗證 | 結果 |
|---|---|
| V3/ReviewCard 擴大嚴格 Debug | 274 通過、0 跳過、0 失敗；隊首恢復的最後微調另納入完整回歸 |
| 普通 V1 完整嚴格 Debug | 1005 項，1000 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Debug | 1005 項，1000 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Release | 1005 項，1000 通過、5 跳過、0 失敗 |
| 授權 DeepSeek V2 雙向真實調用 | 1 項通過，2 次請求，約 5.30 秒；本地重查沒有第三次 API 請求 |

普通完整套件 Core 960 項（4 跳過）+ App 45 項（1 跳過）。離線跳過項為兩個付費 DeepSeek 組、兩個 opt-in 性能組和一個原生快捷鍵組；不能把這些當已驗證。未觸及 provider/prompt/已啟用分析隊列實作，真實調用只作當前整合冒煙，不證明 V3 尚未接入的分析工作流。

授權 live 使用現有 resolver 配置，沒有手工讀取或輸出 key，只發送人工英文短語和中文技術詞。測試驗證候選先留待確認、中文查英文保持英文主體、確認後大寫精確重查復用本地釋義與新增一次查詢事件。請求模型為程式預設 `deepseek-v4-flash`、thinking disabled；服務回應的 model 標識為 `deepseek-flash`，兩次均成功。沒有第三次遠端請求，也沒有用真實私人詞庫做樣本。

```bash
swift test --filter 'WordNoteV3|ReviewCard' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
RUN_LIVE_DEEPSEEK_V2_TESTS=1 swift test --filter LiveDeepSeekV2QueueTests \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

本機日誌：`/tmp/wordnote-b05-controls-expanded.log`、`/tmp/wordnote-b05-controls-v1-debug.log`、`/tmp/wordnote-b05-controls-v2-debug.log`、`/tmp/wordnote-b05-controls-v2-release.log`、`/tmp/wordnote-b05-controls-live.log`。三套最終完整回歸均無編譯 warning/error；初輪備份版本舊断言已隨 format=3 更新並增加跨版矩陣，不沿用初輪失敗結果。`git diff --check` 通過，7 份變更文檔的 204 個本地鏈接目標全部存在。

## 邊界與下一步

1. 普通 App 仍使用 V1，V2 QA 仍使用 V2；這一批沒有用 V2 writer 寫 V3，也未升級實際詞庫。V3 為未發布原型；新可空字段的 JSON 兼容已驗證，不承諾舊原型 SQLite 跨模型直接開啟。
2. 統計報表按目前 membership，不宣稱歷史課程歸屬。asOf 是同一快照的工作量/當日日鍵參考，不是回溯重建過去資料庫；凍結事件不因系統時鐘或報表時區變動而重寫。舊缺省順序只是估計。
3. 控制記錄、完整圖驗證、聚合仍需大庫性能驗證。當前小 fixture 的正確性與上限測試不能證明正式 UI 延遲達標。
4. B05 Settings/Review UI、離頁/關窗/睡眠生命周期仍待與完整 V3 writer/queue/runtime 接入。B06 題型內容、原句填空定位/遮蔽和輸入仍待實作，B07 頁面不能先套舊混合統計。
5. 未聲稱 Computer Use/最低 macOS 14 實機验收；未分發、未合併 main。README 改寫/介紹截圖及全倉/暫存區/可達歷史敏感資訊審查仍留到代碼完成後的 C06。
