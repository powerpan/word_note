# 07. Review System

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
