# A02: Protected Startup Migration

日期：2026-10-08（Asia/Hong_Kong）。基線：`eac289e`；工作分支：`codex/supplemental-development`。

## 範圍

`WordNoteV2StartupCoordinator` 串接版本化 vault、原有 V1 -> V2 轉換及共用 restore journal，沒有另建切庫機制。只使用臨時 SQLite、合成資料和凍結 V1 fixture 的副本；正式 App 仍是 V1，沒有啟用個人詞庫遷移。

它必須在 UI、表單、分析 worker 及其他寫入者建立前運行。低層 store.open 仍不自動遷移；只有顯式 V2 啟動協調器可執行以下流程：

1. 開啟現有世代，已有 V2 先做完整捕獲校驗；遇恢復標記的 V1 要求明確重試。
2. 阻擋所有原容器的服務寫入、停用 autosave；拒絕待保存修改，不幫使用者保存或丟棄。
3. 先寫 version 2 日誌的 migration 意圖及分析暫停，再捕獲、建立 beforeMigration 快照並從 vault 重讀，比較整份 payload。
4. staging 前後再次比較源資料；使用同一 journal 的 pending.operation=migration 和既有后台建庫/重開驗證。
5. 核對本次 pending generation，啟用新庫後才返回 ready。原庫不覆寫，原 context 即使被保留仍受寫入屏障限制。

日誌 recoveryRequired 在備份/建庫失敗、取消或 activating 中斷後保留，避免每次重啟重跑遷移；retryMigration 必須明確指定。若最初寫意圖就失敗，不能保證失敗標記已持久化。取消只針對本次已準備的 generation，不撤銷另一個贏得競爭的操作。遷移未完成不能解除分析暫停；已存在 V2 的 restore 回退可明確恢復原庫分析。

舊 version 1 日誌和既有 API 保持兼容；version 2 新增可選 transition/recovery 字段，舊版 version 2 缺 operation 按 restore 解讀。取消或回退不把日誌降成 version 1；舊 V1 程式仍應拒絕它，而不是忽略保護狀態。

## 回歸證據

新增 18 項啟動遷移測試及 1 項嚴格 V1 捕獲測試；既有版本化恢復測試補上跨啟動恢復標記及明確恢復分析的斷言。

| 類別 | 覆蓋 |
|---|---|
| 完整遷移 | 凍結 V1 真實 fixture 副本、空庫；完整值/關係一致，fixture bytes 不變、原庫內容保留，再開不重複備份/回填 |
| 保護快照 | ENOSPC、目錄寫入失敗、快照寫後被替換；無已驗證相同來源的 beforeMigration 不得 staging |
| 共用切庫 | staging/activate/commit 故障、prepared 跨啟動完成、activating 中斷回退、後續不自動重試 |
| 並發取消 | reentrant 拒絕、后台取消、所有源 context 受屏障限制、不能覆寫或撤銷競爭 restore |
| 來源新鮮度 | 已保存修改令方案過期；未保存修改不被捕獲順帶提交或回滾；精確 pending token 校驗 |
| 損壞資料 | V1 缺必要關聯、V2 非法引用、意圖寫後原檔消失均保留證據且不回傳 ready，不建空庫代替 |
| 遷移語義 | 舊中文主體和無法確定的 saved link 提示保留，不偽造修復；不變更歷史計數/事件、不調 AI |
| 恢復分析 | 遷移未完成拒絕 resume；已有 V2 restore 回退保持暫停，明確恢復後清除標記 |

```bash
RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

RUN_LIVE_DEEPSEEK_TESTS=0 RUN_BACKUP_PERFORMANCE_TESTS=0 swift test -c release \
  --filter 'WordNoteV2StartupCoordinatorTests|WordNoteVersioned|WordNoteRestoreStoreTests|WordNoteDataProtectionTests|WordNoteSnapshotCaptureTests|WordNoteBackupVaultTests' \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors

swift build --product WordNote -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

| 檢查 | 結果 |
|---|---|
| 嚴格離線全套 | 330 項，328 通過、2 跳過、0 失敗；測試耗時 4.915 秒 |
| 跳過項 | live DeepSeek、opt-in 大庫性能；本批不改網絡協議，沒有新增外部請求 |
| Release 定向回歸 | 110 項通過、0 失敗；測試耗時 3.390 秒 |
| 嚴格 App 建置 | 通過；完整並發檢查及 warnings-as-errors 開啟 |
| 文檔鏈接與差異 | 7 份文檔共 74 個相對鏈接有效；git diff --check 通過 |

故障由 checkpoint/日誌重放注入，不冒充真實斷電或磁碟耗盡。未重新測量 V2 大庫性能，未在最低 macOS 14 實機驗收。

## 實機與剩餘範圍

此次 Computer Use 以 QA bundle ID 能讀取 Word Note QA 主窗口可訪問性樹，內容是隔離樣本；截圖返回不可驗收的小型背景縮圖，Raise 未改善，點擊 Settings 後回報 `Sky Computer Use native pipe closed before response`。正式 Word Note 不在當次應用清單。沒有因此標記 UI 通過，也沒有推斷目前鎖屏；現有 QA binary 不是本批新啟動協調器的端到端測試。

A02 尚需受保護的完整性修復套用、V2 App 讀寫/queue/Settings 接入；A01/G00/A03 實機閘門保留。此協調器不自行清理無法正常備份的壞庫，不以純核心測試代替 UI 和原生窗口驗收。不合併 main、不分發；README、產品介紹截圖與全倉敏感資訊審核仍在 C06 後置執行。

後續：[受保護啟動修復](2026-10-08-a02-startup-repair.md) 已補原始證據文件、修復 preview/confirm 及共用切庫。上述測試數字是此遷移批次的歷史結果，正式 App 接入仍待完成。
