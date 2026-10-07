# A04 未保存編輯保護

日期：2026-10-08（Asia/Hong_Kong）。基線：`931f767`，分支：`codex/supplemental-development`。本批是 A04 子里程碑，不能代表完整 A04 或 QA-02/QA-09 驗收通過。

## 範圍

- V2 QA 主窗口的 Term、Course、候選及 Inbox 手動建詞採用獨立值草稿，不直接改 SwiftData。
- 列表切換、跨欄目、詞庫搜索/篩選、課程新增、Inbox 確認/忽略/重試/刪除之前，先處理未保存修改。
- 保存、放棄、取消由每個窗口的保護器協調。待處理動作不能被後續點擊替換，保存失敗不導航、不清空草稿。
- 正常關窗等待確認 sheet 關閉。正常退出逐個處理有修改的窗口；任一取消或失敗均阻止退出，新開窗口也納入檢查。
- 普通 V1 啟動、真實詞庫、既有恢復流程及分析付費規則不變。沒有修改 README、拍攝介紹截圖、執行全倉機密審計或處理分發。

## 實作

| 組件 | 行為 |
|---|---|
| [WordNoteEditDraft / WordNoteEditProtection](../../Sources/WordNoteCore/Domain/Services/WordNoteEditProtection.swift) | 穩定引用持有值型內容、基線與 revision；決策直接讀當前內容，不依賴 SwiftUI onChange 已執行；保留最後一次输入 |
| [QuitProtection](../../Sources/WordNoteCore/Domain/Services/WordNoteQuitProtection.swift) | 可測的多窗口退出序列，不覆蓋已有導航提示；保存失敗仍可取消；已保存的窗口不被後續取消回滾 |
| [SwiftUI 保護器](../../Sources/WordNote/Presentation/EditProtection.swift) | 可查看/複製草稿文字的三選項 sheet，失敗保留原目的地；沒有未保存修改則直接完成動作 |
| [原生窗口橋接](../../Sources/WordNote/App/EditProtectionWindowBridge.swift) | 窄 NSWindowDelegate 代理，保留原 delegate 的其他消息；取消時嘗試還原輸入控件與文字選區；弱窗口登記，不接管其他 App |
| [候選草稿組](../../Sources/WordNote/Presentation/V2CandidateDraftEditor.swift) | 同一來源的所有修改候選一起保存，不能保存一個後把其他本地修改誤當成外部衝突；手動建詞與候選編輯不並行開放 |
| [候選編輯交易](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2Editing.swift) | 全批檢查 candidate/source revision、狀態與世代，來源版本最後統一更新；同一 record 只加一次 revision，任何錯誤全部回滾 |

若其他窗口刪除正在編輯的實體，髒草稿不因視圖移除而清空。窗口的 Unsaved Changes 入口仍可查看文字；保存按原 ID 重查，缺失則拒絕，不重新建立已刪內容。這不是跨重啟草稿恢復，也不是字段合併功能。

## 自動化

新增 23 項測試：

- [窗口草稿狀態機](../../Tests/WordNoteCoreTests/WordNoteEditProtectionTests.swift)：13 項，含即時讀取最後按鍵、取消、保存失敗、部分保存失敗、重複請求、脫離視圖後保留/釋放、保存回調未清除草稿時拒絕導航。
- [多窗口退出](../../Tests/WordNoteCoreTests/WordNoteQuitProtectionTests.swift)：6 項，含每個窗口逐一確認、第二次退出、已有導航、新窗口、第二窗口取消、保存失敗。
- [V2 編輯](../../Tests/WordNoteCoreTests/WordNoteV2EditingTests.swift)：新增 4 項，含同來源只更新一次版本、重複 ID、後項校驗失敗、保存失敗及外部來源版本改變。原 12 項繼續通過。

| 驗證 | 結果 |
|---|---|
| 普通 App 嚴格 Debug + 完整離線測試 | 438 項，435 通過、3 跳過、0 失敗，約 6.74 秒 |
| V2 QA 嚴格 Debug + 完整離線測試 | 438 項，435 通過、3 跳過、0 失敗，約 6.92 秒 |
| V2 QA 嚴格 Release + 完整離線測試 | 438 項，435 通過、3 跳過、0 失敗，約 6.60 秒 |
| 最後定向回歸 | 35 項通過，0 失敗，約 0.19 秒 |
| 編譯診斷 | 最終三組日志無 warning/error；開發中原生 delegate 非隔離轉發、SwiftData import 與測試弱引用警告均已修正後重跑 |
| 隔離啟動 | `--ui-v2-fixture populated light` 完成；僅使用臨時合成 session，不開真實詞庫 |
| Computer Use | `getApp("com.powerpan.WordNote.UITest")` 返回 `-10005 cgWindowNotFound`；沒有本批可用的 UI/截圖證據，不推測原因 |
| 文檔與差異 | 五份本批文檔的 87 個相對文件鏈接有效；`git diff --check` 通過 |

跳過項為兩組顯式 opt-in DeepSeek live 與 Release 性能組。本批不改 AI 請求協議，未重複付費調用；上一批合成雙向 live 證據見 [A02 App 接入](2026-10-08-a02-app-integration.md)。所有測試只使用內存/臨時 fixture。

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
./script/build_and_run.sh --ui-v2-fixture populated light
```

## 尚未完成

1. A04 運行期最近一次編輯/確認的安全撤銷：仍需 before/after receipt、revision 與後續依賴校驗。
2. 衝突目前保留草稿並提示，不提供逐字段差異/合併；詳情預設閱讀等 A06 內容尚未實作。
3. 真實 UI 的關窗、Command-Q、多窗口、列表/搜索焦點與輸入法組字驗收仍未通過。自動化狀態機不能替代 AppKit/SwiftUI 現場交互證據。
4. 只有隔離 V2 QA 注入窗口保護；普通 App 沒有提前切到 V2。強制終止、系統崩潰不保證未保存草稿恢復。

回退仍可使用未改動的普通 V1 啟動；不要通過刪除/替換生產資料回退。下一批先補安全撤銷，再進 A05 確認方案。
