# B06 第一批：題型內容與明確建卡

日期：2026-10-08（Asia/Hong_Kong）。基線：`3a273b05cc591088c9cfc3a70cf7c2a6ebd296b4`，分支：`codex/supplemental-development`。承接 [B05 控制與統計](2026-10-08-b05-controls-statistics.md)，補 QA-25/26 的核心證據；不是正式 V3 runtime、原生輸入或 UI 完成聲明。

環境：arm64、macOS 27.0.1（26A434）、Apple Swift 6.4；套件保持 macOS 14 deployment target / Swift 5 language mode。這是在較新主機執行測試，不代表已在最低系統實機通過。

## 實作

- [題目內容](../../Sources/WordNoteCore/Domain/ReviewQuestionContent.swift) 明確區分正面/背面；正面只有身份、模式、提示，不傳例句/完整答案。中文正面遮蔽英文詞頭，無有效中文不能啟用回憶。英文識別須有可揭示釋義；填空須有可用原文。拼寫只比較 canonical Unicode、大小寫和空白，保留原始輸入；未知同義表達需自評，不生成事件。
- [正式內容入口](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewQuestions.swift) 檢查租約和完整已揭示快照後返回背面；釋放、內容變動和未揭示時拒絕。選組、正式呈現前、統計工作量共用題面資格，無法顯示的題不扣新卡額度或推進游標。停用卡另計，不誤報為缺答案。
- [文字匹配](../../Sources/WordNoteCore/Domain/ReviewTextMasking.swift) 使用 Foundation/ICU escaped literal、詞邊界、常見連字符/撇號形式；引號與詞內撇號區分。一次建立 UTF-16/Character 邊界表，拒絕半個 grapheme，所有重疊範圍合併、同一詞多次出現全部遮蔽，固定四底線不透露答案長度。最多 1,000 個命中，超限停止並拒絕，不只遮住前一千個。
- [填空預覽](../../Sources/WordNoteCore/Domain/ReviewClozeBuilder.swift) 不推斷屈折，使用者明確選完整詞形；主答案與確認的其他形式共同遮蔽。單獨詞頭/沒有剩餘英文上下文/中文來源拒絕，原始 UTF-8 hash 變動即失效，canonical 等價改寫也不冒充未修改原文。
- [填空交易](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ClozeCards.swift) 只接受存在的原 InputRecord、凍結英查中方向、與 occurrence 完全相同的原 bytes。預覽只讀，確認比對完整 Term/TermState/來源/記錄元資料再重建預覽；同 ID 重送只讀返回，相同來源範圍不同 ID 拒絕重複建卡。失敗全回滾。
- 修改來源保留原 InputRecord；清空目標答案/hash/位置、設 sourceChangedAt、停卡並把依賴會話項改 unavailable，不寫評分。刪 InputRecord 不刪仍有效的 occurrence/卡，但不能再新建無證據提案；刪 occurrence 則轉成互斥的 sourceDeletedAt。人工修改 snapshot 不直接獲得新原始捕獲身份。
- [方向啟用](../../Sources/WordNoteCore/Domain/Services/V3/WordNoteV3ReviewDirections.swift) 明確 opt-in，new 方向不複製 sibling 能力/引入史。重新啟用既有卡保留自身能力/桶；舊會話項不復活。揭示交易保存詞級 reviewExposedUntil，即使刪掉最後一張卡，新建方向仍受當天保護；更晚 burial 不縮短。本地命中在無卡時重建主卡也繼承曝光，不因 priority 提前展示。舊無曝光資料採現存當日已呈現項/事件作保守依據，不補造已刪且無記錄歷史。
- 普通備份及修復證據新寫 format=4，保護 sourceChangedAt 和 reviewExposedUntil；舊 format=1/2/3 在無新字段時可讀，降標拒絕。V1/V2 模型/codec 凍結，未發布 V3 原型 SQLite 跨模型直開不在承諾內。

## 測試

| 新增測試 | 項數 | 主要覆蓋 |
|---|---:|---|
| [ReviewTextMaskingTests](../../Tests/WordNoteCoreTests/ReviewTextMaskingTests.swift) | 14 | 詞邊界、C++/C#、regex metacharacter、連字符/撇號/引號、emoji/组合字、中文內英文、重疊/極端範圍、上限、900 次 Unicode 命中、屈折明選、多次遮蔽、詞頭/中文拒絕、raw hash、非自動判錯 |
| [WordNoteV3ClozeCardTests](../../Tests/WordNoteCoreTests/WordNoteV3ClozeCardTests.swift) | 12 | 只讀預覽、獨立新卡、重送/重複目標、全部草稿依賴、原文證據、中文拒絕、保存/源改動回滾、會話失效、無變化、兩種刪除、tombstone 約束、磁盤恢复、format=4 |
| [WordNoteV3ReviewDirectionTests](../../Tests/WordNoteCoreTests/WordNoteV3ReviewDirectionTests.swift) | 13 | 明確新卡、revision/模式/時區、無中文拒絕、呈現/揭示後新增方向及填空、未呈現例外、刪卡重開曝光保留、本地命中重建、倒退/較晚埋藏、停用再啟用/legacy、失敗回滾、曝光獨立格式保護 |
| [WordNoteV3QuestionContentTests](../../Tests/WordNoteCoreTests/WordNoteV3QuestionContentTests.swift) | 6 | 正面無答案/例句欄位、英文詞頭遮蔽、租約/揭示/源變動、讀取不造事件、來源與例句分離、無效題不扣額度、選題/統計同口徑 |

45 項新增測試均使用合成資料和临時 SwiftData 容器，沒有讀取或修改真實詞庫。保存/恢復實際經過 codec、staging、磁盤重開；保存故障以 beforeSave 注入，不冒充真實斷電。900 次匹配驗證結果正確，不是大庫性能基準。

先用兩項回歸測試復現引號內答案未遮蔽，以及刪除已揭示卡後新方向 burial 為 nil，再修正。初輪另有三個測試 helper 在預期拋錯外層使用 XCTUnwrap 而自報失敗，已拆開取得結果和 unwrap；沒有藉此放寬產品驗證。

| 最終驗證 | 結果 |
|---|---|
| 普通 V1 完整嚴格 Debug | 1050 項，1045 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Debug | 1050 項，1045 通過、5 跳過、0 失敗 |
| V2 QA 完整嚴格 Release | 1050 項，1045 通過、5 跳過、0 失敗 |

三套均為 Core 1005 項（4 跳過）+ App 45 項（1 跳過），無編譯 warning/error。跳過的是兩個付費 DeepSeek 組、兩個 opt-in 性能組及一個原生快捷鍵組，不算本批通過證據。最終完整回歸包含最後加入的長原文映射與本地命中重建卡曝光保護。`git diff --check` 通過，8 份修改文檔的 224 個本地鏈接目標存在。

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test -c release --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

本機日誌：`/tmp/wordnote-b06-regression-before.log`、`/tmp/wordnote-b06-content-expanded.log`、`/tmp/wordnote-b06-v1-debug.log`、`/tmp/wordnote-b06-v2-debug.log`、`/tmp/wordnote-b06-v2-release.log`。本批沒有更改 AI provider/prompt/worker，沒有再次付費請求；最近授權的雙向 live 冒煙證據保留在 [B05](2026-10-08-b05-controls-statistics.md)，不充當 V3 分析鏈路驗收。

## 未完成範圍

1. 這是隔離 V3 內容/交易核心，普通 App V1 和 QA App V2 未切換 schema；UI 不能把這些服務附在 V1/V2 store 上使用。
2. 原生文字輸入、IME/空格與數字快捷鍵屏蔽、建卡預覽面板、練習 UI、跨窗口/離頁生命周期尚未接入。沒有以 Computer Use 或最低 macOS 14 實機驗收本批。
3. 下一步優先完成 V3 內容/分析/確認/編輯交易及唯一 queue/runtime，再整合 B04 至 B06 的可操作流程；不以繼續堆疊孤立測試代替產品交付。整庫完整校驗與大來源的真實 UI 延遲仍需性能測量。
4. 無原記錄的 legacy/orphan 來源、人工修改且不等於原捕獲的 snapshot 暫不提供新填空。這是保守限制，不自動請求 AI 補原文。
5. README 更新/界面介紹截圖，以及最終工作樹、暫存區和可達歷史敏感資訊檢查，仍留在代碼完成後的 C06；未分發、未合併 main。
