# 03. UX Flows

## 設計方向

Word Note 是學習和整理工具，不是營銷型網站，也不是卡片堆疊式展示產品。界面應該安靜、密集、清楚，讓用戶在上課和課後整理時快速完成任務。

## 信息架構

首版主導航：

```text
Dashboard
Quick Add
Inbox
Vocabulary
Review
Courses
Settings
```

### Dashboard

首頁聚合今天要做的事：

- 今日待復習數量。
- 未整理記錄數量。
- 今日新增詞條。
- 最近輸入。
- 快速進入 Quick Add。

Dashboard 不做大型視覺化圖表。首版只展示必要指標和入口。

### Quick Add

核心輸入頁。

主要控件：

- raw text 多行輸入框。
- course 選擇器。
- source type 選擇器。
- note 可折疊輸入。
- Save 按鈕。
- Save & Analyze 按鈕。

交互要求：

- raw text 為唯一必填。
- course/source/note 不阻塞保存。
- 用戶按 Command + Enter 觸發 Save & Analyze。
- 保存成功後清空輸入，並展示最近保存狀態。
- AI 分析可以在背景中進行。
- Save & Analyze 前先做本地詞庫精確命中檢查。
- 若輸入和既有 Term.normalizedTerm 完全一致，不調用 DeepSeek，直接展示既有中文釋義。
- 命中已有詞條時提示該詞已加入今日復習隊列。

### Inbox

Inbox 是未整理原始記錄列表。

顯示範圍：

- draft：只保存，尚未分析。
- analyzing：正在分析。
- analyzed：已有候選但尚未處理完。
- failed：分析失敗，需要重試或手動整理。

列表字段：

- raw text 摘要。
- course。
- source type。
- status。
- createdAt。
- candidate count。

操作：

- 查看詳情。
- Analyze / Retry。
- Ignore。
- Delete。

### Candidate Review

Candidate Review 是從 InputRecord 到 Term 的確認界面。

布局：

```text
左側：原始輸入和整句含義
右側：候選詞條列表
底部：保存選中、全部忽略、重新解析
```

每個候選顯示：

- 勾選框。
- term。
- importance。
- category。
- reason。
- chinese meaning。
- english definition。
- AI / CS context explanation。
- example sentence。
- related terms。

編輯要求：

- 候選保存前可直接編輯。
- 必填字段：term、chineseMeaning 或 englishDefinition 至少一個。
- 未勾選候選不保存為 Term。

### Vocabulary

詞庫管理頁。

列表欄：

- term。
- termType。
- course。
- masteryLevel。
- nextReviewAt。
- updatedAt。

詳情欄：

- 基本解釋。
- AI / CS 語境說明。
- 例句。
- 原始上下文。
- 來源。
- 復習統計。

搜索和篩選：

- term 搜索。
- course 篩選。
- masteryLevel 篩選。
- sourceType 篩選。
- importance 篩選。

### Review

復習頁優先簡單、穩定。

首版卡片：

```text
正面：term + context sentence 可選
背面：中文解釋 + 英文定義 + AI / CS 語境說明 + 例句
```

操作：

- Show Answer。
- 完全不會。
- 模糊。
- 記得。
- 很熟。

完成後進入下一張卡片。

P1 交互增強：

- 模式切換：英文 -> 中文、中文 -> 英文。
- 鍵盤快捷鍵：空格顯示答案，1/2/3/4 對應 again/hard/good/easy。
- Skip / Later，允許用戶暫時跳過卡片。
- 本輪完成頁展示復習數量、四種反饋分布和明日新增待復習數。
- 錯題 / 薄弱詞入口按 wrongCount、duplicateHitCount 和近期 again/hard 排序。

### Courses

課程管理頁。

字段：

- courseName。
- courseCode。
- instructor。
- semester。
- description。

列表顯示：

- 課程名。
- 詞條數。
- 今日待復習數。
- 未整理記錄數。

### Settings

設置頁。

首版必需：

- DeepSeek API Key。
- Test API Key。
- 默認課程。
- 默認來源。

P1 再加入：

- 資料導出。
- 復習規則調整。
- 快捷鍵設置。

## 核心流程

### 流程 1：只保存原始輸入

```text
打開 Quick Add
  -> 輸入 raw text
  -> 選填 course/source/note
  -> 點 Save
  -> 建立 InputRecord(status=draft)
  -> 顯示保存成功
```

### 流程 2：保存並解析

```text
打開 Quick Add
  -> 輸入 raw text
  -> 點 Save & Analyze
  -> 本地查找 Term.normalizedTerm
  -> 若精確命中：跳過 AI，展示既有釋義，提升復習優先級
  -> 若未命中：繼續 AI 分析流程
  -> 建立 InputRecord(status=analyzing)
  -> 調用 AI
  -> 解析成功：保存 CandidateTerm，InputRecord(status=analyzed)
  -> 解析失敗：InputRecord(status=failed)，保留錯誤訊息
```

### 流程 3：候選保存到詞庫

```text
打開 analyzed InputRecord
  -> 查看候選詞條
  -> 編輯候選內容
  -> 勾選要保存的候選
  -> Save Selected
  -> 建立 Term
  -> 建立初始 ReviewEvent 或設置 nextReviewAt
  -> CandidateTerm(status=saved)
  -> InputRecord 若無未處理候選則 status=completed
```

### 流程 4：AI 失敗後手動整理

```text
打開 failed InputRecord
  -> 查看錯誤
  -> Retry Analysis 或 Add Term Manually
  -> 手動建立 Term 時保留 contextSentence=rawText
```

### 流程 5：復習

```text
打開 Review
  -> 載入 nextReviewAt <= today 的 Term
  -> 選擇復習模式
  -> 顯示卡片正面
  -> Show Answer
  -> 用戶選擇反饋
  -> 建立 ReviewEvent
  -> 更新 Term 統計和 nextReviewAt
  -> 進入下一張卡片
  -> 隊列完成後展示本輪統計
```

### 流程 6：重複詞命中

```text
打開 Quick Add 或浮窗 Quick Add
  -> 輸入 word / phrase
  -> 點 Save & Analyze 或回車
  -> normalized(rawText) 精確匹配 Term.normalizedTerm
  -> 不建立新的 InputRecord
  -> 不調用 DeepSeek
  -> 直接展示 Term.chineseMeaning / englishDefinition
  -> Term.nextReviewAt = now
  -> 若 Term.masteryLevel 為 familiar/mastered，降為 vague；new/vague 保持不提高
  -> Term.importance 最高提升一級
  -> duplicateHitCount + 1；若超過冷卻窗口，wrongCount + 1
```

## 狀態與空狀態

### Quick Add 空狀態

輸入框聚焦，提示「Paste a word, phrase, or sentence from class, paper, or slides」。

### Inbox 空狀態

沒有未整理記錄時，展示「No pending records」和 Quick Add 入口。

### Vocabulary 空狀態

沒有詞條時，展示 Quick Add 入口，不展示大型說明文本。

### Review 空狀態

今日無待復習時，展示下一次待復習日期和 Vocabulary 入口。

## 錯誤體驗

### API Key 缺失

- Save 可用。
- Save & Analyze 顯示需要配置 API Key。
- 提供 Settings 入口。

### 網絡超時

- InputRecord 不丟失。
- status = failed。
- 展示 Retry。

### JSON 解析失敗

- 保存原始 AI response 的安全摘要供調試，不展示過長內容。
- status = failed。
- 展示 Retry。

### 無候選詞條

- 展示整句含義。
- 提示「No strong terms found」。
- 提供 Add Term Manually。

### 重複詞條

- Quick Add 入口優先檢查正式詞庫 Term.normalizedTerm。
- 若 raw text 與既有 Term 完全一致，直接顯示已有釋義並加入今日復習，不進入 DeepSeek。
- 保存候選時仍需檢查 normalizedTerm，避免不同 InputRecord 產生重複 Term。
- 合併候選到已有詞條放 P1 後段；首個重點是輸入入口的精確命中短路。
