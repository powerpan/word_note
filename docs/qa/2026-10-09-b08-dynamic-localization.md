# B08：動態提示與編輯對比

日期：2026-10-09。基線：`f5cfa15`。本批收尾界面文案，不修改 schema、備份格式、AI 請求或復習規則；普通 App 仍為 V1。

## 改動

- 資料保護服務以運行期 `WordNoteDataNotice` 保留導出詞條數、恢復分析數和自動備份失敗診斷。既有 `statusMessage/errorMessage` 仍提供相同英文內容，App 才組合本地化文案，不把語言結果寫入詞庫。
- 快捷鍵控制器保留原始錯誤類型。註冊/釋放失敗的操作建議可翻譯，macOS 錯誤碼不變；未知系統錯誤按原文呈現。
- 編輯對比將候選英文詞頭與字段標籤分開。類型、來源、方向、狀態、分類、重要度和掌握程度明確標記為系統值；釋義、例句、課程和其他用戶內容不送入翻譯字典。相等判定和衝突合併仍使用原來的強型別值。
- 三份語言資源各新增 6 鍵，總數各 731。沒有為翻譯持久化 HTTP 診斷而增加 schema 字段，也不從英文錯誤句子反向猜測類型。這些技術細節與失效引用 ID 保留原文。

## 測試

新增 4 項 App 測試和 1 項資料保護測試，並擴充 CSV、分析恢復及快捷鍵失敗斷言。覆蓋數量、原始診斷/錯誤碼、用戶內容恰好等於翻譯鍵、候選標題上下文、三語鍵與格式參數一致性。測試初次使用了不正確的草稿構造參數標籤，修正後重跑，不記作產品缺陷。

| 範圍 | 結果 |
|---|---|
| 本地化、快捷鍵、V1/V2/V3 資料保護與編輯對比定向 | 89 通過，0 失敗 |
| 完整 V3 嚴格 Debug | Core 1,156 項（7 跳過）；App 100 項（1 跳過）；合計 1,248 通過、8 跳過、0 失敗 |
| 編譯警告 / `git diff --check` | 無警告，無空白錯誤 |

命令：

```sh
swift test --scratch-path .build-v3-qa -Xswiftc -DWORDNOTE_V3_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
```

本機日誌：`/tmp/wordnote-b08-dynamic-focused.log`、`/tmp/wordnote-b08-dynamic-full.log`、`/tmp/wordnote-b08-dynamic-launch.log`。本批不重跑版本全矩陣、性能或付費 live；跳過項不代表已取得原生驗收。

## 原生觀察與阻塞

隔離 App 使用 `learning` 合成資料，session `6F3A4CC7-2B12-4ABB-9FEC-B23159088975`，未讀寫正式詞庫。

1. 舊英文進程透過窗口的 Raise 動作取得完整 2498x1660 像素截圖，Inbox 三欄與隊列區未見遮擋。這不是三個指定窗口尺寸的完整證據。
2. 重建本批簡體版後，首頁與一般設定均可讀；使用者合成詞義仍保持其原來簡繁字形。
3. 點擊捕獲設定時回報 `Sky Computer Use native pipe closed before response`。當次系統報告 `SkyComputerUseService-2026-10-09-013504.ips` 顯示服務本身 `EXC_BREAKPOINT / SIGTRAP`，堆棧包含 `Array.remove(at:)`；WordNoteQA 進程仍在，沒有對應 App 崩潰報告。關閉設定的工具動作亦因失去活動連接而被拒絕，未持續重試。
4. 已請使用者觀察隔離版捕獲和資料設定頁是否正常。尚未收到結果，不能把工具崩潰推定為 App 缺陷或 App 通過。

原生 Settings 全頁、編輯離頁/關窗/退出、多窗口、全局快捷鍵跨 App、真實中文 IME、三尺寸/大字體及 VoiceOver 路徑仍未完整驗收。服務性能記錄不能替代輸入可用時間和搜索渲染時間。B 階段保持未完成；推送本批不是進入 C 或解除正式詞庫升級閘門。README、介紹截圖和全倉敏感資訊審查保持在 C06。
