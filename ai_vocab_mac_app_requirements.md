# AI 专业英语词汇记录 Mac App：功能与需求说明

## 1. 项目背景

我刚到香港，准备开始在香港科技大学攻读人工智能方向研究生。由于课程主要是英文授课，我在听课、阅读课件、看论文和完成作业时，经常会遇到不熟悉的英文单词、短语、术语或句子。

我希望开发一个 macOS App，用来快速记录这些内容，并通过 AI 自动生成适合 AI / CS 研究生语境的释义，方便课后整理和长期复习。

这个软件不是普通背单词工具，而是一个面向英文授课环境下 AI 专业学习的个人词汇与术语积累工具。

---

## 2. 产品目标

软件的核心目标是：

> 帮助 AI / CS 研究生在英文课堂、论文阅读、课件学习和作业场景中，快速记录不懂的英文内容，并自动生成专业语境下的解释，形成可复习、可管理、可长期积累的个人专业英语词汇库。

最小闭环：

```text
记录英文内容
  ↓
调用 DeepSeek API 自动解析
  ↓
生成词 / 短语 / 句子的专业解释
  ↓
用户选择保存有价值的词条
  ↓
加入本地词库
  ↓
后续复习和回顾
```

---

## 3. 核心使用场景

### 3.1 上课时快速记录

在英文授课过程中，老师讲到不熟悉的词、短语或术语时，用户需要快速记录，不希望被复杂操作打断。

示例：

```text
regularization
latent representation
gradient descent
attention mechanism
inductive bias
```

需求：

- 可以快速打开输入窗口。
- 输入单词、短语或句子后快速保存。
- 可以选择所属课程。
- 可以先保存，之后再整理。
- 上课时操作要尽量轻量。

---

### 3.2 课后整理

用户课后打开当天记录的内容，对 AI 自动生成的解释进行检查、修改和确认。

需求：

- 查看今日新增内容。
- 查看未整理词条。
- 编辑中文释义、英文释义、AI 专业语境解释。
- 确认哪些内容需要加入长期词库。
- 对无价值或过于简单的内容可以忽略或删除。

---

### 3.3 阅读论文 / 课件时记录

用户在阅读论文、PDF、Lecture Slides、作业说明时，可能会复制一段句子或短语到软件中。

示例：

```text
The model learns a latent representation of the input data.
```

软件需要判断这是一句话，并自动提取真正值得学习的内容，而不是机械解释每个单词。

例如：

- 应重点解释：latent representation
- 可以辅助说明：representation
- 不需要解释：the, a, of, data 等简单词

---

### 3.4 后续复习

用户需要定期复习已经保存的词汇、短语和术语。

需求：

- 查看今日待复习内容。
- 按课程复习。
- 按掌握程度复习。
- 按错误次数复习。
- 记录复习结果。
- 根据掌握情况安排下一次复习。

---

## 4. 用户定位

目标用户：

> 正在英文授课环境中学习 AI / CS 相关课程的中文母语研究生。

用户特点：

- 具有一定 AI / CS 专业基础。
- 英语课堂听力和专业词汇反应速度不足。
- 需要理解专业语境，而不是只查普通词典释义。
- 高频场景包括听课、读论文、看课件、写作业。
- 需要记录的不只是单词，还包括短语、术语、固定表达和句子。

---

## 5. 产品设计原则

### 5.1 先快速记录，再课后整理

上课时不要要求用户填写太多字段。用户应该可以只输入一个词或一句话，然后快速保存。

课后再补充：

- 中文解释
- 英文解释
- AI / CS 语境解释
- 例句
- 课程
- 标签
- 掌握程度

---

### 5.2 短语优先于单词拆解

AI 专业英语中，很多表达必须作为整体理解。

例如：

```text
loss function
latent representation
attention mechanism
gradient descent
feature extraction
inductive bias
hidden state
```

这些不应被机械拆成单个词解释，而应该优先作为完整短语解释。

---

### 5.3 只解释真正有学习价值的内容

当用户输入一句话时，软件不应解释所有词，而应自动判断哪些词、短语或表达值得学习。

不需要解释：

```text
the
a
an
is
are
of
to
and
```

但需要注意：有些普通词在 AI / CS 语境中有专业含义，仍然需要解释。

例如：

| 词 | 普通含义 | AI / CS 语境含义 |
|---|---|---|
| loss | 损失 | 损失函数的值 |
| bias | 偏见 | 模型偏差 / inductive bias |
| layer | 层 | 神经网络层 |
| head | 头 | attention head |
| token | 标记 | NLP 模型处理单位 |
| mask | 面具 | attention mask / segmentation mask |
| prompt | 提示 | 大模型输入指令 |
| agent | 代理 | 智能体 |

因此规则应是：

> 没有专业含义、也不影响理解的简单词不解释；但普通词如果在 AI / CS 语境中有特殊含义，则需要解释。

---

### 5.4 保留上下文

用户输入的句子或原始内容应被保留为上下文。

例如用户输入：

```text
The model learns a latent representation of the input data.
```

真正保存为词条的可能是：

```text
latent representation
```

但原句应作为该词条的 context sentence 保存，方便后续复习时理解它出现的场景。

---

## 6. 核心功能需求

## 6.1 快速记录模块

### 功能目标

让用户在上课或阅读时快速记录英文内容。

### 功能需求

- 支持输入单词。
- 支持输入短语。
- 支持输入完整句子。
- 支持输入较短段落，后续可作为扩展功能。
- 支持选择课程。
- 支持选择来源类型。
- 支持填写备注或上下文。
- 支持保存后自动进入 AI 解析流程。

### 输入字段

| 字段 | 是否必填 | 说明 |
|---|---|---|
| rawText | 是 | 用户输入的原始英文内容 |
| course | 否 | 所属课程 |
| sourceType | 否 | 课堂 / 论文 / 课件 / 作业 / 其他 |
| note | 否 | 用户备注 |

---

## 6.2 DeepSeek AI 自动释义模块

### 功能目标

用户记录单词、短语或句子时，调用 DeepSeek API 自动生成解释。

### 核心规则

1. 如果输入是单词，直接解释该词。
2. 如果输入是短语，优先把短语作为整体解释。
3. 如果输入是句子，先解释整句含义，再提取值得学习的词、短语、术语和固定表达。
4. 不解释无价值的简单功能词。
5. 普通词如果在 AI / CS 语境中有专业含义，需要解释。
6. 返回结构化结果，方便 App 保存和展示。
7. 用户可以选择哪些候选词条加入词库。

---

### 单词输入示例

用户输入：

```text
regularization
```

期望 AI 输出：

- 这是一个 AI / ML 专业词。
- 中文解释：正则化，用于限制模型复杂度、降低过拟合风险。
- 英文解释：A technique used to reduce overfitting by adding constraints or penalties to a model.
- AI 语境解释：常见于 L1 / L2 regularization，通常作为 loss function 的惩罚项。
- 例句：L2 regularization penalizes large weights in the model.
- 相关词：overfitting, loss function, L1 regularization, L2 regularization。

---

### 短语输入示例

用户输入：

```text
latent representation
```

期望 AI 输出：

- 优先解释 latent representation 这个整体短语。
- 不要机械拆成 latent 和 representation 两个独立词条。
- 可以在解释中辅助说明 latent 和 representation 的含义。
- 判断该短语值得加入词库。

---

### 句子输入示例

用户输入：

```text
The model learns a latent representation of the input data.
```

期望 AI 输出：

- 整句中文意思：模型会从输入数据中学习一种隐含的内部特征表示。
- 值得学习的词条：latent representation。
- 可选辅助词条：input data。
- 不需要解释：the, model, learns, a, of 等简单词，除非有特殊语境。

---

## 6.3 AI 返回结果结构

DeepSeek API 建议返回严格 JSON，App 按 JSON 解析。

建议字段：

```json
{
  "input_type": "word | phrase | sentence",
  "sentence_meaning": "",
  "items": [
    {
      "term": "",
      "need_to_learn": true,
      "importance": "low | medium | high",
      "category": "general | academic | AI/ML | DL | NLP | CV | math | programming",
      "reason": "",
      "chinese_meaning": "",
      "english_definition": "",
      "ai_context_explanation": "",
      "example_sentence": "",
      "related_terms": [],
      "confidence": 0.0,
      "should_auto_save": false
    }
  ]
}
```

字段说明：

| 字段 | 说明 |
|---|---|
| input_type | 判断用户输入是单词、短语还是句子 |
| sentence_meaning | 如果输入是句子，给出整句中文意思 |
| term | 候选词条 |
| need_to_learn | 是否值得学习 |
| importance | 重要程度 |
| category | 词条类别 |
| reason | 为什么建议学习 / 不学习 |
| chinese_meaning | 中文解释 |
| english_definition | 英文解释 |
| ai_context_explanation | AI / CS 语境下的解释 |
| example_sentence | 英文例句 |
| related_terms | 相关词 |
| confidence | AI 判断置信度 |
| should_auto_save | 是否建议自动保存 |

---

## 6.4 候选词条确认模块

当输入是句子或短语时，AI 可能返回多个候选项。App 应展示给用户确认。

示例：

```text
原始输入：
The model learns a latent representation of the input data.

建议加入词库：
[✓] latent representation    高优先级    AI/ML term
[ ] input data               低优先级    basic CS phrase
[ ] learns                   不建议保存  common word
```

用户可以：

- 勾选需要保存的词条。
- 查看每个词条的解释。
- 编辑 AI 生成内容。
- 保存到词库。
- 忽略不需要的词条。

---

## 6.5 词库管理模块

### 功能目标

管理所有已经保存的词、短语、术语和表达。

### 词条类型

建议支持：

```text
word
phrase
expression
sentence_pattern
```

说明：

- word：单词，例如 regularization。
- phrase：短语，例如 latent representation。
- expression：固定表达，例如 it is worth noting that。
- sentence_pattern：有学习价值的句型。

普通完整句子默认不作为词条保存，而是作为上下文保存。

---

### 词条字段

| 字段 | 说明 |
|---|---|
| term | 词 / 短语 / 表达 |
| termType | word / phrase / expression / sentence_pattern |
| chineseMeaning | 中文解释 |
| englishDefinition | 英文解释 |
| aiContextExplanation | AI / CS 专业语境解释 |
| exampleSentence | 例句 |
| contextSentence | 原始上下文句子 |
| course | 所属课程 |
| sourceType | 来源类型 |
| tags | 标签 |
| importance | 重要程度 |
| masteryLevel | 掌握程度 |
| reviewCount | 复习次数 |
| wrongCount | 错误次数 |
| nextReviewAt | 下次复习时间 |
| createdAt | 创建时间 |
| updatedAt | 更新时间 |

---

### 词库列表功能

- 查看全部词条。
- 搜索词条。
- 按课程筛选。
- 按来源筛选。
- 按词条类型筛选。
- 按掌握程度筛选。
- 按重要程度筛选。
- 按创建时间排序。
- 按下次复习时间排序。
- 按错误次数排序。

---

## 6.6 课程管理模块

### 功能目标

将词条和具体课程关联，方便按课程复习。

### 课程字段

| 字段 | 说明 |
|---|---|
| courseName | 课程名称 |
| courseCode | 课程代码 |
| instructor | 老师 |
| semester | 学期 |
| description | 课程说明 |

### 课程视图

每门课程下可以查看：

- 该课程累计词条数。
- 今日待复习词条。
- 未掌握词条。
- 高错误率词条。
- 最近新增词条。

---

## 6.7 复习模块

### 功能目标

让用户后续能够持续复习，而不是只记录不回顾。

### 掌握程度

建议支持：

```text
new        未学 / 未整理
vague      模糊
familiar   基本掌握
mastered   熟练
```

### 复习方式

MVP 先支持：

1. 英文 → 中文。
2. 中文 → 英文。
3. 上下文填空。

### 复习反馈

用户查看答案后选择：

```text
完全不会
模糊
记得
很熟
```

系统根据结果更新：

- masteryLevel
- reviewCount
- wrongCount
- nextReviewAt

### 复习入口

- 今日待复习。
- 按课程复习。
- 按错误次数复习。
- 按未掌握词复习。

---

## 6.8 统计模块

### 功能目标

让用户了解自己的词汇积累和学习压力。

### 统计内容

- 总词条数。
- 本周新增词条数。
- 今日待复习数量。
- 未整理词条数量。
- 已掌握词条数量。
- 按课程统计词条数量。
- 错误次数最多的词条。
- 最近新增词条。

---

## 7. 建议页面结构

### 7.1 Dashboard 首页

显示：

- 今日待复习数量。
- 今日新增词条。
- 未整理词条。
- 最近记录。
- 快速入口。

---

### 7.2 Quick Add 快速记录

用于快速输入英文内容，并调用 AI 解析。

功能：

- 输入 rawText。
- 选择课程。
- 选择来源。
- 保存。
- Save & Explain。
- Analyze Sentence。

---

### 7.3 Vocabulary 词库

功能：

- 词条列表。
- 搜索。
- 筛选。
- 编辑。
- 删除。
- 查看详情。

---

### 7.4 Review 复习

功能：

- 今日复习。
- 课程复习。
- 错题复习。
- 复习卡片。

---

### 7.5 Courses 课程

功能：

- 新增课程。
- 查看课程下词条。
- 查看课程统计。

---

### 7.6 Settings 设置

功能：

- DeepSeek API Key 设置。
- 默认课程设置。
- 数据导入导出。
- 复习规则设置。

---

## 8. AI 功能按钮设计

建议不要只做一个笼统的“AI 解释”按钮，而是分成几个明确任务。

### 8.1 Explain

适合输入单词或短语。

功能：

```text
解释当前输入内容。
```

---

### 8.2 Analyze Sentence

适合输入完整句子。

功能：

```text
解释整句含义，并提取值得学习的词、短语和专业表达。
```

---

### 8.3 Save & Explain

适合快速记录场景。

功能：

```text
保存原始输入，并立即调用 DeepSeek 生成解释。
```

---

## 9. 原始输入与词条的关系

建议区分两个概念：

### 9.1 InputRecord

记录用户最初输入的原始内容。

例如：

```text
The model learns a latent representation of the input data.
```

### 9.2 Term

记录真正需要学习和复习的词条。

例如：

```text
latent representation
```

这样设计的好处：

- 保留原始上下文。
- 避免把整个句子都当成词条。
- 可以从一句话中提取多个词条。
- 后续复习时可以显示原句帮助理解。

---

## 10. MVP 优先级

## 10.1 P0 必须实现

- 新增原始输入。
- 调用 DeepSeek API 解析输入。
- 判断输入类型：word / phrase / sentence。
- 单词直接生成解释。
- 短语优先整体解释。
- 句子提取值得学习的词条。
- 显示 AI 返回的候选词条。
- 用户选择保存哪些词条。
- 保存词条到本地词库。
- 查看词条列表。
- 查看词条详情。
- 编辑词条。
- 删除词条。
- 课程管理。
- 词条绑定课程。
- 基础复习卡片。
- 本地数据持久化。

---

## 10.2 P1 应该实现

- 快速记录窗口。
- 菜单栏入口。
- 全局快捷键。
- 剪贴板导入。
- 去重提醒。
- 按课程筛选。
- 按掌握程度筛选。
- 今日待复习。
- 未整理词条列表。
- 复习结果记录。
- 错误次数统计。
- JSON / CSV 导出。

---

## 10.3 P2 后续扩展

- PDF 选词导入。
- Lecture slides 导入。
- 课堂录音转文字。
- 从转录文本自动提取词条。
- 发音播放。
- 跟读练习。
- iCloud 同步。
- iPhone / iPad 版本。
- Anki 导出。
- Notion / Obsidian 导出。
- 专业词汇知识图谱。

---

## 11. 不建议首版实现的功能

首版不要做以下内容：

- 用户登录注册。
- 云同步。
- 社区词库。
- 复杂 PDF 阅读器。
- 完整语音识别。
- 多端同步。
- 付费系统。
- 社交分享。
- 复杂知识图谱。

首版目标是先让个人学习闭环跑通。

---

## 12. MVP 验收标准

首版完成后，应满足以下标准：

1. 用户可以输入一个英文单词，App 调用 DeepSeek 并生成解释。
2. 用户可以输入一个英文短语，App 优先解释短语整体含义。
3. 用户可以输入一个英文句子，App 能解释整句含义并提取值得学习的词条。
4. App 不会机械解释每个简单词。
5. 用户可以选择保存 AI 推荐的词条。
6. 保存后的词条可以在词库中查看、编辑、删除。
7. 词条可以绑定课程。
8. 词条可以进入复习队列。
9. 用户可以按课程或今日待复习进行复习。
10. 所有数据可以本地保存，关闭 App 后再次打开仍然存在。

---

## 13. 一句话总结

这个 App 是一个面向 AI / CS 英文授课场景的 macOS 专业英语词汇工具。它通过 DeepSeek API 自动分析用户记录的单词、短语和句子，只提取真正值得学习的专业词汇和表达，并将其保存为可管理、可复习、可长期积累的个人专业词库。
