# 命令快捷鍵總開關

日期：2026-10-09。基線：`a2698c4`。對應 B02、B08 / QA-16、QA-17、QA-30。

本次按使用者確認的範圍修改：命令快捷鍵預設關閉，浮窗回車保存和 Tab 補全照常保留。沒有改復習排程、查詞規則、schema 或備份格式。

## 行為

- V3 的 Settings > General 增加「啟用命令快捷鍵」；V1/V2 設置也有同一開關。使用本機 `commandShortcutsEnabled` 偏好，缺省為 false。舊 `captureShortcut.v1` 即使保存為 enabled，也不能繞過新總開關。
- 全局捕獲、Command-Shift-N、主窗口 Command-Return、Control-Command-S 及復習 Space/1–4 均受控。SwiftUI 菜單/按鈕、AppKit 文字框、復習本地事件監聽和 Carbon 註冊分別接入同一偏好；不是只刪掉菜單上的按鍵標記。
- 關閉立即釋放全局註冊，拒絕遲到回調。即使系統釋放失敗，回調也不能執行業務動作；錯誤仍可見。維護狀態與總開關分開，恢復結束不能重新打開被使用者關掉的快捷鍵。
- 鼠標按鈕和菜單、浮窗 Return、Tab 補全/焦點移動、中文組合確認、Escape、對話框確認/取消、系統編輯和窗口命令不改。普通 V1 的原有保存語義也不改。
- 可以在總開關關閉時保存全局組合；再次啟用才註冊，衝突仍走原有錯誤路徑。偏好跨窗口和重啟保留，不隨學習資料備份導入。
- 一併修正此前發現的預設全局組合衝突：新配置及 Reset 草稿改為 Control-Shift-Space；不覆寫使用者已保存的舊組合，也不改 macOS 系統設定。總開關仍預設關閉。

## 自動化

新增 14 項測試：12 項覆蓋總開關、AppKit 輸入兼容和復習命令；2 項覆蓋舊組合保留及新預設的原生註冊。既有快捷鍵測試明確先開啟，另設缺省關閉測試，避免以測試初始化掩蓋預設行為。

| 範圍 | 結果 |
|---|---|
| 快捷鍵、輸入框、復習、偏好和三語資源定向 | 73 通過，0 失敗 |
| V3 嚴格 Debug 全套，含原生註冊 | Core 1,164 項，7 跳過；App 106 項，無跳過。合計 1,263 通過、7 跳過、0 失敗 |
| 普通 V1 嚴格編譯 | 通過，未啟動正式詞庫 |
| 隔離 V3 重建與重啟 | 通過 |

7 項跳過為 4 項顯式付費 live 與 3 項性能組。本次沒有改 AI 或性能路徑，不重複跑这些測試。原生預設組合註冊/釋放、排他衝突測試實際執行並通過，不計作跳過。

```sh
RUN_NATIVE_HOTKEY_TESTS=1 swift test --scratch-path .build-v3-qa \
  -Xswiftc -DWORDNOTE_V3_VALIDATION -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift build -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

本機日誌為 `/tmp/wordnote-command-shortcuts-focused.log`、`/tmp/wordnote-command-shortcuts-full.log`、`/tmp/wordnote-command-shortcuts-v1-build.log` 及同名前綴的 `launch` / `restart` 日誌。

## 原生交互

Computer Use 操作隔離 `learning` fixture，session `6F3A4CC7-2B12-4ABB-9FEC-B23159088975`，簡體界面，隊列保持暫停。沒有使用真實詞庫或發送 AI 請求。

1. Settings > General 的「啟用命令快捷鍵」初始為 off；點擊後為 on。
2. 開啟後 Command-Shift-N 打開浮窗；Escape 關閉。回到設置關閉開關，再按同一組合不再打開浮窗。
3. 關閉狀態下，鼠標 Capture > Quick Add 仍能打開浮窗；輸入 `qui`，Tab 補為 `quick`；Return 清空輸入並顯示 `quick：迅速的；敏捷的；短時間完成的`。此為 fixture 本地命中，未外傳。
4. 主 Quick Add 輸入合成文字後按 Command-Return，文字保留、未提交；Command-A / Backspace 仍能清空。Control-Command-S 不切換側欄。
5. 重啟同一會話後，General 開關仍為 off；測試結束保持關閉。

本次取得 AX 狀態與交互證據；Settings 截圖仍是工具輸出的異常縮略畫面，不能拿來宣稱完整視覺/尺寸驗收。此前 Capture/Data 設置頁的工具服務崩潰未在本輪反覆重試。

全局鍵在其他 App 前台的實體鍵盤觸發、真實中文 IME、全部窗口尺寸和 VoiceOver 等 B 階段剩餘項沒有因本次通過而自動完成。普通 App 仍走 V1，未進入 C，也未提前做 README/介紹截圖或全倉敏感資訊審查。
