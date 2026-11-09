# 空闲窗口拖曳卡顿分析

本次按用户要求恢复自定义无标题栏样式。WP2 尚未开始。

## 结论与修复

可复现的性能触发点是 SurfacePanelView 最外层的 shadow（黑色 opacity 0.45、radius 18、y 8）：
它包住整棵面板树，包括文字、LED、按键及多个 AppKit 旋钮输入视图。

只移除这一处阴影、保留所有 LED 光晕，窗口移动的帧记录就从约 12–13/s 恢复到约 120/s。
最终修复没有删除外阴影，而是把它移到 background 内的圆角机壳形状上，使控件子树不在
该阴影的修饰范围内。最终版本同样维持约 120/s，保留原有视觉效果。

拖曳区间未记录到 SwiftUI View body 更新，App CPU 约 1–3%。主要异常出现在 Instruments
显示的系统 Render/合成阶段。现有证据支持阴影修饰范围引发合成成本，不能据此断言某个
WindowServer 私有函数或 GPU 着色器是瓶颈；本机权限不允许直接 sample WindowServer。

## 对照结果

本机 macOS 27.2，内建显示器最高 120 Hz，Debug 构建，Mock 空闲、无实体设备、无运行中的 Agent。
使用 Instruments SwiftUI 模板，60 Hz 合成鼠标事件拖曳约 4 秒，并记录中间窗口位置，确认窗口实际移动。
以 trace 第 3–7 秒作为拖曳比较区间。各组仅改变列出的渲染项。

| 场景 | 拖曳时每秒帧记录 | Render 平均 | Render P95 |
|---|---:|---:|---:|
| 完整面板，原阴影 | 约 12–13 | 74.6 ms | 79.4 ms |
| 空白内容对照 | 约 120 | 2.2 ms | 3.2 ms |
| 仅移除状态栏毛玻璃 | 约 13–23 | 65.3 ms | 78.0 ms |
| 移除面板所有阴影 | 约 120 | 3.6 ms | 4.6 ms |
| 仅移除最外层面板阴影，保留 LED 光晕 | 约 120 | 3.6 ms | 4.7 ms |
| 最终：只给机壳背景形状加外阴影 | 约 120 | 4.3 ms | 5.5 ms |

帧数据来自 Instruments 的显示帧与 Render 阶段记录，不是应用内 FPS 计数，也不是鼠标输入到显示
的端到端延迟。系统其他窗口可能影响显示数据；多轮单变量对照均表现出外层阴影启用与移除的巨大差异。
最终版本的显示帧生命周期平均约 17.1 ms、P95 约 25.1 ms，不能将“120 条帧记录/s”解释成所有帧延迟
都低于 8.3 ms。体感仍需用户实际拖曳确认。

## 排查过程

- 更换原生标题栏不能解决完整面板的卡顿，已撤回该样式修改。
- 移除毛玻璃未实质解决问题，相关试改已还原。
- 窗口本身已是 opaque；不是为修复而关闭整窗透明或改变窗口背景。
- 大量阴影的排查最终收敛到最外层面板阴影，无需删除 LED 光晕、改 MIDI 路由或迁移 Observation。
- 临时空白内容开关、窗口层级输出均已移除；原始 trace、导出 XML、驱动程序与采样只在忽略的
  build/drag-analysis/ 中，未加入版本控制。

复核方式：构建并打开应用，用 Instruments SwiftUI 模板录制空闲窗口拖曳，检查 View Body、
CPU、Render 和显示帧记录。命令行入口示例：

    source "$HOME/.config/dev-environment/environment.sh"
    python3 configs/macos_workflow.py build
    open build/app/BCRAgentConsole.app
    xcrun xctrace record --template SwiftUI --attach BCRAgentConsole \
      --time-limit 10s --output build/drag-analysis/manual.trace --no-prompt

录制期间实际拖曳顶部空白区；保留相同窗口尺寸、显示器与 Agent 状态再比较。

## 自定义标题栏

恢复 hiddenTitleBar，通过轻量 AppKit 桥接处理顶部空白区域的双击放大。
单击传给 AppKit，移动时不更新 SwiftUI frame 或 ViewModel；内容区、其他窗口、交通灯按钮不拦截。
桥接移除时注销事件监听。

新增 5 条 App 层单元测试覆盖：空白标题区双击、单击拖曳透传、内容区、交通灯按钮、其他窗口。
没有把阴影修饰符文本检查当成性能测试；性能结论来自上面的原生 Instruments 对照。

## 验证

- Swift：82 条 Core 测试与 5 条 App 测试通过，无新增编译警告。
- Python BuildWorkflowTests：19 条通过。
- App build、原生 startup smoke、命令配置校验、compileall、workflow help、diff 检查通过。
- 原生最小窗口布局、Mock 旋钮、双击放大/还原与拖曳位移实际检查通过。\n- 额外几何探针发现 AX 位置通知会合并，不能据其重复读数判断掉帧；改读合成器窗口几何后，\n  10 个拖曳采样点均跟随预定轨迹（容许像素取整）。性能数据仍以 Instruments 为准。
