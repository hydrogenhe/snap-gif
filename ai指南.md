# snap-gif

最后更新：2026-11-21

- 目标：本地 macOS 截图及 GIF 录制工具，提供操作窗口、Dock 入口和菜单栏快捷入口。捕获完成自动复制，支持修改全局快捷键。
- 技术栈：Swift、AppKit、Carbon 快捷键、ScreenCaptureKit、ImageIO。最低 macOS 14。
- 源码位于 `Sources/main.swift`；运行 `./build.sh` 生成 `build/snap-gif.app`，再用 `open build/snap-gif.app` 打开。
- 默认截图 ⌃⌥5、GIF ⌃⌥6。框选后按框下按钮或再次按 GIF 快捷键开始，录制中停止后自动保存和复制，最长 15 秒。首次使用可点主窗口「申请录屏权限…」直达系统设置并授权。
- 已验证：Swift 编译与 App 签名通过。应用内测试用 ScreenCaptureKit 捕获屏幕上的纯色窗口，验证指定区域、暂停、独立测试剪贴板、保存失败保留录制以及落盘 GIF 的尺寸、帧数和颜色。本机已验证操作窗口显示，并实际点击录制按钮触发系统录屏权限提示。也已在本机实测权限按钮跳转至「录屏与系统录音」。授权仍由用户在系统设置完成。
- 图库：`Sources/GIFLibrary.swift` 管理 `~/Library/Application Support/snap-gif/GIFs` 中的文件。主窗口可展开预览、复制、另存为和移到废纸篓。边框与开始/停止控制由 `Sources/RecordingOverlay.swift` 提供。隔离测试使用真实 ScreenCaptureKit 验证了录制、8 帧 GIF、入库、预览、复制和移到废纸篓；安装版录屏授权仍需用户完成。
- 更新：`Sources/Updater.swift` 用无登录、无 Cookie 的 URLSession 读取最新公开 Release 的 `snap-gif-update.json`，校验资产 SHA-256、App 签名、标识和版本后安装。启动和每 6 小时检查，菜单支持手动检查。
- 发布：正式版本用 `vX.Y.Z` 标签和匹配的 Info.plist 版本；用 `./build.sh` 构建并为 arm64 和 x86_64 分别打包并上传 Release，文件名为 `snap-gif-macOS-<架构>.zip`。用 `SNAP_GIF_ARCH=x86_64 ./build.sh <独立输出路径>` 构建 Intel 版。打包好两个 ZIP 后运行 `./release-manifest.sh <ZIP 输出目录>`，把生成的 `snap-gif-update.json` 和两个 ZIP 一起上传。
- GitHub：`hydrogenhe/snap-gif`（公开），默认分支 `main`。
- CodeGraph：已用官方 CLI 执行 `CODEGRAPH_TELEMETRY=0 codegraph init --local-only`，索引 1 个 Swift 文件，索引目录不提交。源码变更后可运行 `codegraph sync`。
