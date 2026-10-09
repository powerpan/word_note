# 復習窗口交接與統計刷新

日期：2026-10-09。基線：`ac94995`。環境：macOS 27.0.1（26A434）、隔離 V3 `learning` fixture。對應 B05、B08 / QA-24、QA-27、QA-30。

## 實機發現

兩個主窗口同時開著 Review。第二窗口揭示後，透過 Window 菜單回到第一窗口，需重新繼續和揭示，回答權保護正常。第一窗口把 `overfitting` 評為 Good，進度由 1/20 變成 2/20；再切回第二窗口，其答案已隱藏，但統計仍停在 1/20。只有再次點「繼續」才刷新。

根因在窗口控制器：失焦會釋放回答權和清除答案，重新激活卻只改 `isWindowActive`，沒有重讀持久會話及統計。不是保存失敗，也不是新事件被重複計分。

## 修復

窗口從非活動變成活動、且資料可用時，重讀會話摘要與統計。若資料維護期間取得焦點，等資料重新可用才刷新。重複的 active/available 通知不重跑處理。

這裡只讀資料，不取得回答權、不呈現卡片、不扣新卡配額、不重建固定組，也不恢復揭示狀態。繼續作答仍須使用者明確操作。

## 回歸

先新增三項共用同一 ModelContainer 的雙控制器測試，在舊代碼上得到 5 個失敗斷言：已評卡數、回答次數、revision、已結束狀態及維護結束後的摘要未更新。修復後三項轉綠，再增加重複窗口通知不清除答案/租約的回歸；四項均比較完整資料快照，確認刷新不寫資料。

| 範圍 | 結果 |
|---|---|
| 修復前定向復現 | 3 項失敗，5 個斷言符合原生症狀 |
| 修復後控制器與窗口導航 | 37 項通過，0 失敗 |
| V3 嚴格 Debug 全套 | Core 1,164 項、App 110 項；合計 1,265 通過、9 項 opt-in 跳過、0 失敗 |
| 修復後雙窗口原生復測 | 通過，見下文 |

9 項跳過包括 4 項付費 live、3 項性能和 2 項原生鍵註冊。本批只改 Review 焦點刷新，不重跑前批已通過的鍵註冊或跨版本矩陣。嚴格編譯沒有警告，`git diff --check` 通過。

```sh
swift test --scratch-path .build-v3-qa -Xswiftc -DWORDNOTE_V3_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency \
  -Xswiftc -warnings-as-errors
```

本機日誌：`/tmp/wordnote-review-focus-red.log`、`/tmp/wordnote-review-focus-green.log`、`/tmp/wordnote-review-focus-full.log`、`/tmp/wordnote-review-focus-launch.log`。

## 原生復測與設定核對

使用同一隔離 session `6F3A4CC7-2B12-4ABB-9FEC-B23159088975`，未讀寫正式詞庫或調用 AI。

1. 重建後第一窗口打開 Review，建立第二個主窗口；兩者原進度皆為 2/20。
2. 第二窗口繼續 `out-of-distribution generalization`，明確揭示後 Good 一次，進度成為 3/20，下一卡是 `gradient descent`。
3. 從 Window 菜單切回第一窗口。未點「繼續」就顯示 3/20、已復習 3 張、3 次作答；只保留「繼續」入口，没有答案或評分按鈕。原生症狀不再出現。
4. Settings > Learning 實測把組大小 20 改為 21、新卡上限 10 改為 9。切頁後保留 21/9，已存在的組仍為 20 張；最後使用重置按鈕恢復 20/10。
5. AI 頁顯示 `DeepSeek deepseek-flash`、尚未配置密鑰，隔離連接測試按鈕禁用。沒有修改憑據。

命令快捷鍵总開關維持關閉；本次切窗口使用原生 Window 菜單，沒有依賴自定義快捷鍵。

## 剩餘限制

捕獲設定頁改用完整 AX 樹讀取仍出現 `Sky Computer Use native pipe closed before response`，因此不再重試同一路徑。工具在部分窗口只返回 274x292 左右的透視縮略圖，另一次座標點擊回報 `noWindowsAvailable`，但重新讀取仍能取得原窗口；不能以這些圖宣稱指定尺寸/字體的視覺驗收。

本批補上雙窗口交接的實際證據，沒有把 Capture/Data 設定、髒編輯窗口保護、真實中文 IME、跨 App 實體全局鍵或完整 VoiceOver 路徑標為通過。B 階段仍有原生出口待補，不進入 C，不升級正式詞庫。
