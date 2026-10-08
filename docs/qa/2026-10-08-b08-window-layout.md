# B08：窗口列宽与侧栏

日期：2026-10-08。基线：`91ae96d`。本批只调整隔离 V3 的窗口布局，不改数据、备份、凭据或 AI 请求。

## 改动

主侧栏、Inbox、Vocabulary、Courses 复用 `WorkspaceSplitView`。列宽按窗口分别存入 SceneStorage；导航、筛选、当前词条及编辑草稿不归布局组件管理。窗口缩小时只限制可见宽度，扩大后恢复原偏好，不把临时窄宽度写回。隐藏侧栏也不销毁右侧内容视图。

侧栏默认 232pt，可调 200–320pt；窗口小于 1180pt 时保留 72pt 图标栏，手动隐藏则完全收起。Inbox/词库默认 350pt，可调 310–520pt；课程默认 240pt，可调 210–380pt。列表扩大仍为详情保留至少 440pt。宽度值非有限或越界时安全回退/限制，不影响词库。

工具栏和 View 菜单提供同一个侧栏开关，快捷键为 Control-Command-S，只作用于当前主窗口。分隔线支持拖动、焦点方向键、辅助功能增减及重置；右键菜单可恢复默认宽度。SceneStorage 不进入词库备份，不承诺在关闭窗口或禁用系统窗口恢复后仍还原同一窗口。

## 已验证

- 新增 7 项列宽规则测试，覆盖三个目标宽度、两种侧栏状态、上下限、窄窗口恢复、连续拖动计算及无效几何值。与窗口导航合跑 21 项全部通过。
- V3 严格 Debug 全套：Core 1,142 项、App 90 项，共 1,232 项；1,225 通过，7 跳过，0 失败。跳过项仍是四个 opt-in live、两个性能组和一个原生快捷键案例。本批没有付费请求。
- V1/V2 仅做严格构建兼容检查，不重复跑旧版全套矩阵。V2 的空详情和固定列宽行为保持不变。
- Computer Use 核对了词库宽度 350 -> 370pt、侧栏按钮和快捷键切换后当前词条不变、跨页面保留词库宽度、课程独立宽度、侧栏 232 -> 252pt，以及新窗口的独立默认宽度和隐藏状态。方向键调宽可用；关闭第二窗口后，第一窗口仍保留侧栏 252pt、词库 370pt 和选中词条。

可复现命令：

```sh
swift test --scratch-path .build-v3-qa -Xswiftc -DWORDNOTE_V3_VALIDATION \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency -Xswiftc -warnings-as-errors
./script/build_and_run.sh --ui-v3-fixture learning dark
```

本机日志：`/tmp/wordnote-b08-layout-focused.log`、`/tmp/wordnote-b08-layout-v3-debug.log`、`/tmp/wordnote-b08-layout-v1-build.log`、`/tmp/wordnote-b08-layout-v2-build.log`。

## 未验收项

本轮截图工具返回低分辨率、透视变形的窗口图。AX 控件操作结果可核对，但不足以验证真实鼠标拖动、980x680 / 1320x800 / 1920x1080 排版、文字无遮挡或完整 VoiceOver 路径，以上保留待补。没有用列宽数学测试代替视觉验收。

B08 还缺三语资源及前批 Settings 各页的完整原生回归；B 阶段出口仍未完成。按最新安排，完成整个 B 阶段并推送后暂停，不进入 C。
