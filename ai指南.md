# snap-gif

最后更新：2026-11-21

- 目标：本地 macOS 菜单栏截图及 GIF 录制工具。捕获完成自动复制，支持修改全局快捷键。
- 技术栈：Swift、AppKit、Carbon 快捷键、ScreenCaptureKit、ImageIO。最低 macOS 14。
- 源码位于 `Sources/main.swift`；运行 `./build.sh` 生成 `build/snap-gif.app`，再用 `open build/snap-gif.app` 打开。
- 默认截图 ⌃⌥5、GIF ⌃⌥6。第二次按 GIF 快捷键停止，最长 15 秒。首次捕获需授予系统屏幕录制权限。
- 已验证：Swift 编译、App 签名。屏幕捕获与系统剪贴板需在授权后的桌面会话中进行端到端验证。
- CodeGraph：当前尚未初始化；有 CLI 时在项目根目录运行 `CODEGRAPH_TELEMETRY=0 codegraph init --local-only`。
