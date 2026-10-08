# B04 第一批：純排程與本地查詢信號

日期：2026-10-08（Asia/Hong_Kong）。基線：`a30a6e4`，分支：`codex/supplemental-development`。承接 [B03 刪除與完整性](2026-10-08-b03-deletion-integrity.md)，覆蓋 QA-21 的純核心及 QA-22 的隔離交易部分；不是 B03/B04 正式 App 啟用驗收。

## 本批範圍

- [ReviewCardScheduler](../../Sources/WordNoteCore/Domain/ReviewCardScheduler.swift) 分開 presentation 和 feedback。真正呈現才記 introducedAt/重學次數；feedback 預覽是不可變 before/after 值，不操作 ModelContext。新 Again 才加 lapse；Hard 不算失敗，Good/Easy 沿用原曲線，重學退出為 1/2 個日曆日。
- 每當地日第一次呈現後最多再呈現兩次重學。Again/重學 Hard 間隔是完整 600 秒；用盡次數後延期到次日本地日開始，不標成功完成。Good/Easy 不退還當日 quota，JSON 往返或新 scheduler 實例不重置。已有呈現桶只在下次正式呈現時切換，跨午夜作答本身不佔次日首次呈現。
- [ReviewStudyClock](../../Sources/WordNoteCore/Domain/ReviewStudyClock.swift) 保留 observedAt/effectiveAt，時鐘倒退不刷新 quota 或產生負間隔。日級使用 Gregorian Calendar 加日，DST 可為 23/25 小時；時區改變先等原桶結束。事件保留觀察時間及當時日/時區，後續 writer 必須保存交互高水位。
- [共用校驗](../../Sources/WordNoteCore/Domain/ReviewCardScheduleValidation.swift) 被 scheduler 和完整 V3 snapshot 使用。非法日期、未知時區、缺配對日桶、負/越界計數和不合法 phase 組合拒絕，不回退「現在」。公元前年份不誤寫成公元後 dayKey；不存在的民用日期（如 Pacific/Apia 2011-12-30）不被 Calendar 靜默正規化。本收緊僅作用於未啟用的 V3 邊界，V1/V2 模型/codec 不改。
- [ReviewCardQueuePolicy](../../Sources/WordNoteCore/Domain/ReviewCardQueuePolicy.swift) 分類下一次呈現：先停用/埋藏，再新卡、重學等待/上限，最後日級優先與到期。分鐘到期用 `<= observedAt`，日級用 `< startOfTomorrow`；優先信號不繞過等待、埋藏、停用或新卡配額。
- [V3 capture](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3Capture.swift) 本地精確英文命中保存 occurrence/LookupEvent/必要 membership；只給啟用 wholeTerm 卡增加優先請求，先英文再其他方向。沒有任何卡才建立 new 英文卡，只有 cloze/停用卡時只保留查詢事實。返回原詞庫英文主體及現有釋義，不建立 Inbox/候選/ReviewEvent，也不持有網絡客戶端。
- Term 兼容計數、能力、排程、重要度及歷史三計數快照全部不變，只 touch revision/updatedAt。既有卡不改到期/能力/重學等待，更新 priority、revision 和不倒退的 updatedAt。captureID 重送不再次保存或刷新 priority，刪來源後重送報衝突，不復活資料。
- Save Only、中文查英文及英文未命中繼續保存凍結上下文/方向的草稿或 queued 記錄。捕獲本身不執行分析。寫入遵循全窗口屏障、未提交草稿保護、前後完整關聯校驗與單次保存；任何失敗全交易回滾。

## 測試證據

| 新增測試 | 項數 | 覆蓋 |
|---|---:|---|
| [ReviewCardSchedulerTests](../../Tests/WordNoteCoreTests/ReviewCardSchedulerTests.swift) | 23 | 新舊 Hard 語義分離、四種反饋及曲線、預覽確定性、首次呈現、兩次重學/上限延期、退出不退 quota、序列化恢復、跨午夜等待及作答配額/DST、倒退/時區變更、優先消費、停用/埋藏、溢出、非法民用日期/BCE |
| [ReviewCardQueuePolicyTests](../../Tests/WordNoteCoreTests/ReviewCardQueuePolicyTests.swift) | 9 | 日末嚴格邊界、分鐘精確邊界、優先不越過等待/停用/埋藏/新卡配額、每日上限、時區/倒退不提前抽卡、只讀分類、非法狀態拒絕 |
| [WordNoteV3CaptureTests](../../Tests/WordNoteCoreTests/WordNoteV3CaptureTests.swift) | 22 | 兩方向捕獲上下文、Save Only、全值核對本地命中副作用、反覆查詢/跨服務重送、完整備份及真實磁盤恢复重開、刪來源不復活、選卡/停卡/無卡、固定會話及重學等待不变、非法輸入/歧義/衝突、保存故障/溢出回滾、舊計數達上限仍可查詢、屏障/草稿/時鐘高水位 |

新增合計 54 項。現有 V1/V2 行為、完整性與恢復測試全部保留，沒有用新語義改寫舊 Hard/wrongCount 的斷言。

開發中用 `testAnswerAcrossMidnightDoesNotConsumeNextDaysFirstPresentation` 復現一個真實規則錯誤：23:59 呈現、00:01 作答時，feedback 提前把桶換到次日，導致 00:11 首次呈現被記為 repeat=1。修正前該單例在 Again/Hard 兩分支產生 8 個斷言失敗（`/tmp/wordnote-b04-midnight-red.log`）；修正為只在 presentation 切已有桶後，54 項定向測試全部通過。這是排程斷言失敗，不是測試環境或編譯問題。

| 驗證 | 結果 |
|---|---|
| 最終新增核心定向嚴格 Debug | 54 通過，0 失敗，包含 BCE 及跨午夜作答回歸 |
| 普通 V1 完整嚴格 Debug | 904 項，899 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Debug | 904 項，899 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Release | 904 項，899 通過、5 跳過、0 失敗 |

完整套件分為 Core 859 項（4 跳過）、App 45 項（1 跳過）。跳過項為兩組顯式 opt-in 的付費 DeepSeek、兩組性能及一組原生全局快捷鍵。本批無 provider/prompt 或已啟用 queue 路徑變更，沒有付費調用；實際調用授權保留給需要網絡驗證的階段。

測試只使用人工 fixture、內存/臨時 SQLite、隔離備份/切庫目錄；未讀寫正式詞庫或憑據。時钟及時區可注入，不靠真實等待十分鐘。保存失敗以 beforeSave 注入，實際成功路徑調用 SwiftData save，恢復使用真實 staged SQLite/重開；不宣稱故障注入等於實際斷電測試。

```bash
swift test --scratch-path .build-v3-qa \
  --filter 'WordNoteV3CaptureTests|ReviewCardSchedulerTests|ReviewCardQueuePolicyTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v3-qa \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

本機日誌：`/tmp/wordnote-b04-focused.log` 及 `/tmp/wordnote-b04-{v1-debug,v2-debug,v2-release}.log`。最終四份均無 compiler warning/error，三份全套在跨午夜修復後重新執行，不沿用修復前結果。

`git diff --check` 通過；7 份變更文檔的 177 個本地鏈接目標均存在。V1/V2 schema、codec、原版 SQLite fixture、項目 README 及 docs 索引均未修改。

## 尚未完成

1. 純 feedback plan 不具有正式作答權。V3 writer 還須核對已呈現 item、revision/原始快照、actionID 和窗口租約，將 card/event/item/cursor 原子保存；預覽和提交的同源驗證仍待接入。
2. B05 固定組、全局每日新卡配額、恢復已呈現項不重扣次數、單一可恢復會話和多窗口回答權尚未交付。queue policy 只是分類，沒有冒充完整會話建立器。
3. 普通 App 仍使用 V1，`WORDNOTE_V2_VALIDATION` 入口仍使用 V2。完整 V3 writer/分析隊列/資料保護 UI 與 B03/B04 一起啟用，不把 V2 writer 接到 V3 庫。
4. capture/刪除沿用 MainActor 前後全圖校驗。正式啟用前要量測大詞庫延遲，必要時優化一致性邊界；這批小 fixture 正確性測試不表示性能通過。
5. 沒有新增 V3 頁面、Computer Use 或最低 macOS 14 實機驗收。QA-20/QA-21/QA-22 和 B03/B04 仍保留尚未完成部分。
6. README 介紹、新版界面截圖和全倉/可達歷史敏感資訊檢查仍是代碼完成後的 C06；本批不執行這些收尾，也不分發 App 或合併 main。

下一批接正式 V3 作答交易及同源預覽，再完成 V3 content writer/queue 的隔離 App 集成。
