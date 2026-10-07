# A02: Versioned Backup Vault and Capture

日期：2026-10-08（Asia/Hong_Kong）。基線：`97bbcb4`；工作分支：`codex/supplemental-development`。

## 範圍

本批打通 V1/V2 共用備份清單、生成、導出與后台一致性捕獲。沒有啟用 V2 正式遷移、沒有操作使用者詞庫，沒有執行 live DeepSeek、性能重測或 app 分發。README、產品截圖與全倉敏感資訊審核仍留在 C06。

`WordNoteVersionedPayload` 明確保留版本，不把 V2 的 content 子集當作完整五實體快照。兩版 codec、checksum envelope 和 on-disk counts 不變；目錄摘要的 `WordNoteBackupCounts` 則包含全部八類數量。Settings 對非 V1 備份顯示 schema 標記，但現行 V1 coordinator 的恢復預覽仍拒絕 V2，不提供尚未接通的切庫能力。

## 行為與限制

- vault 可混合列出、生成、導出和明確刪除兩版；按 ID 導出對同一次讀取 bytes 完成驗證，再原樣寫出。
- 自動變更檢测包括 V2 關係、元資料和偏好；滿 24 小時或時鐘回退時才按既有規則判定。首次空庫不備份，已有資料刪至空庫仍可備份。
- 兩版共用最近七份自動備份限額；手動、beforeMigration、beforeRestore 不自動刪除。catalog 損壞可重建；寫入或清理失敗保留既有有效快照。
- 不認識的 schema、損壞文件和偽造文件名/內嵌 ID 不列為有效快照、不參與輪替刪除；無效導出不得覆寫目的文件。
- V2 捕獲復用后台獨立 context 與同步 save counter，一次讀取全部八實體；並發保存則整次重試，最多三次。取消後即使 reader 忽略取消也不能返回成功結果。
- V1 保留先保存已有修改的既有行為；V2 的直接未保存模型編輯則明確拒絕，不繞過 service revision、不保存也不丟棄草稿。
- 舊 V1 `readSnapshot`/`capture` 仍只接受 V1；版本化方法顯式接受 V1/V2。現行 App 恢復日誌、V2 啟動遷移及多課程 CSV 接入尚未完成。

## 回歸證據

新增 22 項：版本化 vault 11、版本化捕獲 10、V1 App coordinator 拒絕 V2 恢復 1。

| 類別 | 證據 |
|---|---|
| 序列化 | V2 全字段/全部關係往返相等；V1 經新版入口編碼與原 codec bytes 完全一致 |
| 目錄及導出 | 兩版 schema/計數、源文件 bytes 保留、0600 文件/0700 目錄、顯式刪除不改導出副本 |
| 排程及輪替 | 只改來源/關係/revision 仍檢出；空庫/刪空/跨 schema；7 份自動與全部保護快照 |
| 文件故障 | 損壞 catalog、寫入/清理注入失敗、未知 schema、錯誤數量、冒名 ID；原有效備份保留 |
| 並發 | 保存中整次重試、持續變動三次截止、取消、錯版本 reader、未保存編輯在讀取前/中出現 |
| 恢復邊界 | V1 coordinator 可列出 V2 但拒絕恢復預覽；原庫完整值不變，無 pending 日誌或寫入屏障 |

```bash
RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test -c release \
  --filter 'WordNoteVersioned|WordNoteSnapshotCaptureTests|WordNoteBackupVaultTests|WordNoteDataProtectionTests|WordNoteRestoreStoreTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

swift build -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

| 檢查 | 結果 |
|---|---|
| 定向 Debug 回歸 | 55 項全通過，0 失敗；測試耗時 1.967 秒 |
| 嚴格離線全套 | 292 項，290 通過、2 跳過、0 失敗；測試耗時 3.718 秒 |
| 跳過项 | live DeepSeek 與 opt-in 大庫性能；本批不改 AI 協議，未重複付費請求 |
| Release 定向回歸 | 72 項全通過，0 失敗；測試耗時 2.306 秒 |
| 嚴格 App 建置 | 通過；完整並發檢查及 warnings-as-errors 開啟 |
| 文檔鏈接、差異檢查 | 6 份文檔共 58 個相對鏈接有效；git diff --check 通過 |

所有測試使用人工樣本及臨時/記憶體容器，不讀使用者實際詞庫。先前 V1 性能測量不冒充 V2 性能結果。

## 未完成閘門

本批未再次操作 Computer Use；最近一次實機嘗試仍是 [前批記錄](2026-10-08-a02-integrity.md) 的 Mac 鎖屏回應。新增 schema 標記沒有視覺驗收，不把建置成功當 UI 通過。

A02 需繼續接入共用版本化 restore journal/staging/bootstrap、遷移保護與 App 讀寫服務，修復預覽還需正式確認/保護流程。正式 App 仍在 V1，QA-06/QA-07 未完成，也未合併主分支。

後續 [版本化恢復記錄](2026-10-08-a02-versioned-restore.md) 已补齊共用日誌、staging 與核心 bootstrap；App 接入及正式遷移閘門仍未完成。本頁保留該批備份驗證的數字與範圍。
