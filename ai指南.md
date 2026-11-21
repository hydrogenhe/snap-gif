# snap-gif

最后更新：2026-11-21

- 目标：本地 macOS 菜单栏截图及 GIF 录制工具。捕获完成自动复制，支持修改全局快捷键。
- 技术栈：Swift、AppKit、Carbon 快捷键、ScreenCaptureKit、ImageIO。最低 macOS 14。
- 源码位于 `Sources/main.swift`；运行 `./build.sh` 生成 `build/snap-gif.app`，再用 `open build/snap-gif.app` 打开。
- 默认截图 ⌃⌥5、GIF ⌃⌥6。第二次按 GIF 快捷键暂停并自动复制，第三次打开保存窗口，最长录制 15 秒。首次捕获需授予系统屏幕录制权限。
- 已验证：Swift 编译与 App 签名通过。应用内测试用 ScreenCaptureKit 捕获屏幕上的纯色窗口，验证指定区域、暂停、独立测试剪贴板、保存失败保留录制以及落盘 GIF 的尺寸、帧数和颜色。桌面自动化超时，未实际操作鼠标框选或原生保存面板。
- GitHub：`hydrogenhe/snap-gif`（私有），默认分支 `main`。
- CodeGraph：已用官方 CLI 执行 `CODEGRAPH_TELEMETRY=0 codegraph init --local-only`，索引 1 个 Swift 文件，索引目录不提交。源码变更后可运行 `codegraph sync`。
