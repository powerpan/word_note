# A02: Shared Versioned Restore Journal

日期：2026-10-08（Asia/Hong_Kong）。基線：`f99b01b`；工作分支：`codex/supplemental-development`。

## 範圍與取捨

延續既有 WordNoteRestoreStore，加入顯式 `targetSchema: .v2`；沒有另建一套與 A01 競爭的切庫選擇器。默認仍是 V1，正式 App 的啟動、類型別名和 coordinator 未切換。測試僅使用合成資料和臨時 SQLite，不操作實際詞庫。

版本 1 日誌仍寫五類 counts，既有 prepared 恢復可由 V2-capable bootstrap 打開為 V1。沒有 pending 的 V1 庫也只返回 V1 session，不因呼叫方支援 V2 就原地升級。新的 session 明確攜帶 schemaVersion，後續 App 遷移協調器必須在掛接 V2 UI 前處理這個狀態。

首次準備 V2 恢復時，日誌升至 version 2，active/previous/pending 記錄 schema，pending 記錄全部八類 counts。舊 V1 模式看到 version 2 直接拒絕，既不寫日誌也不打開 staged 庫。取消或故障回退後保留 version 2，不自動降版；這會要求使用支援該日誌的版本繼續，而不是讓舊程式忽略新版欄位。

## 恢復行為

- V2 模式接受 V1/V2 快照；V1 在后台先走既有確定性值轉換，再寫空 V2 store。不把 V2 當作 V1 子集恢復，也不降級現有 V2。
- 沿用唯一 private Stores generation 目錄；后台建庫後重新打開，比較全部 DTO/偏好並算完整 checksum。準備成功只寫 pending，原庫不覆寫。
- 下一次 open 標記 activating，再按 pending schema 開庫、驗證八類數量和 checksum，最後原子提交 active。僅改來源或其他 V2 關係也會被檢出。
- activating 中斷或啟動校驗/提交失敗，按日誌中的原 active schema 回退，保留原庫及保護快照，不自動重試不確定的新庫。
- 保護快照需為 beforeRestore，且 schema 與當前 active 庫相符。呼叫方仍必須持有全窗口寫入屏障、剛驗證當前庫保護快照；低層不取代 App coordinator 的新鮮度/表單/網絡回調防護。
- 后台返回時重讀日誌；已取消、不再是當前 generation 或已有另一 prepared 操作時，不提交過期結果。
- V2 queued/running/failed 工作標記為需顯式恢復；偏好和暫停狀態跨重啟保留。底層不調 AI；V2 App worker 的端到端接入仍待後續。

## 測試

新增 `WordNoteVersionedRestoreStoreTests` 19 項，原 V1 恢復 17 項繼續保留。共用原有阻塞 checkpoint 測試輔助，未等待業務計時器或真實網絡請求。

| 類別 | 證據 |
|---|---|
| 舊版兼容 | V1 無日誌啟動不遷移；V1 prepared 日誌仍五類 counts，可由新版打開；原 V1 全字段不变 |
| 完整恢復 | 八實體及新增來源元資料往返，V1 snapshot 升級後歷史 ID/ReviewEvent 保留；第二次恢復不降級 V2 |
| 舊入口防護 | V1 prepare 拒絕 V2；open、cancel、pause、resume、偏好確認在 version 2 日誌前停止，文件 bytes 不變 |
| 故障回退 | staging/prepare ENOSPC；activate/commit 失敗回 V1；activating 中斷回既有 V2；原 generation 保留 |
| 全量校驗 | 只改 occurrence.note 的 checksum 不符、新實體 counts 不符、缺 staged store、符號鏈接均拒絕新庫 |
| 日誌邊界 | 缺/未知 schema、legacy 偽標 V2、缺新 counts、負數、偽造降版 header/pending 均拒絕且不重寫 |
| 並發取消 | staging 不在 MainActor；取消不產生 pending；晚返回者不能覆蓋別人的 prepared 或已激活 generation |
| 分析暫停 | queued/running/failed 檢出，none/cancelled 不當活動工作；暫停及偏好需明確確認，跨重啟保留 |

```bash
RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test -c release \
  --filter 'WordNoteVersioned|WordNoteRestoreStoreTests|WordNoteDataProtectionTests|WordNoteSnapshotCaptureTests|WordNoteBackupVaultTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

swift build -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

| 最終檢查 | 結果 |
|---|---|
| 嚴格離線全套 | 311 項，309 通過、2 跳過、0 失敗；測試耗時 4.451 秒 |
| 跳過項 | live DeepSeek、opt-in 大庫性能；本批不改模型協議，無新外部請求 |
| Release 定向回歸 | 91 項全通過，0 失敗；測試耗時 3.032 秒 |
| 嚴格 App 建置 | 通過；完整並發檢查及 warnings-as-errors 開啟 |
| 文檔鏈接及差異檢查 | 7 份文檔共 70 個相對鏈接有效；git diff --check 通過 |

故障為注入/日誌重放，不冒充真實斷電、磁碟耗盡或強殺 App 驗證。最低 macOS 14 target 不代表已在 macOS 14 實機測試；沒有把 V1 大庫性能數字套用為 V2 結果。

## 剩餘工作

A02 仍需遷移前保護與启动協調、修復方案確認/套用，以及 V2 App 讀寫、queue 和 Settings 恢復預覽接入。舊 App coordinator 對 V2 仍拒絕，不能因核心 `targetSchema: .v2` 測試通過就把正式 App 切過去。

本批沒有再次啟動或操作 App，最近一次 Computer Use 鎖屏回應見 [完整性批次](2026-10-08-a02-integrity.md)。實機、A01 整體恢復流程及 QA-06/QA-07 仍未標完成。不合併 main、不分發 App；README、產品截圖和全倉敏感資訊審核仍按 C06 在代碼/測試完成後執行。

後續：[受保護啟動遷移](2026-10-08-a02-startup-migration.md) 已補隔離協調器、beforeMigration 重讀驗證及持久恢復標記；正式 App 接入仍未完成。以上數字及工具狀態保留為本批歷史證據。
