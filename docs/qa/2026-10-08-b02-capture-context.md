# B02 共享捕獲上下文

日期：2026-10-08（Asia/Hong_Kong）。基線：`c6c927b`，分支：`codex/supplemental-development`。對應 QA-16/QA-17 的共享上下文子範圍，不代表整個 B02 完成。

## 範圍

- 僅 `WORDNOTE_V2_VALIDATION` runtime 注入共享控制器；正式 V1 的課程/來源和提交行為保持原樣。
- 主 Quick Add、所有主窗口、浮窗、Settings 使用同一份 current/default context，course 使用穩定 UUID，source 使用既有枚舉，intent 為 Automatic/English to Chinese/Chinese to English。
- 每個字段獨立記錄是否手動覆寫；明確 No Course 不跟隨後來的預設課程。重置圖標恢復全部預設並重新跟隨。current 不持久化，restart 從 defaults 初始化。
- request 固定原文、note、courseID、sourceType、intent、surface 及獨立 captureID；隊列與重試沿用 A02 持久化元資料。解析規則由 LookupIntent 集中提供，畫面提示與服務相同。
- 課程刪除時清空失效引用並提示，保存前才發現 current 課程失效則拒絕該次保存，保留輸入供檢查後重試，不換綁其他課程。
- 浮窗以圖標 popover 修改上下文，收合仍為 360x60 pt。新增可關閉、隨內容限高的保存錯誤區；成功後才清空輸入。

## 持久化邊界

預設來源仍使用 `defaultSourceType`，因此啟動時尊重既有 snapshot 恢復後的來源值；course/intent 使用帶 version 的 `captureContextDefaults.v1`。未知版本、未知枚舉、損壞 JSON 或錯誤類型只顯示警告和安全回退，不在啟動時覆寫，明確更新 Settings 才替換。

新增 defaultCourse/intent 目前僅本機保存，不隨 V1/V2 邏輯備份。已提交記錄的捕獲元資料已完整入快照，兩者不能混稱。B08 已增加版本化偏好 adapter、舊快照預設、course 引用校驗與往返測試門檻；沒有修改凍結 V1/V2 文件格式，也未宣稱最終備份範圍縮減。

## 代碼與自動化

| 文件 | 責任 |
|---|---|
| [CaptureContextController](../../Sources/WordNoteCore/Domain/Services/CaptureContextController.swift) | 值選擇、預設/覆寫、偏好讀寫、失效課程回退和 request 固定 |
| [CaptureMetadata](../../Sources/WordNoteCore/Domain/CaptureMetadata.swift) | 同一 LookupIntent 方向解析入口 |
| [CaptureContextFields](../../Sources/WordNote/Presentation/CaptureContextFields.swift) | 復用選單、重置、警告、課程 Query 及保存前 ID 檢查 |
| [V2ValidationRuntime](../../Sources/WordNote/App/V2ValidationRuntime.swift) | 唯一控制器生命周期與各窗口注入 |
| [QuickAddView](../../Sources/WordNote/Presentation/QuickAddView.swift) / [FloatingQuickAddPanel](../../Sources/WordNote/Presentation/FloatingQuickAddPanel.swift) | 主窗/草稿/浮窗提交都使用固定 request，浮窗可見錯誤 |
| [CaptureContextControllerTests](../../Tests/WordNoteCoreTests/CaptureContextControllerTests.swift) | 新增 17 項控制器測試 |
| [CaptureContextIntegrationTests](../../Tests/WordNoteCoreTests/CaptureContextIntegrationTests.swift) | 新增 6 項 queue/content/備份/磁盤重開整合測試 |

23 項新增測試全部使用獨立 UserDefaults suite 和內存/臨時合成詞庫。包括同值也算手動選擇、明確 No Course、defaults 只更新未覆寫字段、清除失效預設並跨啟動保持、保存競態拒絕一次、損壞偏好不覆寫、原有來源恢復、兩個入口不等待分析、保存草稿延後分析方向不漂移、local exact hit 不發 AI、失敗保存回滾、snapshot 往返和實際 SQLite 重開後顯式恢復分析。

| 驗證 | 結果 |
|---|---|
| V2 嚴格定向（新增上下文 + 既有 capture/analysis/restart） | 54 項全部通過 |
| 普通 V1 嚴格 Debug 全套 | 671 項，666 通過、5 跳過、0 失敗 |
| V2 QA 嚴格 Debug 全套 | 671 項，666 通過、5 跳過、0 失敗 |
| V2 QA 嚴格 Release 全套 | 671 項，666 通過、5 跳過、0 失敗 |

默認跳過仍是兩組 live DeepSeek、兩組性能和一組 native hotkey。這批不改 AI provider/prompt，沒有新增付費呼叫；用注入 handler 檢查實際送入分析服務的方向、課程和來源。本機工具鏈與第一批相同，macOS 14 最低系統未實測。

四份測試日誌均沒有 warning/error，保持 complete concurrency、warn-concurrency 和 warnings-as-errors。日誌位於本機 `/tmp/wordnote-b02-context-{focused,v1-debug,v2-debug,v2-release}.log`。七份變更文檔的 140 個相對文件鏈接有效，`git diff --check` 通過。

```bash
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors \
  --filter 'CaptureContext|WordNoteV2CaptureTests|WordNoteV2AnalysisTests|WordNoteV2AnalysisRestartTests'
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
./script/build_and_run.sh --ui-v2-fixture populated light
```

## Computer Use 核對

隔離 session：`6682566E-3912-4A85-B4A2-95EA9B0243C0`，bundle：`com.powerpan.WordNote.UITest`。未讀寫真實詞庫。取得主 Quick Add 和收合浮窗實際截圖，沒有作 README 介紹素材。

1. 主窗口顯示 Course/Source/Direction 菜單、跟隨預設狀態、重置按鈕；控件可讀，沒有互相遮擋。
2. 在主窗口選合成課程 Computer Science、Paper 和 Chinese to English。Command-Shift-N 打開浮窗；上下文 popover 的 AX 值與三個選擇完全一致。
3. 在浮窗將來源改成 Book，關閉 popover，輸入 `precision` 並 Return；輸入清空。再次 Command-Shift-N 隱藏浮窗，主窗口顯示 Computer Science / Book / Chinese to English 與 Saved to the analysis queue。
4. 未觀察到此筆的分析完成或釋義，不把「已入隊」當成分析成功。這個 QA 庫沿用啟動遷移後分析需顯式恢復的保護。
5. 點擊 Settings 後讀 AX/截圖返回 `Sky Computer Use native pipe closed before response`；重置 REPL 再連一次仍相同。沒有使用 AppleScript 或其他 UI 通道繞過，也不推斷 Settings 已成功顯示。QA 進程仍存在，這只能證明進程未退出，不能證明界面響應正常。

本批沒有取得 Settings 預設變更、保存失敗錯誤區、刪課程、不同主題/尺寸、實際中文 IME 或另一 App 前台全局鍵的實機結果。這些由自動化覆蓋的部分與未完成 UI 驗收分開記錄。已結束本輪 QA 進程以釋放全局註冊。

## 後續門檻

- B02 剩餘：最小排隊/失敗提示與按需任務、英文複製、朗讀/停止/無聲音、跳轉正確記錄；可見上下文收結果、10 秒失焦時計、隱藏重開不重播，以及最終 UI 清單。
- B08：將新增預設納入版本化非機密偏好白名單，完成舊快照升級與跨重啟恢復，不能永久留成未備份設定。
- C06：代码與測試收尾後再做 README、界面介紹截圖、最終內容和可達 Git 歷史敏感資訊檢查。這批未執行上述交付工作，未做 App 分發或合併 main。
