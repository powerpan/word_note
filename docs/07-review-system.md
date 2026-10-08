# 07. Review System

版本說明：下文原有 P1 規則仍是基線行為；文末「2026-10 補充契約」由 WN2-B03/B04 起啟用，未實施前不得把新計數與舊 wrongCount 混用。任務見 [13](13-supplemental-development-plan.md)。

## 目標

首版復習系統只需要完成基礎閉環：

```text
Term created
  -> nextReviewAt set
  -> due term appears in Review
  -> user reviews
  -> feedback recorded
  -> nextReviewAt updated
```

目前已完成 P1 簡化自適應排程和復習體驗，仍不引入完整 FSRS / SM-2。

## MasteryLevel

| 等級 | 說明 |
|---|---|
| new | 新增，尚未穩定掌握 |
| vague | 模糊，需要較快復習 |
| familiar | 基本掌握 |
| mastered | 熟練 |

## ReviewFeedback

| UI 文案 | 內部值 | 含義 |
|---|---|---|
| 完全不會 | again | 幾乎不記得 |
| 模糊 | hard | 有印象但不穩 |
| 記得 | good | 基本答對 |
| 很熟 | easy | 熟練 |

## 初始排程

新 Term 保存後：

- masteryLevel = new。
- reviewCount = 0。
- wrongCount = 0。
- nextReviewAt = 今天。

這樣用戶保存後即可在今日復習中看到。

## 歷史 MVP 排程規則

以下固定間隔只保留作為歷史基線，現行實作使用後文的 P1 簡化自適應排程。

| feedback | new mastery | nextReviewAt |
|---|---|---|
| again | vague | 明天 |
| hard | vague | 3 天後 |
| good | familiar | 7 天後 |
| easy | mastered | 14 天後 |

若一個 mastered 詞條選 again：

- masteryLevel 降為 vague。
- wrongCount + 1。
- nextReviewAt = 明天。

## 統計更新

每次復習：

- reviewCount + 1。
- lastReviewedAt = now。
- 寫入 ReviewEvent。
- 根據 feedback 更新 masteryLevel。
- 根據 feedback 更新 nextReviewAt。
- feedback = again 或 hard 時 wrongCount + 1。

## ReviewMode

現行模式：

```text
englishToChinese
chineseToEnglish
```

介面提供模式切換，但不同模式共用同一個 Term 排程。一次復習只記錄一個 mode 和 feedback。

P2 評估：

```text
contextCloze
```

## 卡片內容

### 正面

英文 -> 中文：

- term。
- course，可選。
- context sentence，可選。

中文 -> 英文：

- chineseMeaning。
- course，可選。
- context sentence 可選，但應遮住 term 或弱化 term，避免直接暴露答案。

### 背面

- chineseMeaning。
- englishDefinition。
- aiContextExplanation。
- exampleSentence。
- relatedTerms。

## 卡片交互

- 空格：Show Answer。
- 1：Again。
- 2：Hard。
- 3：Good。
- 4：Easy。
- Skip：本輪稍後再出現，不更新 Term。
- Later：將 nextReviewAt 推遲到明天，不增加 wrongCount。

快捷鍵只在 Review 卡片獲得焦點時生效，不能干擾 Quick Add 或文本輸入。

## due term 查詢

今日待復習：

```text
nextReviewAt != nil && nextReviewAt <= endOfToday
```

排序：

1. nextReviewAt 升序。
2. wrongCount 降序。
3. importance 降序。
4. createdAt 升序。

## 課程復習

按 courseID 過濾 due term。

若用戶選擇某課程但今日無 due term：

- 顯示該課程下一個待復習日期。
- 提供「Review all from this course」作為 P1 功能，MVP 可不做。

## 復習完成狀態

當本輪隊列為空：

- 顯示完成狀態。
- 顯示本輪復習數量。
- 顯示 again/hard/good/easy 數量。
- 顯示明天新增待復習數。
- 顯示本輪錯題和薄弱詞摘要。
- 返回 Dashboard。

## 現行簡化自適應排程

P1 不直接上完整 SM-2。採用透明、可測的簡化規則：

### 新增字段

- `reviewIntervalDays`：當前間隔天數。
- `correctStreak`：連續答對次數。

### 初始值

新 Term：

- `reviewIntervalDays = 0`。
- `correctStreak = 0`。
- `nextReviewAt = now`。

### 反饋規則

| feedback | masteryLevel | correctStreak | reviewIntervalDays | nextReviewAt | wrongCount |
|---|---|---:|---:|---|---:|
| again | vague | 0 | 1 | 1 天後 | +1 |
| hard | vague | 0 | max(1, current / 2) | 1 到 3 天後 | +1 |
| good | familiar | +1 | 根據 streak 漸進增長 | 2 / 4 / 7 / 14 天後 | 不變 |
| easy | mastered | +1 | 比 good 更快增長 | 4 / 7 / 14 / 30 天後 | 不變 |

建議首版具體曲線：

```text
good:
  streak 0 -> 2 days
  streak 1 -> 4 days
  streak 2 -> 7 days
  streak >=3 -> min(current * 2, 30)

easy:
  streak 0 -> 4 days
  streak 1 -> 7 days
  streak 2 -> 14 days
  streak >=3 -> min(current * 2, 60)
```

若 mastered 詞條 again/hard：

- `masteryLevel = vague`。
- `correctStreak = 0`。
- `wrongCount + 1`。
- `nextReviewAt` 回到 1 到 3 天內。

## 重複輸入與錯題提升

當用戶在 Quick Add 中輸入的 word / phrase 精確命中既有 Term：

- 不調用 DeepSeek。
- 直接顯示既有釋義。
- `nextReviewAt = now`，直接進入今日待復習。
- 若 `masteryLevel` 為 familiar/mastered，降為 vague；new/vague 保持不提高。
- `importance` 最多提升一級。
- `duplicateHitCount + 1`。
- 若距上次 duplicate hit 超過 10 分鐘，`wrongCount + 1`。

這個事件表示「用戶再次遇到同一詞且需要查」，不等同於正式 Review feedback。因此 P1 首版不必寫 ReviewEvent，但必須更新 Term 的復習優先級。

## 邊界情況

### 詞條缺少中文解釋

若 chineseMeaning 為空，但 englishDefinition 非空，仍可復習。

### 詞條被刪除

刪除 Term 時，ReviewEvent 可以保留或級聯刪除。MVP 建議級聯刪除，避免孤兒記錄。

### nextReviewAt 為空

不出現在今日復習。編輯詞條時可提供「Add to Review」。

## 已完成的 P1 改進

- 復習模式選擇。
- 中文 -> 英文。
- 錯題復習。
- Quick Add 重複詞命中後直接加入今日復習。
- 簡化自適應排程。
- 按錯誤次數、重複命中次數和重要度排序。
- Review session 完成統計。
- 鍵盤快捷鍵。
- 跳過卡片。
- Later 推遲到下一個本地日曆日，不寫 ReviewEvent、不增加復習統計。
- 今日到期與薄弱詞兩個隊列共用排序策略。

## P2 改進

- 上下文填空。
- 發音和跟讀。
- 更完整的 spaced repetition algorithm。
- 對不同 masteryLevel 使用不同間隔曲線。
- 自定義間隔和算法參數。

## 2026-10 補充契約

### 為何調整，而非直接換算法

舊模型把再次查詞、Hard 和 Again 都累加到 wrongCount，且識別英文與回想英文共用排程。因此目前數字不能直接表示實際回憶失敗率。先分清事件、卡片和會話，再討論更複雜的排程；不要把模型能力升級當作更換復習算法的證據。

參考邊界：Anki 的 FSRS 說明把 Hard 視為費力但成功的回憶，並提示歷史品質、期望保持率及全量重排可能影響工作量。本計劃據此採明確反饋與保守遷移，不宣稱已證明本項目的學習效果改善。[Anki 官方 Deck Options](https://docs.ankiweb.net/manual/deck-options#fsrs)

本節的 10 分鐘、每卡每日最多 2 次重學再呈現、20 張/組、10 張新卡/日是首輪產品預設，需通過實機使用驗證，不是對所有學習者的最佳值結論。

### 卡片、方向與遷移（B03）

英文識別、中文回憶、有效原句填空各自是一張卡，擁有独立排程與能力狀態。新詞默認只建立英文識別卡；其他方向用戶啟用後加入新卡池。無中文釋義的詞不能開啟中文回憶；英文識別可退回英文定義。

舊 Term 排程遷到一張主卡，方向取最後有效 ReviewEvent，無事件則英文識別；無排程保持停用。不複製成多張到期卡，不由舊總計數猜測其他方向能力。舊事件和計數保留 legacy 標記；新版「實際答錯」只計新語義 Again。詳細字段及外鍵見 [05](05-data-model.md)。

2026-10-08 已完成這一轉換的隔離模型/快照基礎，尚未啟用 B04 排程。遷移後主卡標記 legacy-v1，lapseCount 從 0 開始，保留原 nextReviewAt；舊事件不補造新語義歷史或 introducedAt。較晚事件為原型 contextCloze、但無穩定填空目標的庫會阻止自動遷移並報告，不猜測新題型。新模型通過測試不等於真實詞庫已切換，詳見 [B03 第一批](qa/2026-10-08-b03-isolated-foundation.md)。

### 反饋語義與排程（B04）

所有正式反饋都新增一個 version=2 ReviewEvent；僅 Again 增加 lapseCount。本項目 lapseCount 指正式回憶失敗次數（包括新卡），不等同其他軟件限定成熟卡的 lapse 統計。Hard 仍可標「不熟」，但不是答錯。confidentStreak 只累積 Good/Easy，不再命名為所有答對次數。

| 反饋 | 日級 new/review 卡 | relearning 卡 | 能力與計數 |
|---|---|---|---|
| Again 完全不會 | 進入重學，10 分鐘後 | 10 分鐘後再次重學；受每日上限限制 | vague、streak=0、lapseCount+1 |
| Hard 費力想起 | `min(max(1, floor(intervalDays/2)), 3)` 個日曆日後 | 仍在重學，10 分鐘後；受每日上限限制 | vague、streak=0、不加 lapse |
| Good 想起 | 按原簡化 Good 曲線 | 結束重學，1 個日曆日後 | familiar、streak+1、不加 lapse |
| Easy 很熟悉 | 按原簡化 Easy 曲線 | 結束重學，2 個日曆日後 | mastered、streak+1、不加 lapse |

日級曲線使用反饋前的 confidentStreak：Good 在 0/1/2 時為 2/4/7 天，其後 `min(max(intervalDays,1)*2,30)`；Easy 在 0/1/2 時為 4/7/14 天，其後 `min(max(intervalDays,1)*2,60)`。重學退出後實際間隔覆蓋 intervalDays。新版仍是產品內的透明簡化算法，不稱為 SM-2 或 FSRS。

重學上限按「同一卡片在當地日第一次正式呈現後，最多再呈現 2 次重學」計算。若兩次再呈現後仍 Again/Hard，轉為次日待復習，保持 vague，不顯示掌握。次數保存在卡片的 dayKey/repeatCount，另開會話或重啟不能重置；既有桶只在新日第一次正式呈現時切換。排程跨度跨午夜時保持真正的 10 分鐘，不提前到午夜抽卡。

日級日期使用 Calendar 加日，不以 86,400 秒替代本地日。分钟級重學使用絕對到期時間；裝置時鐘回調、睡眠喚醒後重新計算剩餘時間，已到期只入隊一次。明顯時鐘倒退時不寫負間隔或重置每日配額，保留事件時間及異常標記供本機核對。

按鈕上的「10 分鐘 / 明天 / N 天」與實際保存共用 scheduler 的同一輸入快照；點擊時如果卡片已被其他窗口修改，刷新預覽，不沿用過期結果。

B04 實施細則（2026-10-08）：

- 重學 quota 在正式呈現的交易中更新，不在預覽或點擊答案時增加。新日第一次呈現為基準（repeatCount=0）；同日再次呈現 relearning 才加 1，最多 2。恢復已呈現項只重新顯示正面，不再記一次；B05 必須依 session item 狀態保障冪等。Good/Easy 退出重學仍保留當日桶與已用次數，不能靠再次查詞或另開會話重新取得配額。
- 既有桶只在新日第一次正式呈現才切換；時區改變不能立即清零，既有桶按原時區保存到其日末，過界後才使用新會話時區。午夜前呈現、午夜後作答時，反饋按新日尚無再呈現計算等待，但仍保留上次呈現桶；不能把該次作答當作新日第一次呈現。跨午夜的 10 分鐘仍是完整 600 秒；到期後新日首次呈現不算前一日的再呈現。
- 早於卡片最近已保存交互時間的時鐘輸入標記 movedBackward。事件 reviewedAt/studyDay 保留觀察到的實際時間；計算到期使用不倒退的 effectiveAt，未來 writer 以 effectiveAt 維護 card.updatedAt 的高水位。倒退不清每日次數，不把 nextReviewAt 推到已知交互時間以前。日級加日使用會話的 Gregorian Calendar/時區，沒有日期時回退成「現在」的路徑。
- Again，或 relearning 的 Hard，在 repeatCount=2 時轉 review/vague、intervalDays=1，安排到次日本地日開始（不能早於既有 quota 桶結束）；結果標為上限延期，而非 reviewed 成功。仍保留這次真實 Again/Hard 事件，只有 Again 增 lapse。B05 對該項使用 postponed 終態，不混入成功完成量。
- 到期分類僅用於挑選下一張/新組，不能把已呈現項的顯示恢復當再次呈現。優先請求不能越過 suspended、sibling burial、未到時的 relearning 或 new 卡配額；新卡先分類為 new，再由每日配額/包含新卡選項決定是否呈現。
- 新排程核心與舊 ReviewScheduler 分開，復用原 Good/Easy 日級曲線；V1/V2 的 Hard/wrongCount 歷史語義不在隔離開發期間改寫。未完成 V3 writer/queue/UI 共同切換前，不能把純 scheduler 測試當成 B04 完整交付。

`ReviewCardScheduler`/`ReviewCardQueuePolicy` 的第一批隔離實作與測試見 [排程與查詢信號證據](qa/2026-10-08-b04-scheduler-signals.md)。純 feedback plan 不等於正式作答保存；第二批 writer 補齊已呈現項、完整快照、actionID 和窗口回答權校驗，並原子保存事件/卡片/會話。

B04 第二批作答交易邊界：

- writer 只接受 active 會話的當前 presented 項；不在評分時補做呈現、補抽新卡或自行消耗新卡配額。窗口回答權由同一容器共享，綁定恢復寫入屏障的 generation；釋放、重啟或恢復後必須重新取得，舊回調不能寫入。
- 已呈現的 new 卡必須持有 introducedAt。此約束同時用於完整快照、導入、啟動完整性及交易前校驗；缺失時阻止，不由作答服務臨時補時間，以免隱藏已丟失的新卡配額事實。
- 揭示以畫面讀到的完整詞條/卡片/會話/當前項快照校驗，不只看 revision。揭示後把已啟用 sibling 埋藏至次日本地日開始；本組相關未終態項標 siblingDeferred，不寫 ReviewEvent。揭示能力只留在當前租約的內存，重開或換窗口不直接恢復「已看答案」。
- 預覽是唯讀值，顯示相對間隔（10 分鐘/明天/N 天）。提交用同一 scheduler 與未變的輸入快照，按實際點擊時間重新計算絕對 due，不能沿用十分鐘前的 due。若跨日、時鐘倒退、反饋後語義/延期分類或依賴快照有變，要求刷新預覽；不默默保存不同規則。原始事件 reviewedAt 使用提交觀察時間，card.updatedAt 維持不倒退高水位。
- 同一 actionID、同一會話/卡片/反饋及 beforeSchedule 重送只返回既有事件收據，不要求重新揭示、不重扣次數或刷新游標；同 actionID 不同內容明確衝突。重送可以在會話已完成或卡片已刪除後只讀返回原事件；事件已作廢則不當成功，Term 級聯刪事件後也不能重新補造。
- 正式交易一次保存 version=2 ReviewEvent、卡片新排程、item 作答次數/結果和 session 游標/revision。Again 的 waiting、上限 postponed 與 reviewed 分開；游標只在固定集合內移至下一個未終態的已呈現/待呈現項，沒有這類項但仍有重學則 waiting，全部終態才 completed。移動游標不等於下一張已正式呈現。
- Term 兼容排程/能力/三計數及 legacy 歷史不雙寫。預覽失效、計數溢出、屏障/草稿阻擋或保存故障不留下半個事件；保存失敗仍可用原 actionID 和揭示狀態重試。

這些核心入口不取代 B05 會話建立/新卡配額、呈現冪等或 UI 生命周期，也不代表 B06 的卡片內容/填空/輸入交互已完成。正式 V3 App 仍須整套切換及實機驗收；核心證據見 [B04 作答交易](qa/2026-10-08-b04-answer-transactions.md)。

### 查詢信號，不是答錯（B04）

精確本地命中繼續零 AI 成本、不建立 Inbox 記錄，保存 LookupEvent 和 occurrence。B04 起不再增加 lapseCount、不清 streak、不降低 mastery；也不再因重複查詢反覆把內容重要度推到 high。歷史 importance 不回退，新優先级用 priorityRequestedAt 表達。

優先選已啟用的英文識別卡，沒有則選已啟用主卡；設 priorityRequestedAt=now，使它進今日待辦，不直接覆寫原始排程。明確 suspended 的卡不自動啟用，界面顯示可恢復復習；詞條尚無卡時正常建立默認識別新卡，仍受新卡配額管理。

同一卡只保留一個未處理優先請求，反覆查詢更新時間，原始查詢事件仍各自去重保存。若是等待中的重學，優先請求不突破 10 分鐘到期時間。正式反饋消費在它之前的請求；反饋後發生的新查詢保留到下一組，不向正在完成的快照無限塞新卡。

V3 本地命中寫入 source、LookupEvent、membership 和優先請求，Term 只更新内容 revision/updatedAt；舊 wrongCount/reviewCount/duplicateHitCount、lastDuplicateHitAt、mastery、streak、interval、due、importance 全部保留為兼容快照，不雙寫。選卡限已啟用的 wholeTerm：先英文識別，沒有則回退其他已啟用 wholeTerm 主卡，不隨機挑一張原句填空；只有 cloze 或停用卡時保留查詢事實，不自動增卡。真正沒有任何卡時才建立默認英文 new 卡，其優先信號仍不能繞過新卡配額。

captureID 重送只返回已有保存結果，不再加來源、查詢事件、課程關聯或優先請求；來源已刪除則報重送衝突，不靠重送復活內容。Save Only/中文查英文/未命中仍保存相應草稿或待分析記錄，不走本地英文重查信號；capture 本身不持有網絡客戶端。正式反饋只清除 observedAt 之前已存在的優先請求，未來時間的請求（包括時鐘倒退造成的情況）保守保留。

### 隊列與會話（B05）

建會話前先讀固定範圍與時鐘，卡片按 ID 去重：

1. 已到分鐘的 relearning（`nextReviewAt <= now`）。
2. 已啟用、非未到時重學的優先請求卡。
3. 日級到期卡（`nextReviewAt < startOfTomorrow`）。
4. 用戶選擇包含新卡時才補入新卡池，受每日配額限制。

同組內排序以到期時間、priorityRequestedAt、新語義失敗次數、手動 importance、建立時間和 UUID 作穩定 tie-break；不混用 legacyWrongCount 當新失敗次數。薄弱範圍使用 version=2 Again 或未處理 lookup 信號，歷史薄弱數值另標「歷史」，不偷偷轉為新事件。

預設 target=20 張不同卡（可設 5-100），newLimit=10 張/日（可設 0-50）；預設不啟用「補新卡」，無到期卡可明確選擇開始新卡。新卡第一次呈現即保存 introducedAt 並消耗當日配額，退出、另開課程或重啟不能繞過。未用配額不累積到明天；限制是不同卡數，不是答題次數。

B05 實施補充：配額不是按當前頁面或課程計數。每次首次呈現同時在會話保存 originalCardID、introducedAt、chargedAt 及當時 dayKey/timezone；刪卡/刪詞保留無詞文的引入記錄，不退還當日用量。chargedAt 是不倒退的配額時間，日桶在原時區結束前不因切時區而重置；新時區日區間與前一桶重疊時仍計入重疊的既有用量。舊隔離 V3 備份沒有此欄位時保持缺省，不補造正式歷史；尚在庫中的 introducedAt 作保守配額依據。已引入但尚未評分的 new 卡是未完成練習，不再消耗新額度，也不依賴「補新卡」開關。

只允許一個可恢復會話；開始另一範圍時先繼續或結束現有會話。開始後存固定 cardID 集合與順序；新詞、新課程關聯和新查詢在下一組處理，無限等待/擴容不符合完成條件。課程關聯變更不改本組範圍快照；刪除或停用卡立即標為不可用，解除對應引用並展示數量，不假装完成。

| 狀態 | 進入條件 | 離開方式 |
|---|---|---|
| active | 有當前可回答的卡 | 反饋、暫停、等待或結束 |
| waiting | 未結束項只剩未到時的重學 | 時間到後繼續；可離開 App |
| paused | 用戶暫停或離開 Review | 返回後明確繼續，不重建 |
| completed | 全部會話項已解決，包含自動延期/不可用等終態 | 展示分類總結，可開始下一組 |
| ended | 用戶提前結束 | 剩餘卡保留原排程供新會話使用 |

Skip 只把卡放到本組後面，不計事件、不改排程；連續略過一輪時提供暫停/結束，不自動無限循環。Later 將卡安排到次日本地日開始、清除當時優先請求，不寫 ReviewEvent，單獨記延期。卡片待重學不能因第一次 Again 就標完成。

B05 第二批控制契約：Skip 保留 presented 狀態，僅輪轉既有 item 的位置，返回時不重扣呈現次數/新卡額度；已揭示能力在成功操作後清除。連續略過所有當前可答項即保存 paused，未到時重學不迫使用戶繼續循環；正式反饋、Later 或明確繼續才重置略過輪次。Later 不需要先揭示，保留掌握度、streak/lapse、最後作答及呈現桶；new 卡改為 review 以保存延期 due，relearning 保留該 phase。到期使用不倒退時鐘的次日本地日界，必要時等待原重學桶日末；未來時間的優先請求不被誤清除。

Skip/Later 的 actionID 收據與略過輪次在會話單次保存，與 ReviewEvent 共用 actionID 唯一命名空間。同來源快照重送只讀返回收據，跨操作/來源衝突拒絕；刪卡/詞仍保留不含詞文的控制身份，不重做操作。每組最多保存 10,000 個控制收據，達到時要求結束後另開，不默默丟棄舊收據。固定集合不變，Skip 是明確允許的初始順序調整。

崩潰恢復以最後成功交易為準，重複 actionID 返回既有結果；沒有已保存 action 的評分不能猜測補記。恢復後先顯示正面，防止答案揭示狀態造成誤提交。多窗口只能一個取得回答權，其他窗口閱讀/跳轉到當前會話。

B05 第一批已提供固定建組、全局配額、首次呈現/恢復及暫停/繼續/提前結束的隔離交易。建立只存 pending，真正呈現才扣額度；同 sessionID 建組重試不重抽，已呈現項恢復不重扣。到時的重學優先於尚未呈現項，但不打斷眼前已呈現的卡；未到點只返回等待，不擴大固定組。薄弱範圍只採有效新 Again 事件或未處理優先請求，不用 legacy wrongCount 或已作廢事件；中文回憶無有效中文內容時不選入。詳見 [B05 第一批證據](qa/2026-10-08-b05-session-presentation.md)。第二批已補核心 Skip/Later 和共用統計，整輪略過後繼續從輪轉隊首恢復；過渡游標指向已略過項時不能再次提交，須先正式呈現下一項。設定及原生 UI 生命周期仍待接入，見 [第二批證據](qa/2026-10-08-b05-controls-statistics.md)。

### 卡片內容與練習（B06、C04）

- 英文識別：正面英文，背面中文及必要釋義；中文回憶：正面中文，英文只在揭示後出現，可選先輸入。
- 相同詞的其他方向/義項是 sibling；同一組不連續出題，正式揭示後其餘 sibling 延後到下一個當地日，以免當天照答案回憶虛高。因 lookup 新優先請求只顯示待辦，不突破該日埋藏限制；用戶可在詞庫自由查閱。
- 原句填空在 B06 使用 occurrence 中有可確認匹配範圍的英文；保存原文 hash、Unicode 安全範圍和答案形式。多次出現的目標需一併遮蔽以免洩露答案，無法可靠定位则不建立卡。
- 拼寫比較只提供提示，不把自然同義句當錯誤；英文輸入與 IME 期間禁用空格/數字評分快捷鍵。
- AI 生成的填空/造句屬 Practice，默認不改排程。用戶明確轉為正式反饋時仍需選定一張有效卡、明示反饋，並使用同一 actionID/交易服務，不能由模型直接評定 Again。

B06 實施契約：題目正面與答案背面使用不同值類型；正面只傳提示文字，不傳完整 Term/例句/答案供 View 隱藏。中文回憶只用有漢字的中文釋義，遮蔽其中的英文詞頭；英文例句和來源標題只放背面。拼寫比較保留原始輸入，僅按 Unicode canonical normalization、大小寫和空白比較已保存答案，結果為未輸入/匹配/需自行確認，不自動生成任何 ReviewEvent。

填空預覽基於指定 occurrence 的原文和完整來源快照。新建自動建議要求仍可核對的原 InputRecord、原文一致、捕獲時方向為英文查中文，且原文不含漢字；缺原記錄或只有 legacy context 不冒充已核實英文來源。已建立目標的原記錄後續刪除不破壞仍保留的 occurrence。單獨詞頭、遮蔽後沒有英文語境的輸入不建題。默認只找已知詞形，不自行猜屈折；用戶明確選擇原文範圍並確認後可以使用實際屈折形式和自訂可接受答案。

目標範圍為 Swift Character 偏移和長度，原文 hash 綁定原始 UTF-8。比對使用有詞邊界的 Foundation/ICU 匹配，支持大小寫、canonical Unicode、空白及常見連字符/撇號形式；不替換其他單詞的子串。正面一併遮蔽原詞、選定表面詞形和已確認答案形式的全部匹配範圍，重疊範圍合併，所有空格使用固定標記，不透露答案長度。原文修訂令依賴填空卡停用、當前項 unavailable，保留卡/事件身份但清空舊答案和範圍；不猜新位置或把舊能力移到新目標。

B06 第一批已落地上述純內容與建卡交易，見 [驗證記錄](qa/2026-10-08-b06-question-content.md)。一個來源最多 1,000 個匹配範圍，超限拒絕而非漏遮。明確新方向按 new 啟用，原已停用方向保留自身能力和引入史重新開始，不回填另一方向狀態。揭示另存詞級 reviewExposedUntil，刪除最後一張已揭示卡後新建也不能取消日內保護；既有卡的更晚埋藏不縮短。來源修訂保留原 InputRecord，修改的 snapshot 不能在未建立新原文證據前直接重建填空。

正式服務只在租約對應的完整快照已揭示後返回背面，失敗/釋放/內容變動均拒絕；選題、正式呈現前和統計共用題面資格。題目失效不扣新卡額度。原生輸入、IME/空格數字快捷鍵屏蔽、建卡面板、練習 UI 與完整 V3 runtime 仍待實作，不能把值層拼寫提示當作完整輸入驗收。

### 統計口徑（B05、B07）

| 指標 | 定義 |
|---|---|
| 回答次數 | 範圍內有效 version=2 ReviewEvent 數，重學多次各算一次 |
| 已回答不同卡 | 上述事件中不同 cardID 數；不等於整組全部已解決 |
| 本組完成卡 | 已收到正式反饋且退出重學、排到後續日的不同卡；純 Later、刪除和上限自動延期另列，不冒充成功完成 |
| 本組處理進度 | 所有終態項 / 固定目標項數，另列完成、延期、不可用；不以「成功率」命名 |
| 今日完成量 | 當地日達到完成條件的不同 cardID 數，同卡跨會話只算一次；原樣顯示分方向信息 |
| 首次回憶成功率 | 每個 studyDayKey、cardID 的第一個有效 version=2 事件中，Hard/Good/Easy 的個數 / 全部此類首事件數 |
| 實際失敗 | 新語義 Again 次數；legacy 混合 wrongCount 不相加、不冒充等價 |
| 優先查詢詞 | 有未處理 LookupEvent 信號的不同 Term 數，與卡數分開 |
| 今日剩餘 | 尚未完成的日級到期卡與可用優先卡；未到時重學另列「稍後」，不能全部顯示為現在可答 |

統計零樣本顯示「尚無記錄」及分母，不顯示 100%。studyDayKey 和 timezone 在事件當時凍結；切換時區不改寫既有日桶。若未來支持作答撤銷，須先增加獨立規格；當前 invalidatedAt 只為資料修復保留，被明確作廢的事件不計入。現有 A04 撤銷僅涵蓋編輯/確認，不承諾復習撤銷。

新正式事件在保存時分配全局唯一、递增的 recordedOrder，以實際保存先後判斷每日每卡首次有效回答，原始 reviewedAt 仍保留，不因時鐘倒退重排。早期隔離 V3 缺序號的事件按觀察時間/UUID 作確定性回退並標記順序為估計，不補造序號；V1/V2 legacy 事件不進新版指標。當前日以報表時區取得 dayKey，再按已凍結 dayKey 篩事件，不重新換算歷史日桶；包含時鐘異常的樣本須可見。

會話處理進度以實際固定項數為分母，不以配置的 target 上限作分母。reviewed、手動 Later、重學上限延期、其他無法確認原因的延期、siblingDeferred、unavailable 分開；已作廢或無有效成功證據的 completed 項列為未驗證結果，不冒充成功。全局每日首次回答先在全庫去重，再過濾到會話，第二個會話的同日重答不成為新的首次樣本。

課程包含多個 membership，但全局按 cardID/termID 去重；不同課程分別展示同詞時不可以把課程小計直接相加當全局。Dashboard、Course、Review 共用一個統計服務和同一時間快照。

課程報表以當前 membership 過濾詞和相關事件，不宣稱是歷史上課時的歸屬；會話報表按凍結 sessionID/範圍。刪卡後保留 originalCardID 的有效事件仍可統計，刪詞級聯刪除的事件不補造。現在可答、未到時重學、未引入新卡及 sibling 埋藏分開，未消費的 priority 信號按不同詞去重，不把埋藏/等待中的信號算作立即可答。

### FSRS 評估閘門（C05）

先記錄候選實作版本、授權、Swift/macOS 14 集成、離線能力和升級成本，再用可靠事件回放。測試資料不足時只驗證計算與集成，不承諾個人化收益；模擬較少卡量也不能證明真實記憶效果更好。

Go 至少需要：可固定版本、確定性測試通過、能比較相同輸入下的到期負擔、參數/資料不足的回退方案、可靠的語義資料、預算及維護成本可接受。No-Go 記錄原因並維持簡化算法。採用仍須另寫遷移 ADR、用戶可見的排程影響預覽、回退和獨立任務，本輪不得自動重排全庫。
