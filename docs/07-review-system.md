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

首版不實現完整 SM-2 或複雜間隔重複算法。

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

## MVP 排程規則

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

MVP 只做：

```text
englishToChinese
```

P1 加入：

```text
chineseToEnglish
```

P2 評估：

```text
contextCloze
```

## 卡片內容

### 正面

- term。
- course，可選。
- context sentence，可切換顯示。

### 背面

- chineseMeaning。
- englishDefinition。
- aiContextExplanation。
- exampleSentence。
- relatedTerms。

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
- 返回 Dashboard。

## 邊界情況

### 詞條缺少中文解釋

若 chineseMeaning 為空，但 englishDefinition 非空，仍可復習。

### 詞條被刪除

刪除 Term 時，ReviewEvent 可以保留或級聯刪除。MVP 建議級聯刪除，避免孤兒記錄。

### nextReviewAt 為空

不出現在今日復習。編輯詞條時可提供「Add to Review」。

## P1 改進

- 復習模式選擇。
- 中文 -> 英文。
- 錯題復習。
- 按錯誤次數排序。
- 自定義間隔。
- 跳過卡片。

## P2 改進

- 上下文填空。
- 發音和跟讀。
- 更完整的 spaced repetition algorithm。
- 對不同 masteryLevel 使用不同間隔曲線。

