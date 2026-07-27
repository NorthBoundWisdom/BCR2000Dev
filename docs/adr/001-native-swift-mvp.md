# ADR 001：首个 MVP 采用原生 Swift

- 状态：Accepted
- 日期：2026-07-27

## 决策

首个 BCR Agent Console 使用 Swift 6、SwiftUI 和 CoreMIDI。工程由 Swift Package
Manager 构建，FreeCM 提供仓库级工作流与 `.app` 组装。

## 理由

- 产品当前只面向 macOS，而 CoreMIDI、SwiftUI、应用生命周期和辅助功能都可直接使用
  Apple 原生 API；
- 硬件回调到 `@MainActor` 状态的路径短，首版没有 C++/FFI 或跨语言所有权成本；
- 兄弟仓库已有 Swift/FreeCM 的组织和打包实践；
- Swift Package 可让 MIDI codec、映射和状态机独立测试，同时保持 MVP 工程轻量。

## 未选择的方案

Qt 适合明确需要 Windows/Linux GUI 的阶段，但当前会增加 Qt SDK、CMake、部署和桥接
CoreMIDI 的成本。Rust 适合以后抽取高吞吐、跨平台或协议核心，但用它直接承担 macOS UI
仍需要 Swift/Objective-C 桥接，不能减少首版工作量。

## 后果

- macOS MVP 可以最快验证实体交互；
- UI 暂不跨平台；
- 领域层保持值类型和 adapter 边界，未来若验证出跨平台需求，可把协议/调度核心替换为
  Rust library，或另建 Qt 前端，而不改变用户映射和状态语义。
