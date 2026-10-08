# B08 第一批：可攜式捕獲與學習偏好

日期：2026-10-08。前一批基線：`40d75ef`。範圍：隔離 V3 的偏好白名單、備份/恢復、啟動及受保護修復；不代表 B08 全部完成。

## 實作邊界

- 普通啟動仍為 V1，`--ui-v2-fixture` 仍為 V2；只有 `--ui-v3-fixture` 使用新增偏好。未打開、遷移或修改真實詞庫。
- 不改 V1/V2 schema、Preferences、codec 或固定 fixture bytes；不新增 V3 SwiftData 欄位。
- `WordNoteLearningPreferences` 的版本為 1，只含 defaultCourseID、defaultLookupIntent、reviewTargetCards（5-100）及 reviewDailyNewLimit（0-50）。外觀/預設來源沿用原白名單。
- 當前捕獲上下文、設備快捷鍵、API 配置、窗口布局、未保存表單均不進快照。不全量導出 UserDefaults。
- README、介紹截图和全倉敏感資訊審核仍是代碼完成後的 C06。本批無 DeepSeek 付費請求。

## 格式與恢復

V3 普通快照及修復證據新寫出 format=5；reader 可讀 1-5，但帶 learningPreferences 的 payload 降標 1-4 必須拒絕。缺省 nil 不增加舊 payload 字段，不改嵌套 V1/V2 bytes。新增偏好亦參與 checksum；只改設定可產生不同備份。

新增值隨 prepared payload、后台建庫/重開比較、啟動啟用及日誌 version=4 傳遞。十一類 counts 和 SQLite schema 不变。取消/回退不降日誌能力；V1/V2 writer 先拒絕新日誌。修改 pending 偏好但不修改原 checksum 不能啟用新庫。

切換成功後保留待套用回執，先檢查課程引用和限額，再寫入並同步 UserDefaults，最後共同確認清除兩組回執。未確認重啟仍可取得原值，普通重開不重套。UserDefaults 多 key 更新不是原子資料庫交易；套用失敗會保留日誌以重試，不宣稱可回滾每一次偏好寫入。

恢復沒有新增字段的 V1/V2/舊 V3 快照，使用 No Course/Automatic/20/10，不承接恢復前的本機值。當前上下文不被當成預設，已建立固定組不因改限額重建。已刪本機預設課程由既有 controller 明示回退；匯入快照的失效引用則嚴格拒絕。

捕獲前後重讀偏好；期間變動時整次拒絕，不建立混合狀態備份。完整性修復亦綁定新增偏好，變更使預覽失效，staging 期間變更僅取消自己的副本。原始證據保留非法引用，不能當普通備份使用。正常啟動不因壞本機預設封鎖 Settings，備份依然報錯直到使用者修正。

## 測試

新增 27 項：

- `WordNoteLearningPreferencesTests` 7 項：缺省、白名單、嚴格本機值解析、套用前引用/範圍校驗、既有 storage encoding、當前/預設分離及刪課程回退。
- `WordNoteV3LearningPreferencesTests` 14 項：format/checksum、降標、V1/V2 bytes、錯誤值、完整證據、后台捕獲、日誌 4、重開/確認/取消、篡改、舊快照缺省及啟動。
- `WordNoteV3DataProtectionTests` 4 項：手動/導出/預覽、僅偏好自動備份、捕獲期間變更及無效本機值。
- `WordNoteV3StartupRepairTests` 2 項：新增偏好使預覽過期、重檢/修復保留及 staging 期間變動取消。

定向集成 73 項通過，0 失敗。首次全套發現舊 evidence 篡改用例把 format=5 當未知版本，現已改測 6；format=5 新值降標拒絕有獨立測試。自動備份用例亦修正測試時鐘，避開首次保護備份的節流間隔；產品節流規則未更改。

嚴格編譯旗標：`-strict-concurrency=complete -warn-concurrency -warnings-as-errors`。

| 構建 | 結果 |
|---|---|
| V1 Debug | 1,209 項：1,203 通過、6 跳過、0 失敗 |
| V2 QA Debug | 1,209 項：1,203 通過、6 跳過、0 失敗 |
| V2 QA Release | 1,209 項：1,203 通過、6 跳過、0 失敗 |
| V3 QA Debug | 1,209 項：1,203 通過、6 跳過、0 失敗 |
| V3 QA Release | 1,209 項：1,203 通過、6 跳過、0 失敗 |

每次全套包括 Core 1,135 項、App 74 項。跳過項為三組 opt-in live、兩組 opt-in 性能及一組原生全局快捷鍵；不把跳過計作通過。本批未重跑付費 API 或大型性能測量。

```bash
STRICT=(-Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors)
swift test "${STRICT[@]}"
swift test --scratch-path .build-v2-qa -Xswiftc -DWORDNOTE_V2_VALIDATION "${STRICT[@]}"
swift test --scratch-path .build-v2-qa -c release -Xswiftc -DWORDNOTE_V2_VALIDATION "${STRICT[@]}"
swift test --scratch-path .build-v3-qa -Xswiftc -DWORDNOTE_V3_VALIDATION "${STRICT[@]}"
swift test --scratch-path .build-v3-qa -c release -Xswiftc -DWORDNOTE_V3_VALIDATION "${STRICT[@]}"
```

本機日誌為 `/tmp/wordnote-b08-v1-debug.log`、`/tmp/wordnote-b08-v2-debug.log`、`/tmp/wordnote-b08-v2-release.log`、`/tmp/wordnote-b08-v3-debug.log`、`/tmp/wordnote-b08-v3-release.log`，不納入 Git。各構建無編譯警告；`git diff --check`、`bash -n script/build_and_run.sh` 和 192 個本批相關文檔本地鏈接檢查通過。

## 原生驗證與剩餘出口

使用 `./script/build_and_run.sh --ui-v3-fixture learning dark E591BC84-1E9C-4C25-B9F8-CDDB887BE91C` 重啟同一個合成會話，嚴格構建/啟動成功。Computer Use 讀到正常首頁：44 ready、15 Inbox、原 CS 固定組 20 張、首次回憶 0/1 和一次回答，未丟失 B07 的復習狀態。

按 Command-comma 開系統 Settings 時，Computer Use 再報 `Sky Computer Use native pipe closed before response`。QA 進程仍存在，但這不證明設定窗口可操作，也不充分證明 App 崩潰；沒有重複點擊該入口。恢復預覽雖已加入新增偏好和可滾動資料摘要，仍未通過原生操作驗收，不能以核心測試或進程存在替代。

統一標準 Settings 窗口、可拖分隔線/側欄、三語、VoiceOver、三尺寸矩陣和真正多窗口即時同步仍是 B08 後續工作。最低 macOS、故障注入到 App 偏好同步失敗及最終正式入口切換亦未在本批驗收。
