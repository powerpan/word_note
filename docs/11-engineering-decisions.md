# 11. Engineering Decisions

本文件記錄已做出的工程決策。後續若改變方向，應新增決策條目，不直接覆蓋歷史原因。

## Decision 001: 原始需求文檔降級為背景資料

日期：2026-07-07

決策：

`ai_vocab_mac_app_requirements.md` 保留為原始想法和背景資料。後續開發以 `docs/` 為工程源文檔。

原因：

- 原始文檔更像完整想法集合，不適合作為直接開發 backlog。
- 其中 P0 範圍偏大，需要工程收斂。
- `docs/` 可以把產品、架構、資料、AI、測試和實施分開維護。

## Decision 002: P0 收斂為核心閉環

日期：2026-07-07

決策：

P0 只保留 Quick Add、AI Analysis、Candidate Review、Vocabulary、Courses、Review、Persistence、Settings 的最小可用能力。菜單欄、全局快捷鍵、剪貼板導入、導出和複雜統計放到 P1。

原因：

- 產品價值取決於記錄 -> 解析 -> 保存 -> 復習的閉環是否順暢。
- 全局快捷鍵和菜單欄是效率增強，不是閉環本身。
- 太大的 P0 會降低首版完成概率。

## Decision 003: InputRecord、CandidateTerm、Term 分離

日期：2026-07-07

決策：

資料模型分成三層：

- InputRecord：用戶原始輸入。
- CandidateTerm：AI 生成候選。
- Term：用戶確認後的正式詞條。

原因：

- 保留上下文。
- AI 失敗不影響原始輸入。
- 用戶可以選擇保存部分候選。
- 避免把整句錯誤保存為詞條。

## Decision 004: AI 不能自動寫入正式詞庫

日期：2026-07-07

決策：

AI 只生成候選，不直接自動保存為 Term。`should_auto_select` 只影響 UI 默認勾選。

原因：

- AI 可能誤判或解釋不準。
- 詞庫是長期學習資產，需要用戶確認。
- 這能降低錯誤資料污染。

## Decision 005: 首版復習算法保持簡單

日期：2026-07-07

決策：

MVP 不實作完整 spaced repetition algorithm，只用固定間隔：

- 完全不會：1 天後。
- 模糊：3 天後。
- 記得：7 天後。
- 很熟：14 天後。

原因：

- 首版重點是閉環而非算法。
- 固定規則可預測、可測試、易調整。
- 等用戶有真實使用資料後再優化更合理。

## Decision 006: 本地優先，API Key 使用本機 env 文件

日期：2026-07-07

決策：

首版所有學習資料保存在本地。DeepSeek API Key 存入本機 env 文件，不進入 SwiftData、日誌、導出文件或 Git 倉庫。App 不讀寫 macOS Keychain，避免頻繁觸發系統密碼授權彈窗。

原因：

- 詞庫和課程資料屬於個人學習資料。
- 首版不需要後端。
- 用戶希望避免 Keychain 密碼彈窗。
- env 文件便於本地調試、遷移和命令行測試。

實施：

- Settings 寫入 `~/Library/Application Support/WordNote/deepseek.env`。
- 可用 `WORD_NOTE_ENV_FILE` 指定其他 env 文件。
- 倉庫內 `.env*` 和 `key.md` 必須保持忽略。

## Decision 007: 推薦 SwiftUI + SwiftData，最低 macOS 14

日期：2026-07-07

決策：

首版推薦使用 SwiftUI + SwiftData，最低 macOS 14。

原因：

- 快速建立原生 macOS App。
- SwiftData 足夠支持 MVP 的本地資料模型。
- 避免首版過早引入自建 SQLite 層。

備註：

如果需要支持 macOS 13 或更早版本，應新增 ADR，評估 Core Data 或 SQLite/GRDB。

## Decision 008: P1 Review 優先做學習回路，不直接引入完整 SM-2 / FSRS

日期：2026-07-09

版本備註（2026-10-07）：此為現行歷史決策。重複查詞當錯題、共同 Term 排程的部分計劃由 Decision 017 在 WN2-B03/B04 完成後取代；精確匹配、零 AI 成本及不立即導入 FSRS 的約束保留。

決策：

P1 Review 先做三件事：

- Quick Add 精確命中既有詞條時跳過 DeepSeek，直接顯示已有釋義。
- 重複輸入既有詞條時，把該詞視為薄弱詞，提升重要度並加入今日復習。
- Review 排程從固定 1/3/7/14 天升級為簡化自適應規則，但不直接引入完整 SM-2 / FSRS。

原因：

- 再次輸入同一詞通常說明用戶又遇到且沒有掌握，應立即回到復習隊列。
- 精確命中正式詞庫時重新調用 DeepSeek 沒有必要，會增加等待和 API 成本。
- 目前數據量不足以支撐複雜算法調參，透明規則更容易驗證和修正。
- Review 產品體驗的短板不只在算法，也包括模式、快捷鍵、完成統計和錯題入口。

約束：

- 只做 `normalized(rawText) == Term.normalizedTerm` 的精確匹配，不做包含匹配或模糊匹配。
- 命中時不創建 InputRecord，避免 Inbox 被重複查詞污染。
- duplicate hit 不等同於正式 Review feedback，P1 首版可不寫 ReviewEvent。
- wrongCount 需要冷卻窗口，避免短時間重複輸入刷高錯題統計。

## Decision 009: 使用版本化私有 store，保守遷移歷史資料

版本備註（2026-10-07）：私有權限與保留舊檔繼續有效；日常邏輯快照、版本演進與受控恢復切庫由待實施 Decision 019 補充。

日期：2026-07-10

決策：

- SwiftData 使用顯式 `VersionedSchema` 和 `SchemaMigrationPlan`。
- store 固定在 `~/Library/Application Support/WordNote/WordNote.store`。
- 首次發現舊 `default.store` 時，先複製主檔及 WAL/SHM 到唯一備份目錄，再複製到新位置。
- 遷移器永不刪除舊 store；啟動後執行孤兒資料修復和私有權限校正。
- 持久化容器無法打開時顯示啟動錯誤頁，禁止在記憶體 fallback 中繼續新增學習資料。

原因：

- 直接沿用 SwiftData 默認位置和隱式 schema 會讓後續模型變更難以驗證。
- 詞庫是不可替代的用戶資產，遷移必須可回退且不能覆寫已有新 store。
- 啟動修復能清理由早期不完整級聯規則留下的孤兒記錄。

## Decision 010: 分析佇列以持久化 InputRecord 為恢復來源

日期：2026-07-10

決策：

- Save & Analyze 先建立 `status = analyzing` 的 InputRecord，再立即把輸入控制權還給 UI。
- 進程內使用單一 `QuickAddAnalysisQueue` 依序處理主窗口與浮窗提交。
- App 啟動時重新入隊所有 analyzing 記錄；同 normalizedText 已排隊時不重複建立或發送。
- 單筆失敗只標記該記錄為 failed，不阻塞後續請求。
- DeepSeek 查詞默認使用 `deepseek-v4-flash` 並顯式關閉 thinking；live 測試必須顯式 opt-in。

原因：

- 網絡請求不能阻塞連續捕獲詞句。
- 僅存在記憶體的 Task 在 App 退出時會丟失，持久化狀態可在重啟後恢復。
- 順序 worker 能控制請求壓力，也讓狀態流轉和錯誤隔離更易測試。
- 結構化查詞不需要默認思考模式，關閉後延遲與輸出契約更可控。

## Decision 011: 跨實體寫入必須原子化並定義級聯規則

日期：2026-07-10

決策：

- 批量確認候選先驗證全部輸入，再一次保存；任一錯誤整批回滾。
- 刪除 InputRecord 級聯 CandidateTerm，保留 Term 但清空 `sourceRecordID`。
- 刪除 Term 級聯 ReviewEvent；刪除被引用 Course 仍被阻止。
- AI 重試保留 saved 候選、替換其餘候選，不追加歷史失敗結果。
- 新建和編輯 Term 都執行全局 normalizedTerm 去重。

原因：

- SwiftData model 關聯目前以 UUID 表示，不能依賴資料庫自動維護引用完整性。
- 部分保存和孤兒事件會使 Inbox、Vocabulary、Dashboard 和 Review 對同一資料得出不同結果。

## Decision 012: 主界面採用固定淺色研究編輯台視覺（已被 Decision 016 取代）

日期：2026-07-10

決策：

- 主窗口、Settings 和 Quick Add 浮窗使用同一套淺色外觀，不跟隨系統深色模式自動反色。
- Dashboard 從彩色 KPI 卡片改為 briefing、metric ledger、review table 和 recent activity 組成的工作台。
- 全局使用冷灰白 surface、酒紅主色、礦物青輔色和細分隔線；serif 只用於品牌、日期和詞條。
- 側欄保留穩定選擇模型，以細色條取代大面積藍色選中塊；窄窗口自動切換圖標側欄。
- 共享 surface、GroupBox、Tag 和狀態色集中在 `WordNoteTheme`，功能頁不再自行使用任意 material 或紫色/藍色卡片。

原因：

- 原界面由等寬 KPI 卡、彩色圖標和大標題構成，容易呈現通用 Dashboard 模板感，與個人研究詞庫的產品定位不符。
- 用戶選定的第一版視覺依賴穩定的淺色紙墨關係；直接自動反色會回到原本不喜歡的深色工作台。
- 統一視覺 token 能降低跨頁漂移，也使後續增加功能時有明確約束。

## Decision 013: 詞庫補全是純本地提示，不改變提交語義

日期：2026-07-10

決策：

- 主 Quick Add 和浮窗 Quick Add 都從正式 `Term.term` 生成本地前綴補全。
- 只顯示一個灰色後綴，Tab 接受；Enter 和保存按鈕仍是唯一提交入口。
- core matcher 負責候選資格和穩定排序；AppKit bridge 只負責選區、繪製和按鍵。
- 補全允許前綴匹配，但提交後的 duplicate hit 仍要求 normalizedTerm 完全相等。
- 首版不提供下拉候選、substring match、編輯距離模糊匹配或 AI 生成建議。

原因：

- 本地正式詞庫是最可信且零網絡成本的候選來源。
- 單一 ghost suggestion 保持快速捕獲界面簡潔，也避免方向鍵和候選菜單干擾輸入。
- 將排序放在純 core 邏輯中，才能對大小寫、短語和多候選分支做確定性測試。
- AppKit 能正確取得 macOS 文本選區和光標位置，避免 SwiftUI 疊層在滾動或移動光標後錯位。

## Decision 014: 中文查英文仍以英文作為正式詞條主體

日期：2026-07-13

版本備註（2026-10-07）：英文主體約束不變。「方向不新增字段」在 WN2-A02/B02 完成後由 Decision 019 的持久化意圖/方向取代，以支持用戶覆寫及跨版本重試一致。

決策：

- 查詢方向由 raw text 本地推導，不新增 SwiftData 欄位。
- 中文查英文仍建立 InputRecord 並進入 AI 分析與 Inbox 確認，不使用英文詞條精確命中短路。
- AI 回傳、Candidate Review 和 VocabularyService 三層都必須保證 `term` 為英文。
- 正式 `Term.term` 保存英文，`Term.chineseMeaning` 保存中文釋義，中文原查詢只保存在 `contextSentence`。

原因：

- Vocabulary 和 Review 的主索引、去重與卡片語義都是英文詞條；把中文查詢保存成主體會破壞既有資料契約。
- 本地推導方向可讓重試和重啟恢復得到一致結果，避免增加 schema migration。
- 多層校驗可防止模型輸出或用戶編輯繞過英文主體約束。

## Decision 015: 詞庫搜索使用字段感知的本地規範化匹配

日期：2026-07-13

決策：

- 英文 term 和英文定義使用大小寫不敏感的規範化包含匹配。
- 中文釋義先使用 ICU `Hant-Hans` 統一簡繁，再移除空白、標點和符號做子串匹配。
- 搜索 matcher 不與精確去重、Quick Add 前綴補全或 AI 語義查詢共用規則。

原因：

- 用戶記得釋義但不記得英文時，中文查找是正式詞庫的核心可用性要求。
- 簡繁規範化能覆蓋主要輸入差異，同時保持規則本地、可預測、可測試。
- 不引入拼音、向量或編輯距離可避免誤匹配和不必要的複雜度。

## Decision 016: 外觀改為系統、淺色、深色三態

日期：2026-07-13

決策：

- Decision 012 的研究編輯台佈局、字體層級與語義色約束繼續有效，但「固定淺色」被本決策取代。
- 外觀偏好以 `system | light | dark` 存入 UserDefaults；未知值回退為 `system`。
- 主窗口、Settings scene 和 Quick Add 浮窗讀取同一偏好。
- 深色基礎色使用中性黑灰，酒紅與礦物青只作狀態和操作強調，不讓畫面呈現墨綠色偏向。

原因：

- 用戶需要可控的明暗模式，而不是被固定在單一外觀。
- 單一持久化偏好可避免多窗口外觀不一致。
- 保留共享 `WordNoteTheme` token，能在增加深色模式時維持既有產品辨識度與對比度。

## Decision 017: 查詢、復習事件與方向卡片分離

日期：2026-10-07。狀態：計劃採用，待 WN2-B03/B04/B05 實施。

決策：

- 重複查詢保留本地命中和優先復習，改記 LookupEvent/priorityRequestedAt，不新增實際錯題、不降 mastery/streak、不無限提升 importance。
- ReviewCard 按方向獨立排程，ReviewEvent 只表示正式反饋；Again 是失敗，Hard 是費力回憶成功。
- 短期重學有限次數、會話有限且可恢復；日級到期與分鐘級到期分開。
- 舊 mixed wrongCount 原樣保存，事件語義分版本；主卡只遷一張，不猜測多方向能力。
- FSRS 只作 WN2-C05 評估，不能用此次結構改造暗中切換算法。

原因與取捨：舊方案直接把「查」解讀為「不會」，可能污染失敗統計；新方案保留查詢信號但弱化了自動降級，需在首頁明確呈現優先待辦以免被忽略。多卡更準確地區分能力，也增加資料/工作量；用戶顯式啟用、每日新卡配額及 sibling 限制控制負擔。這是版本化產品調整，不把原需求實作列為歷史 bug。

落地契約：[07-review-system.md](07-review-system.md)。

## Decision 018: 入庫預覽、人工字段保護與版本化編輯

日期：2026-10-07。狀態：計劃採用，待 WN2-A04/A05 實施。

決策：

- 批量處理先生成 ConfirmationPlan，區分新增、關聯、補充、忽略和衝突；只使用精確規範化詞頭建立相等關係。
- 默認關聯而非覆寫已有內容；人工逐字段接受才可修改。未解衝突不能提交，成功必須全量原子化。
- 編輯用独立草稿，revision 阻止跨窗口 stale overwrite；離開時保存/放棄/取消。
- 支持本次運行期的編輯/確認撤銷，有後續依賴時拒絕破壞性撤銷；不承諾硬刪除或正式評分的 undo。

原因與取捨：舊方案整批拒絕重複詞可以保證原子性，但使用者缺少完成整理的路徑；「跳過錯誤後部分保存」會造成難以核對的半成功，因此不採用。新增預覽會增加一個步驟，單一無衝突候選保留直接保存，批次才顯示影響摘要。

落地契約：[03-ux-flows.md](03-ux-flows.md)、[05-data-model.md](05-data-model.md)。

## Decision 019: 邏輯快照先行與可恢復的分階段資料演進

日期：2026-10-07。狀態：A01 核心與 App 接入於 2026-10-08 落地並通過隔離集成測試，完整 UI/性能驗收待補，見 [App 接入證據](qa/2026-10-08-a01-app-integration.md)；A02/B03/C01 待實施。

2026-10-08 性能修訂：大庫同步捕獲/建庫會阻塞 MainActor，改成背景獨立 context 及樂觀保存世代校驗；恢復仍維持寫入屏障，worker 完成後重讀 journal，取消/競爭不提交過期結果。保留完整驗證而不是縮減資料範圍，見 [測量與限制](qa/2026-10-08-a01-background-persistence.md)。

決策：

- V1 上先提供完整快照/恢復，再順序演進 V2 關聯、V3 卡片/會話、V4 義項；每版都能讀取受支持舊快照。
- 凍結每版 SwiftData 類型形狀，使用原版 fixture；備份、遷移、刪除與資料完整性同步交付。
- 捕獲意圖/解析方向持久化，允許後續手動覆寫但重試不漂移；多課程 membership 與歷史 occurrence 分開。
- 日常備份使用一致 DTO 快照，不在線複製 SQLite sidecars。恢復先建隔離庫，以恢復日誌和啟動前切換處理中斷，原庫保留。
- 快照不含 key/env；私有權限與本機 env-file 憑據策略不變，CSV 不是完整備份。

原因與取捨：無日常恢復能力就調模型，把風險留給唯一真實庫，不可接受。邏輯快照需要維護 adapter、會增加磁碟占用和恢復步驟；換來可檢查內容、版本兼容和中斷回退。自動快照只保留 7 份，保護快照由用戶管理，不能在磁碟不足時偷偷刪除最後可用備份。

落地契約：[05-data-model.md](05-data-model.md)、[08-security-privacy.md](08-security-privacy.md)。

## Decision 020: 義項結構化，AI 品質與練習影響分開驗證

日期：2026-10-07。狀態：計劃採用，待 WN2-C01/C02/C04 實施。

決策：

- 本義與確有區別的專業義作為義項；舊全文保留為 legacy，不靠標點猜拆、不在遷移時生成。
- AI schema v2、prompt/model 版本、ContentRevision 差異接受共同保護人工內容。
- 60 例固定評測同時檢查常用義覆蓋、正確性和上下文；只有品質、成本、延遲有對照結果才改預設。
- 不強求每词多義或 AI 語境，不以輸出字數、型號新舊或自報 confidence 代替準確性。
- AI 按需練習默認不影響復習，只在使用者明確選卡及正式反饋後經同一服務寫事件。

原因與取捨：長段落容易掩蓋缺義，直接再生成易損壞人工校訂；結構化有助閱讀但帶來遷移/編輯複雜度，所以放在 A/B 閉環之後。評測可能得出不如基線的結果，屆時保留舊預設，不為完成任務強行切換。題目與模型評語仍可能錯，使用者保留最終判斷權。

落地契約：[06-ai-integration.md](06-ai-integration.md)、[13-supplemental-development-plan.md](13-supplemental-development-plan.md)。
