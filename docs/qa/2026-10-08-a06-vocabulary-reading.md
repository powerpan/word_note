# A06 詞庫閱讀與批量整理

日期：2026-10-08（Asia/Hong_Kong）。基線：`43438d0`，分支：`codex/supplemental-development`。對應 QA-12、QA-13；核心和隔離 QA 入口已實作，實機驗收未完成。

## 範圍與邊界

- 僅 `WORDNOTE_V2_VALIDATION` 啟用新閱讀、篩選和整理界面；普通 V1 App 仍保留原有界面與搜索的短路路徑。
- 不修改 schema、快照格式或 AI 契約，不讀寫真實詞庫。單測全用內存/合成資料，性能組用純值 DTO。
- 本批沒有 DeepSeek 請求，不消耗 live 測試額度；沒有執行 C06 的 README 重寫、介紹截圖或全倉敏感資訊審計，不做 App 分發。

## 實作

| 範圍 | 行為與入口 |
|---|---|
| [閱讀投影](../../Sources/WordNoteCore/Domain/VocabularyReadingContent.swift) / [閱讀頁](../../Sources/WordNote/Presentation/V2TermReadingView.swift) | 完整中文、英文、技術說明、例句分區；捕獲原文、來源備註、保存上下文分開；點鉛筆才進草稿 |
| [搜索索引](../../Sources/WordNoteCore/Domain/VocabularyBrowseIndex.swift) / [篩選](../../Sources/WordNote/Presentation/V2VocabularyFilters.swift) | 預計算中英文鍵，簡繁中文和英文定義可查；課程/掌握度/標籤/活動取交集，五種排序 |
| [選擇模型](../../Sources/WordNoteCore/Domain/VocabularySelection.swift) / [頁面](../../Sources/WordNote/Presentation/V2VocabularyView.swift) | 穩定詞 ID；搜索/篩選清批選，排序保留可見選擇，全選不包含隱藏項；可見結果集中更新，不在每行重複整庫排序 |
| [標籤規則](../../Sources/WordNoteCore/Domain/WordNoteTags.swift) | 新增 1-80 個 Character，合併空白，規範鍵去重；原有拼寫/順序不被無關操作重写，允許移除較長 legacy 標籤 |
| [整理方案](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2OrganizationPlan.swift) / [服務](../../Sources/WordNoteCore/Domain/Services/V2/WordNoteV2Organization.swift) | 唯讀預覽、完整依賴預檢、一次保存、故障全回滾；只改 membership/tags 和實際變更詞的 revision/updatedAt |
| [整理窗口](../../Sources/WordNote/Presentation/V2VocabularyOrganizationSheet.swift) | 固定本次選中 ID，課程增/減/不變、標籤草稿、逐詞影響計數、刷新/取消；修改請求後舊預覽不可提交 |

閱讀不拆解 legacy 釋義或用 AI 補寫：主要來源存在時優先顯示它，否則標為 Latest Captured Input；没有 occurrence 時保存上下文不冒充捕獲原文。與原文逐字相同的保存上下文不重複展示。學習計數使用 legacy 標籤，不捏造新錯題率。Inbox 的 18 字摘要規則沒有改動。

活動篩選只採有效 exactRepeat LookupEvent：最近為包含邊界的 7 x 24 小時，反復為至少兩個不同 captureID；未來事件不計，不從舊 wrongCount/duplicateHitCount 補造歷史。相同 capture 防禦性去重並取最早時間；正式資料完整性仍拒絕重複業務鍵。沒有事件者在最後再次查詢排序中置後，其餘相同值按英文自然數字順序及 UUID 穩定決勝。

課程和標籤整理不增加查詢/作答事件、不改釋義、例句、來源課程快照或復習排程。預覽計數按唯一詞和每詞實際增減的關係/規範標籤鍵；移除一個鍵會移除它的全部 legacy 拼寫，但只算一次標籤指派。全部相關內容/revision/membership/所用課程在提交前重查，無關詞更新不阻塞。服務不接受隱式縮小已選範圍，也不允許同項同批增減。

保存成功接入 A04 的單步運行期 Undo，恢復原標籤陣列和 membership ID；後續相關修改會阻止撤銷。新預覽的同內容操作是 no-op，不保存、不覆蓋上一張 receipt；已提交的舊方案直接拒絕 stale，不宣稱具有跨重啟持久重放令牌。Cancel/Reset/Preview 只有值草稿變化。

## 測試覆蓋

共新增 47 項功能測試和 1 項 opt-in 性能組：

| 測試 | 數量 | 主要覆蓋 |
|---|---|---|
| [VocabularyBrowseIndexTests](../../Tests/WordNoteCoreTests/VocabularyBrowseIndexTests.swift) | 10 | 中英/簡繁匹配、交集篩選、membership 權威、7 天邊界、未來/未知事件、capture 去重、五排序與穩定決勝 |
| [VocabularySelectionTests](../../Tests/WordNoteCoreTests/VocabularySelectionTests.swift) | 6 | 排序穩定、換範圍清批選、相鄰焦點、空結果、全選與隱藏 ID 保護 |
| [VocabularyReadingContentTests](../../Tests/WordNoteCoreTests/VocabularyReadingContentTests.swift) | 5 | 長釋義逐字保留、空值、主要/最近來源、備註及上下文分離、無證據不造原文 |
| [WordNoteTagsTests](../../Tests/WordNoteCoreTests/WordNoteTagsTests.swift) | 3 | 新標籤邊界/控制字元/空白、逗號、大小寫、legacy 選項 |
| [WordNoteV2OrganizationTests](../../Tests/WordNoteCoreTests/WordNoteV2OrganizationTests.swift) | 10 | 唯讀預覽、影響數、一次保存、詞義/歷史不變、tags 去重/移除/容量、衝突/no-op/部分實際變更 |
| [WordNoteV2OrganizationCommitTests](../../Tests/WordNoteCoreTests/WordNoteV2OrganizationCommitTests.swift) | 13 | 字段/版本/關係/課程過期、刪除選中項、無關修改、故障回滾與重試、計數器/日期、dirty/restore gate、Undo |
| [VocabularyBrowsePerformanceTests](../../Tests/WordNoteCoreTests/VocabularyBrowsePerformanceTests.swift) | 1 | Release、1,000/10,000 詞、固定亂序、預熱後各 30 輪的純值索引/查詢測量 |

環境：Apple M4、16 GiB RAM、macOS 27.0.1（26A434）、Apple Swift 6.4；package 最低目標仍 macOS 14，未宣稱在 macOS 14 實機驗收。

## 驗證結果

| 驗證 | 結果 |
|---|---|
| 普通 App 嚴格 Debug 全套 | 586 項，582 通過、4 跳過、0 失敗 |
| V2 QA 嚴格 Debug 全套 | 586 項，582 通過、4 跳過、0 失敗 |
| V2 QA 嚴格 Release 全套，開啟詞庫性能組 | 586 項，583 通過、3 跳過、0 失敗；測試約 20.31 秒 |
| QA 最終啟動 | 嚴格建置成功，僅隔離 fixture；下節另列窗口未驗收狀態 |

Debug 跳過兩組 opt-in live DeepSeek 和兩組性能測試；Release 顯式開啟本批詞庫性能組，只跳過兩組 live 與備份性能。最終三組日誌無 warning/error；六份變更文檔的 126 個相對文件鏈接有效，`git diff --check` 通過。未放寬嚴格檢查：App target 與既有 Core 一致開啟 `InferSendableFromCaptures`，修正 SDK 27 的 Predicate/KeyPath 推斷；Binding 使用明確閉包，沒有加 unchecked Sendable。性能測試首次嚴格編譯攔下多餘 try，已修正；不以忽略 warning 通過。

```bash
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
RUN_VOCABULARY_PERFORMANCE_TESTS=1 swift test -c release --scratch-path .build-v2-qa \
  -Xswiftc -DWORDNOTE_V2_VALIDATION -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
./script/build_and_run.sh --ui-v2-fixture populated light
```

### 核心性能

每種規模預熱 1 次後測量 30 次；固定置換打亂輸入順序，日期相同以強制排序走英文數字決勝。中文/英文查詢均命中全部詞，標籤篩選命中一半。只有合成詞、兩類標籤及固定中英文釋義，沒有 SwiftData fetch、membership/lookup 大歷史或 SwiftUI 渲染；結果單位 ms。

| 詞數 | 操作 | p50 | p95 | max |
|---|---|---|---|---|
| 1,000 | 建索引 | 11.161 | 11.526 | 11.528 |
| 1,000 | 英文搜索 + 排序 | 9.776 | 10.146 | 10.153 |
| 1,000 | 簡體中文搜索 + 排序 | 11.115 | 11.628 | 11.710 |
| 1,000 | 中文 + 標籤 + 英文排序 | 6.386 | 6.716 | 6.728 |
| 10,000 | 建索引 | 110.890 | 113.794 | 115.071 |
| 10,000 | 英文搜索 + 排序 | 88.087 | 92.091 | 92.210 |
| 10,000 | 簡體中文搜索 + 排序 | 101.150 | 103.322 | 104.460 |
| 10,000 | 中文 + 標籤 + 英文排序 | 57.396 | 60.002 | 60.210 |

早期預排序樣本曾得出 10,000 詞中文查詢約 24 ms 的 p95，不能代表亂序排序成本，以上最終亂序測量取代該初測。界面已避免一次重繪重複整庫排序，V1 便利入口仍先判空/英文命中再做中文轉換。索引構建加查詢在大庫更新時仍有可見成本，沒有據此宣稱完整 UI 達到 200 ms 門檻；需實機量測後決定增量或后台索引策略。

## UI 與尚待驗收

本輪第一次重建的 QA session 為 `70845F55-4878-44FC-97CF-2FACFA566097`，進程在檢查時存在；一次 `getApp("com.powerpan.WordNote.UITest")` 返回 `-10005 cgWindowNotFound`。未重複輪詢相同錯誤，沒有改用其他 UI 技術，也不推斷鎖屏等原因。

最終源碼重建啟動成功，session `08A17DCB-3FFA-4B14-A2F0-D86CB3F8514D`、檢查時 PID 44232；只使用臨時 populated/light fixture，不與真實詞庫共用。進程存在和編譯成功不等於窗口可见、佈局正確或交互通過。

仍需用該隔離入口完成：

1. 980x680、1320x800、1920x1080 明/暗主題，長詞頭/多行釋義/標籤、空結果及鍵盤/VoiceOver。
2. 編輯後切詞/改搜索/返回閱讀/打開整理的 Save、Discard、Cancel；取消保留原範圍及草稿。
3. 列表勾選與單行焦點互不錯配；排序保持 ID，換篩選清空批選；整理期間另一窗口修改，刷新後重試。
4. Cancel/Reset 不寫庫；輸入未按加號的新標籤也被 Preview 納入；Apply 後列表/課程/標籤同步，Undo 仍指向正確操作。
5. 10,000 詞的實際停止輸入到列表穩定 p95 <= 200 ms，包含 SwiftData 讀取、索引更新和渲染；本批核心測量不替代該閘門。大量 membership/事件或批量整理耗時也尚未作性能驗收。

B08 的可拖列表/折疊策略、B04 的新學習計數、C 的結構化義項仍是後續工作；A06 的純文字閱讀不冒充已完成那些改造。

回退：普通編譯仍使用原 V1 界面/資料路徑。沒有正式切庫或需要反向遷移的資料；刪除/替換測試 session 不可擴展到真實庫。
