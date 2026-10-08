# B05 第一批：固定會話、首次呈現與新卡配額

日期：2026-10-08（Asia/Hong_Kong）。基線：`788c248d6720bf25f641d55395a8cd38354333e8`，分支：`codex/supplemental-development`。承接 [B04 作答交易](2026-10-08-b04-answer-transactions.md)，增加 QA-23/QA-24 的核心證據；不是正式 Review 頁面或 V3 runtime 啟用驗收。

## 本批範圍

- [ReviewSessionSelection](../../Sources/WordNoteCore/Domain/ReviewSessionSelection.swift) 按 membership/方向/隊列選固定集合，不用 Term 的 legacy 課程字段。已到分鐘重學、優先請求、日級到期、顯式補新卡依次選入；同類按 due/priority/有效新 Again 次數/手動重要度/建立時間/UUID 穩定排序。薄弱隊列排除 legacy wrongCount 與已作廢事件；中文回憶無釋義不入選。target 預設 20（5-100），newLimit 預設 10（0-50），預設不補新卡。
- [會話入口](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewSessions.swift) 同交易固定 ID/範圍/名稱/順序/配額上限，建立只存 pending。空選擇不建空組；只允許一個可恢復組。同 sessionID/同參數重試只讀回既有組，包括已提前結束的組；不同參數拒絕。課程改名、membership 移除、新卡加入不改本組快照或數量。
- [正式呈現](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewPresentation.swift) 受租約、revision、恢復屏障和草稿保護。當前 presented 項只讀恢復，不重扣配額或重學次數；先有當前卡就不被已到重學打斷。沒有當前 presented 時，本組到點重學優先於 pending，未到點返回 nil。呈現不写 ReviewEvent，卡片/項/游標/台帳一次 save；故障、額度耗盡或計數溢出全部回滾。
- [ReviewNewCardQuota](../../Sources/WordNoteCore/Domain/ReviewNewCardQuota.swift) 按全部會話台帳的 originalCardID 全局計量，第一次呈現才扣；換課程/方向、結束另開或重啟不取得額外一份額度。已引入未評分的 new 卡可繼續，不需重新開補新卡或再扣額度。未用額度不累積，刪卡/刪詞保留無詞文用量。
- [Session 模型](../../Sources/WordNoteCore/Data/Schema/V3/ReviewSessionModel.swift) 增加可空 introductionsJSON，保存 originalCardID、觀察時間、chargedAt 高水位、日/時區。日桶在原時區结束前不切換；重疊日區間保守計數，回調時鐘不清零，DST 使用 Calendar 本地日界。完整快照驗證台帳唯一、屬於本組、日期合法及存活卡 introducedAt 一致。
- 暫停保存後釋放回答權，繼續保留原組/當前項但須新 lease 和重新揭示；提前結束不改卡片排程、不補作答/成功量。保存失敗不釋放租約，過期回調不能提交。刪卡保留 unavailable 固定項，不從新詞庫補位。
- [V3 backup codec](../../Sources/WordNoteCore/Infrastructure/Persistence/V3/WordNoteSnapshotV3Codec.swift)、[共用 reader](../../Sources/WordNoteCore/Infrastructure/Persistence/WordNoteSnapshotReader.swift) 和 [V3 修復證據](../../Sources/WordNoteCore/Infrastructure/Persistence/V3/WordNoteV3RepairEvidenceVault.swift) 分別對 ordinary backup / evidence 使用 format=2，避免舊 decoder 忽略台帳卻報成功。新 reader 可讀無台帳的 format=1；有台帳降標拒絕。修復證據仍原樣保存損壞資料而不冒充普通備份。

## 測試證據

| 新增測試 | 項數 | 覆蓋 |
|---|---:|---|
| [WordNoteV3SessionSelectionTests](../../Tests/WordNoteCoreTests/WordNoteV3SessionSelectionTests.swift) | 10 | 20 張預設/固定 pending、補新卡/額度、membership/方向、四級排序與等值次序、分鐘/日末邊界、legacy/作廢 Again 排除、建組重試/單一組、課程改名/增卡不擴組、輸入/故障回滾、缺中文拒絕 |
| [WordNoteV3SessionPresentationTests](../../Tests/WordNoteCoreTests/WordNoteV3SessionPresentationTests.swift) | 13 | 首次呈現/重讀、暫停/繼續/正面恢復、600 秒邊界、重學不打斷眼前卡、提前結束、呈現/控制保存故障、草稿/revision、真實備份與磁盤重開、恢復屏障、刪卡不補位、完整兩次重學上限、配額重檢/計數溢出 |
| [WordNoteV3NewCardQuotaTests](../../Tests/WordNoteCoreTests/WordNoteV3NewCardQuotaTests.swift) | 11 | 跨課程/新組全局用量、刪卡/詞不退額度、未評分新卡繼續、時區凍結/重疊、時鐘倒退、23/25 小時日及不累積、舊原型缺省台帳、非法關聯/日期/重複、backup 與 evidence 格式保護/舊格式讀取 |

新增合計 34 項，共用 [隔離人工資料](../../Tests/WordNoteCoreTests/WordNoteV3SessionTestSupport.swift)。沒有修改或讀取真實詞庫。Core 成功路徑真正調用 SwiftData save；完整備份測試通過 staged restore 寫入新的 SQLite 再重開，檢查所有 payload 和配額，不只 mock JSON。保存故障用 beforeSave 注入，不聲稱測過實際断電；時鐘可注入，不靠真實等待十分鐘。

開發中先修正新測試的 missing try、獨占訪問及 legacy fixture 計數設定，這些是測試編譯/設定錯誤，不記成產品修復。之後備份格式單例 `testLedgerBackupUsesNewFormatAndCannotBeRelabeledAsOld` 復現 3 個斷言失敗：新台帳仍用 format=1，codec/共用 reader 接受把台帳當舊格式。日誌 `/tmp/wordnote-b05-format-red.log`。升級 envelope 並保留無台帳舊格式讀取後通過；修復證據採同一向後保護原則。

| 最終驗證 | 結果 |
|---|---|
| V3/ReviewCard 定向嚴格 Debug | 242 通過、0 跳過、0 失敗 |
| 普通 V1 完整嚴格 Debug | 973 項，968 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Debug | 973 項，968 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Release | 973 項，968 通過、5 跳過、0 失敗 |

完整套件分為 Core 928 項（4 跳過）、App 45 項（1 跳過）。跳過為兩組付費 DeepSeek、兩組性能及一組原生快捷鍵。沒有 provider/prompt/已啟用隊列路徑改動，本批未作付費調用；不把跳過視為實機或性能已通過。

```bash
swift test --scratch-path .build-v3-qa --filter 'WordNoteV3|ReviewCard' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v3-qa \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

最終本機日誌：`/tmp/wordnote-b05-expanded.log`、`/tmp/wordnote-b05-v1-debug.log`、`/tmp/wordnote-b05-v2-debug.log`、`/tmp/wordnote-b05-v2-release.log`。四份均無 compiler warning/error；三套完整回歸在普通備份與修復證據格式修正後重新執行，不沿用早期 31 項/970 項結果。

`git diff --check` 通過；7 份變更文檔的 198 個本地鏈接目標均存在。README、App 入口和 V1/V2 schema/codec/原始 SQLite fixture 未修改；共用 snapshot reader 僅額外放行 V3 format=2，V1/V2 仍拒絕該格式。

## 兼容與剩餘

1. V3 是未啟用的原型 schema，本次新增可空台帳欄位，沒有改 V1/V2 模型/codec/原始 SQLite fixture。舊原型 V3 JSON 可由新 reader 讀取；沒有驗證或承諾原型 SQLite 跨模型直接打開。帶新台帳的備份不能由舊 reader 靜默降級。
2. 舊原型資料若沒有台帳，只能保守計算存活卡的 introducedAt。已刪且從未記錄的舊引入用量不可恢復，不捏造歷史；實際 V1/V2 遷移沒有 introducedAt，並非把正式用戶的新卡配額清零。
3. Skip/Later、分類統計、Settings/Review UI 及窗口生命週期尚待接入。本批有暫停/繼續/結束核心，不代表離開頁面/關窗的原生行為已驗收。B06 題型內容、填空定位和交互仍待實作。
4. 普通 App 仍為 V1，`WORDNOTE_V2_VALIDATION` 仍為 V2。完整 V3 writer/分析隊列/runtime/資料保護 UI 必須共同切換，不掛接 V2 writer 到 V3 庫。大庫 MainActor 前後全圖校驗性能門檻未測，不能從小 fixture 推定達標。
5. 本批沒有 Computer Use、最低 macOS 14 實機或 UI 完成聲明，也未分發、合併 main。README 介紹/截圖與全倉/暫存區/可達 Git 歷史敏感資訊審查仍在代碼開發後的 C06。

下一批补 Skip/Later 及可信統計，再接完整 V3 runtime/UI。
