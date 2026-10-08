# B03 隔離 V3 模型、遷移與快照

日期：2026-10-08（Asia/Hong_Kong）。基線：`e733e70`，分支：`codex/supplemental-development`。對應 QA-19 及部分 QA-20，不是 B03/B04 完整啟用驗收。

此檔保留第一批時點的測試及未過門檻。後續共用 reader/完整備份/日誌/受保護啟動已於 [第二批](2026-10-08-b03-protected-recovery.md) 接入；目前能力與剩餘範圍以第二批及 [開發計劃](../13-supplemental-development-plan.md) 為準，不回寫第一批歷史測試結果。

## 實作範圍

- [WordNoteSchemaV3](../../Sources/WordNoteCore/Data/Schema/WordNoteSchemaV3.swift) 持有獨立十一實體，未改 V1/V2 歷史模型。新增 ReviewCard/ReviewSession/ReviewSessionItem，擴展 Term 歷史計數及 ReviewEvent 元資料。
- [ReviewCardState](../../Sources/WordNoteCore/Domain/ReviewCardState.swift) 定義共用排程快照、會話狀態、範圍和 Unicode 填空目標；這是資料契約，尚未實作 B04 scheduler/B05 會話控制器。
- [V2 -> V3 遷移](../../Sources/WordNoteCore/Infrastructure/Persistence/V3/WordNoteV2ToV3Migration.swift) 為純值離線轉換。每詞一主卡、nil 排程 suspended、其他有排程歷史待辦保持 review；lastReviewedAt/mastery/interval/streak 保留，lapse=0，不補造 introducedAt、其他方向、會話或作答。
- 同時戳事件以 UUID 字串較大者取最後；主卡 ID 使用固定 SHA-256 命名空間映射。舊 contextCloze 無穩定範圍時，若是最後事件則阻止遷移並報告 term/event ID，不修改來源或調 AI。
- [完整 V3 payload](../../Sources/WordNoteCore/Infrastructure/Persistence/V3/WordNoteSnapshotV3Payload.swift) 及 [codec](../../Sources/WordNoteCore/Infrastructure/Persistence/V3/WordNoteSnapshotV3Codec.swift) 包含全部十一類計數和元資料；sourceSchemaVersion=3.0.0，formatVersion=1，64 MiB 限制及 canonical checksum。content 不是完整 V3 備份。
- [校驗](../../Sources/WordNoteCore/Infrastructure/Persistence/V3/WordNoteSnapshotV3Validation.swift) 拒絕重複業務鍵、缺失/跨詞/跨會話引用、重複 actionID、舊事件冒充新語義、混合計數被改寫、錯誤游標/作答數/日桶、失效 cloze 原文 hash 和 Character 範圍。
- 只允許空 V3 庫導入，十一實體單次保存，保存前故障會 rollback。SwiftData 的 JSON 字段嚴格解碼，不把損壞內容當空白。
- 新 event.originalCardID 與可解除 cardID 分離；刪卡後會話項保留 originalCardID 並標 unavailable。此批驗證合法 tombstone 的恢復，不冒充 V3 刪除交易已完成。

## 測試

| 測試 | 覆蓋 |
|---|---|
| [WordNoteV3MigrationTests](../../Tests/WordNoteCoreTests/WordNoteV3MigrationTests.swift) | 9 項：工作量/方向/tie-break/歷史字段/無推斷/cloze 阻止/損壞源/空庫 |
| [WordNoteV3PersistenceTests](../../Tests/WordNoteCoreTests/WordNoteV3PersistenceTests.swift) | 12 項：原版 V1 SQLite 接續遷移、十一實體字段、活動游標/已刪卡/Unicode 磁盤重開、checksum、舊 reader 拒絕、空庫限制、保存前故障與損壞 JSON |
| [WordNoteV3ValidationTests](../../Tests/WordNoteCoreTests/WordNoteV3ValidationTests.swift) | 16 項：元資料/唯一鍵/計數/新舊事件/引用/日桶/會話/tombstone/cloze/兼容 Term 不被卡片值修改 |

原始 `Fixtures/v1.store` 只讀，複製到臨時目錄後開啟，測試後重新讀取 fixture bytes 保持相同。其他資料均為合成值或臨時 ModelContainer。保存故障為 beforeSave 注入，不聲稱已做磁碟滿的真實文件系統故障。

| 驗證 | 結果 |
|---|---|
| V3 定向嚴格 Debug | 37 通過，0 失敗 |
| 普通 V1 完整嚴格 Debug | 767 項，762 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Debug | 767 項，762 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Release | 767 項，762 通過、5 跳過、0 失敗 |

```bash
swift test --scratch-path .build-v3-qa \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors \
  --filter WordNoteV3
swift test --scratch-path .build-v3-qa \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

本機日誌為 `/tmp/wordnote-b03-focused.log` 及 `/tmp/wordnote-b03-{v1-debug,v2-debug,v2-release}.log`，四份最終日誌均無 compiler warning/error。5 個默認跳過為兩組 live DeepSeek、兩組性能及一組 native hotkey；本批不需要網絡。`git diff --check` 通過，本批 7 份文檔的 157 個本地鏈接目標均存在。

## 未過門檻

1. V3 尚未接入 WordNoteSnapshotReader、VersionedPayload、vault/counts、staged restore 日誌、啟動遷移與資料保護；舊入口必須拒絕 V3，不能退化為只恢復 content。
2. V3 刪除/完整性交易、B04 scheduler/查詢信號、B05 正式作答冪等和會話窗口租約尚未實作。本批校驗測試不證明那些工作流已完成。
3. 真實 App 仍使用 V1，隔離 QA App 仍使用 V2；未切換 typealias/入口、未讀寫真實詞庫，無 UI 改動或 Computer Use 驗收聲明。最低 macOS 14 仍待實機驗證。
4. README、介紹截圖及全倉/可達 Git 歷史敏感資訊檢查仍在 C06 後置交付，不在本批執行；無付費 AI 調用、不分發 App、不合併 main。

下一批先完成 V3 版本化備份恢復及受保護啟動，再推進新排程和服務寫入，不因本批測試通過而結束 B03。
