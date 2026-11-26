# snap-gif

最后更新：2026-11-26

- 目标：本地 macOS 截图及 GIF 录制工具，提供操作窗口、Dock 入口和菜单栏快捷入口。捕获完成自动复制，支持修改全局快捷键。
- 技术栈：Swift、AppKit、Carbon 快捷键、ScreenCaptureKit、ImageIO。最低 macOS 14。
- 源码位于 `Sources/main.swift`；运行 `./build.sh` 生成 `build/snap-gif.app`，再用 `open build/snap-gif.app` 打开。
- 默认截图 ⌃⌥5、GIF ⌃⌥6，可在主窗口分别修改并保存。全局快捷键通过 Carbon 事件分发器接收按键释放事件，未成功注册的组合会在设置中标记。框选后按框下按钮或再次按 GIF 快捷键开始，录制中可停止或停止并丢弃；生成后可只复制、保存并复制或丢弃，最长 15 秒。首次使用可点主窗口「申请录屏权限…」直达系统设置并授权。
- 已验证：Swift 编译与 App 签名通过。应用内测试用 ScreenCaptureKit 捕获屏幕上的纯色窗口，验证指定区域、暂停、独立测试剪贴板、保存失败保留录制以及落盘 GIF 的尺寸、帧数和颜色。本机已验证操作窗口显示，并实际点击录制按钮触发系统录屏权限提示。也已在本机实测权限按钮跳转至「录屏与系统录音」。授权仍由用户在系统设置完成。录制以 ScreenCaptureKit 的实际采集结果为准，系统拒绝时提供设置入口。
- App 图标：`assets/images/AppIcon.icns` 用于 Finder 和 Dock，预览为 `assets/images/snap-gif-icon.png`。可用 `scripts/render-app-icon.swift` 渲染 iconset，再用 `iconutil` 转换。
- 剪贴板：GIF 提供完整 GIF 数据和本地原文件 URL；截图仍复制 PNG。保存并复制、只复制和图库复制共用同一个写入方法。
- 焦点：系统后台启动不主动激活；快捷键设置离开 App 后隐藏且不恢复，取消框选或待录制不重开主窗口。更新仅在主窗口前台时以附属对话框询问。
- 界面：主窗口分为屏幕捕获卡片和最近 GIF 工作区，使用 AppKit 系统配色、原生控件与 SF Symbols。预览支持暂停与播放，默认尊重系统减少动态效果设置。
- 录制设置：主窗口可调整 4–60 fps 目标帧率和最长边像素上限。30/60 fps 采用 ScreenCaptureKit 连续采集与累积百分秒时序舍入，录制工具条会显示受缓冲限制的最长时长，60 fps 的实际播放取决于播放器。停止后的工具条与图库显示实际尺寸、帧数和文件大小。工具条「只复制」不写入图库，使用 App 缓存保留原文件供粘贴；两种复制操作成功后关闭录制边框和面板，不打开主窗口；保存路径先关框，再刷新图库。录制按钮支持非活动窗口的第一次鼠标点击。
- 图库：`Sources/GIFLibrary.swift` 管理 `~/Library/Application Support/snap-gif/GIFs` 中的文件，或由用户选择的默认目录。已有文件不会移动。主窗口默认展示最近 10 条，支持预览、复制、另存为、移到废纸篓，并可在 Finder 打开保存全部 GIF 的文件夹。边框与开始/停止控制由 `Sources/RecordingOverlay.swift` 提供。隔离测试使用真实 ScreenCaptureKit 验证了录制、8 帧 GIF、入库、预览、复制和移到废纸篓；安装版录屏授权仍需用户完成。
- 用户更新约定：升级必须保留已有快捷键、默认存储文件夹、帧率、清晰度及 GIF 历史。保留正式版的 App 标识和偏好键；新增默认值只用于未设置的项目，必须变更偏好格式时先兼容读取或迁移。发布前用带非默认设置的独立副本验证升级；测试不写入正式版偏好。系统录屏授权由 macOS 管理，禁止在更新中重置或改动。
- 更新：`Sources/Updater.swift` 用无登录、无 Cookie 的 URLSession 读取最新公开 Release 的 `snap-gif-update.json`，校验资产 SHA-256、App 签名、标识和版本后安装。启动和每运行 6 小时自动检查，主窗口按钮可立即查询。用户确认后才安装，拒绝版本不再自动提示。
- 发布：正式版本用 `vX.Y.Z` 标签和匹配的 Info.plist 版本；用 `./build.sh` 构建并为 arm64 和 x86_64 分别打包并上传 Release，文件名为 `snap-gif-macOS-<架构>.zip`。用 `SNAP_GIF_ARCH=x86_64 ./build.sh <独立输出路径>` 构建 Intel 版。打包好两个 ZIP 后运行 `./release-manifest.sh <ZIP 输出目录>`，把生成的 `snap-gif-update.json` 和两个 ZIP 一起上传。
- GitHub：`hydrogenhe/snap-gif`（公开），默认分支 `main`。
- CodeGraph：已用官方 CLI 执行 `CODEGRAPH_TELEMETRY=0 codegraph init --local-only`，索引 1 个 Swift 文件，索引目录不提交。源码变更后可运行 `codegraph sync`。
