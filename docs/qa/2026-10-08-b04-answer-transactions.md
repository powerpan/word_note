# B04 第二批：正式作答、揭示與持久收據

日期：2026-10-08（Asia/Hong_Kong）。基線：`396be756fd8d3bb396e574a6d457e1a0f6ac48db`，分支：`codex/supplemental-development`。承接 [純排程與查詢信號](2026-10-08-b04-scheduler-signals.md)，覆蓋 QA-21 的值層預覽/保存及 QA-24 的部分寫入保護。這是隔離 V3 的核心交易，不是完整 Review 或正式 App 啟用驗收。

## 本批範圍

- [WordNoteV3ReviewService](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewService.swift) 復用 ContentService 的 MainActor context、WriteGate、未保存草稿保護、前後完整快照校驗及單次 save/rollback。只接受當前 active/presented 項，不隱式建立會話、呈現卡片或消耗新卡配額。
- [回答權](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewOwnership.swift) 按 ModelContainer 共享，綁 sessionID、ownerID、隨機 lease ID 及恢復 generation。同 owner 重取維持能力，其他窗口被拒；遲到 release 不能釋放新 owner。容器弱引用避免持有已關閉資料庫。僅保證同進程、同 runtime 容器的窗口協調，不提供獨立進程/容器同寫支持。
- [揭示交易](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewReveal.swift) 核對完整畫面快照，保存同詞啟用 sibling 的 burial 及本組 siblingDeferred，不改能力、原始 due 或其他已結束會話。較晚的 burial 不縮短；當前卡更新 revision/交互高水位，但不再計一次呈現。只有保存成功才授予內存揭示能力；同快照重揭示不重存。換窗口/重開/恢復後必須重新揭示。
- [反饋交易](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewFeedback.swift) 重新計算原預覽並核對完整 Term/TermState/Card/Session/Item，漏加 revision 的內容變更也會被拒。按實際點擊時間計算 due，相對間隔、日/時鐘異常及結果狀態必須與預覽一致；跨日或倒退要求刷新。事件保存原始觀察時間，卡片 updatedAt 不倒退。
- 一次保存 version=2 ReviewEvent、卡片新排程、item attempt/lastAction/結果、session 游標/revision。Again 的等待、重學上限延期與 reviewed 分開。游標只前進到固定集合的下一項，不把 pending 偷換成 presented；沒有普通待辦但有重學則 waiting，全部終態才 completed。
- [不可變值與收據](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewValues.swift) 不暴露可變模型。actionID 同內容重送只讀回已保存結果，不再寫事件/游標或清除下一卡的揭示。會話完成、卡片刪除及完整備份恢復後仍可讀 originalCardID；異內容衝突、事件作廢、Term 級聯刪除後不補造事件。保存後僅做不拋錯的內存清理，避免已成功落庫卻報失敗。
- [共享完整校驗](../../Sources/WordNoteCore/Infrastructure/Persistence/V3/WordNoteSnapshotV3Validation.swift) 新增 presented new 卡必須有 introducedAt 的約束，導入/啟動/寫入前一致阻止，不由評分入口補造首次引入。沒有新增 schema 欄位或修改 V1/V2 codec，Term 兼容排程/能力/計數及 legacy 歷史不雙寫。

## 測試證據

| 新增測試 | 項數 | 覆蓋 |
|---|---:|---|
| [WordNoteV3ReviewFeedbackTests](../../Tests/WordNoteCoreTests/WordNoteV3ReviewFeedbackTests.swift) | 15 | 四種反饋/實際提交時間、重學 Hard/上限、固定游標、同 action 重送/異內容衝突、二次點擊、舊回調不清除下一張揭示、跨午夜刷新、刪詞/刪卡、事件作廢、完整備份和磁盤恢復、時鐘倒退、非法預覽 |
| [WordNoteV3ReviewGuardTests](../../Tests/WordNoteCoreTests/WordNoteV3ReviewGuardTests.swift) | 14 | 跨服務窗口回答權、釋放/恢復失效、舊會話不鎖新會話、未揭示/未呈現/非活躍拒絕、草稿不被保存或回滾、完整依賴比對、無關編輯、查詢信號、保存故障重試、revision 溢出、舊 schema/非法時間、introducedAt 缺失 |
| [WordNoteV3ReviewRevealTests](../../Tests/WordNoteCoreTests/WordNoteV3ReviewRevealTests.swift) | 6 | sibling 埋藏及本組延期、重揭示冪等/不縮短 burial、失敗回滾且不授權、過期畫面/失去回答權、恢復後不保留揭示能力、已呈現第二次重學不重扣次數 |

新增合計 35 項。共用 [人工 fixture](../../Tests/WordNoteCoreTests/WordNoteV3ReviewTestSupport.swift) 先經純 scheduler 的 presentation，再構造可評分會話；這不等於已交付 B05 會話建立器。

開發中 `testPresentedNewCardRequiresPersistedIntroductionBeforeImportOrAnswer` 先復現四個斷言失敗：快照驗證未拒絕、導入未拒絕並寫入四個詞、writer preflight 接受缺失引入時間的 presented new 卡。日誌：`/tmp/wordnote-b04-writer-introduction-red.log`。修正共享校驗後，擴大 208 項 V3/排程測試全部通過。既有 B03 刪除測試的 cloze fixture 改為真正執行 presentation 取得 introducedAt；未削弱刪除斷言，也沒有靜默修復實際資料。

| 驗證 | 結果 |
|---|---|
| 最終 V3/ReviewCard 定向嚴格 Debug | 208 通過、0 跳過、0 失敗 |
| 普通 V1 完整嚴格 Debug | 939 項，934 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Debug | 939 項，934 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Release | 939 項，934 通過、5 跳過、0 失敗 |

完整套件包含 Core 894 項（4 跳過）、App 45 項（1 跳過）。跳過項為兩組付費 DeepSeek、兩組顯式性能測試和一組原生快捷鍵。這批沒有 provider/prompt/啟用中的分析隊列變更，未發起付費請求；不把授權或跳過寫成實際調用通過。

所有測試使用人工 fixture、內存/臨時 SQLite 與隔離 staged restore；未操作正式詞庫或憑據。成功路徑實際調用 SwiftData save，完整備份恢復後重新開磁盤庫核對收據。保存失敗用 beforeSave 注入，時間可注入，不靠實際等待十分鐘；故障注入不等於實際斷電測試。

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

本機日誌：`/tmp/wordnote-b04-writer-focused.log`、`/tmp/wordnote-b04-writer-v1-debug.log`、`/tmp/wordnote-b04-writer-v2-debug.log`、`/tmp/wordnote-b04-writer-v2-release.log`。最終四份均無 compiler warning/error；完整三套在 introducedAt 約束修正後執行，不沿用修正前套件數。

`git diff --check` 通過；7 份變更文檔的 189 個本地鏈接目標均存在。V1/V2 schema/codec、原版 SQLite fixture、App runtime 入口及 README 均未修改。

## 尚未完成

1. B05 尚須固定組建立/排序、真正呈現及冪等恢復、全局每日新卡配額、暫停/繼續/Skip/Later、統計與窗口生命週期。核心租約必須由 UI 在關窗/離開等事件釋放，不以存在 registry 推定原生窗口整合完成。
2. B06 這批僅實作揭示後 sibling 交易；題型內容、原句 Unicode 範圍定位/遮蔽、輸入與頁面仍待實施。
3. 普通入口仍為 V1，`WORDNOTE_V2_VALIDATION` 仍為 V2。完整 V3 content writer/分析隊列/runtime/資料保護 UI 尚須整套切換，禁止把 V2 writer 接到 V3 容器。
4. 交易沿用 MainActor 前後全圖校驗，大詞庫延遲仍是正式啟用前的性能門檻。現有小 fixture 正確性回歸不證明性能合格。
5. 本批沒有 V3 頁面、Computer Use 或最低 macOS 14 實機驗收。QA-21/QA-24 只標記上述核心證據，不標記完整驗收通過。
6. README 項目介紹、新版截圖與全倉/暫存區/可達 Git 歷史敏感資訊審查仍在代碼開發後的 C06；本批不執行，不分發 App，不合併 main。

下一批先補 B05 會話建立、呈現/恢復與全局每日新卡配額，再推進完整 V3 writer/queue/runtime 集成。
