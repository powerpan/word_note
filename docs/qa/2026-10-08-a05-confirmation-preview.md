# A05 確認預覽與原子提交

日期：2026-10-08（Asia/Hong_Kong）。基線：`d7b67ed`，分支：`codex/supplemental-development`。涵蓋 QA-10、QA-11 的核心與隔離 V2 UI 入口，保留實機驗收缺口。

## 範圍

- Inbox Confirm Selected 和候選 Save Selected 共用同一個確認預覽；未保存編輯先由 A04 處理。普通 V1 啟動及真實用戶資料未切換。
- 沒有 schema、資料遷移格式或 AI 協議變更；沒有 API 請求，也未執行 C06 的 README、介紹截圖或全倉敏感資訊審計。
- 全部測試使用內存或臨時合成資料，沒有讀寫真實詞庫；不做分發、簽名或公證。

## 規則與實作

| 組件 | 行為 |
|---|---|
| [只讀方案與值](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2ConfirmationPlan.swift) | 凍結候選/來源/課程、同名目標及關係；方案和解析结果不暴露可變持久模型 |
| [解析與選擇](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2ConfirmationResolving.swift) | new/link/fill/ignore、明確衝突、英文主體與凍結方向要求、切換目標/忽略候選時清理舊選擇 |
| [讀取與預檢](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2ConfirmationPlanning.swift) | 精確重複選中拒絕；版本和完整值比較；同名詞集合變化、來源/課程/關係變化使預覽失效；無關詞條更新不阻塞 |
| [提交](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2ConfirmationCommit.swift) | 所有依賴/計數器預檢後才改模型，一次 save；失敗全 rollback；一來源/既有詞每批最多增一次 revision；共享 A04 undo history |
| [重試](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2ConfirmationReplay.swift) | 版本化 token 綁定 plan.operationID 和最終選擇；相同重送零寫入，更改選擇不可當作原操作；已刪目標不重建 |
| [預覽](../../Sources/WordNote/Presentation/V2ConfirmationPreview.swift) / [分組](../../Sources/WordNote/Presentation/V2ConfirmationGroupView.swift) | 記錄/候選計數、來源明細、納入/忽略、主候選/既有目標選擇、四字段 Stored/Selected 對比、取消與刷新 |

既有詞預設保留全部正式字段及復習歷史。顯式補充只改中文、英文、技術釋義或例句中的所選字段，不以空值抹除內容。目標改變清空舊覆蓋選擇；未選中的字段不做裁切或規範化重寫。

同批 normalizedTerm 相同且內容相同只建一個 Term；內容不同要求選主候選或忽略部分候選。主候選決定新詞正式內容及主要來源，不自動拼接不同含義；所有納入候選的獨立來源/課程仍保存。相同 capture 同詞不重複 occurrence。

計數：newTerms 是唯一新詞數，linkedCandidates 包括既有詞連結及同批新詞的其餘候選，supplementedTerms 與 links 重疊，ignoredCandidates 是提交後正式忽略。無衝突時 `newTerms + linkedCandidates + ignoredCandidates == candidates`；衝突候選另計 unresolvedCandidates，不能把來源數與候選數混用。

方案不是持久任務。Refresh 產生新 operationID 並清空選擇，保留原候選 ID 範圍；已處理或被刪的選中項要求重新選擇，不靜默部分提交。保存的 token 隨 V2 快照保留；測試在新容器恢復後用相同原方案驗證零寫入重送，並非宣稱 App 重啟會恢復預覽彈窗。

ignored 的 confirmationOperationID 按凍結 V2 約束仍為 nil。只有內容和預期單步 revision、來源終態完全相符才返回零寫入收斂；不宣稱它具有持久操作所有權。後續來源/候選修改或 undo 會阻止舊方案重放。這一限制避免為短期預覽擅自改 V2 schema。

## 自動化證據

- [方案測試](../../Tests/WordNoteCoreTests/WordNoteV2ConfirmationPlanTests.swift)：20 項，涵蓋唯讀、計數、同名合併、單/多來源與課程、不同內容、精確目標歧義、顯式字段保護、無效選擇、忽略連動、切換目標、中文查英文及 C++/L2。
- [交易測試](../../Tests/WordNoteCoreTests/WordNoteV2ConfirmationCommitTests.swift)：20 項，涵蓋一次保存、同方案重試、選擇變更、恢復後重送、ignore 終態、來源/目標/課程/關係過期、無關修改、混合操作保存故障、計數器上限、撤銷及 stale/dirty/gate/generation 保護、刷新不丟候選。

| 驗證 | 結果 |
|---|---|
| 普通 App 嚴格 Debug 全套 | 538 項，535 通過、3 跳過、0 失敗，約 7.99 秒 |
| V2 QA 嚴格 Debug 全套 | 538 項，535 通過、3 跳過、0 失敗，約 7.92 秒 |
| V2 QA 嚴格 Release 全套 | 538 項，535 通過、3 跳過、0 失敗，約 7.58 秒 |
| QA 啟動 | 最終重建成功，合成 session `2A3F20A2-E656-4D9D-B960-5EB2CD204ACF`；進程 PID 40975 在檢查時存在，不代表窗口可見或交互通過 |
| Computer Use | 一次 `getApp("com.powerpan.WordNote.UITest")` 返回 `-10005 cgWindowNotFound`；本輪不反復重試，不推測原因，UI 未驗收 |
| 文檔與編譯檢查 | 三組最終測試及 QA 啟動日志無 warning/error；六份文檔共 112 個相對文件鏈接有效，`git diff --check` 通過 |

首次定向測試發現測試夾具的兩份來源其實屬同一課程；修正為明確不同課程後通過，沒有改程式成重複 membership。首次 UI 編譯擋下不存在的 theme token 及缺少 SwiftData import，均按現有工程修正，未放寬嚴格編譯。最終補上切換既有目標清空覆蓋選擇的兩項回歸。

三個預期跳過項為兩組 opt-in live DeepSeek 與備份性能組；本批不改 AI 協議、不重複付費請求。沙箱中的首次 pgrep 無權讀進程列表，使用只讀授權檢查才確認進程存在；沒有以別的 UI 技術繞過 Computer Use，也沒有操作真實 App 資料。

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
./script/build_and_run.sh --ui-v2-fixture populated light
```

## 尚待驗收

1. 980x680、1320x800、1920x1080 的明暗主題、長釋義與長詞頭、鍵盤/VoiceOver、焦點和兩種確認入口。
2. 預覽期間另一窗口修改/忽略候選，重新刷新或關閉後重新選；Cancel 不保存；切換目標不沿用覆蓋決定。
3. A05 核心已整合 A04 撤銷，但真實多窗口 UI 尚未驗收；B01 相鄰焦點/篩選和 B08 窗口策略另外推進，大庫批量確認性能不在本批宣稱通過。

回退：不啟用 `WORDNOTE_V2_VALIDATION` 時仍走原 V1；本批没有生產切庫或需要反向遷移的資料。隔離 QA 資料使用本次 session，不與真實庫共用。
