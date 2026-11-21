# snap-gif

macOS 截图和 GIF 录制工具。打开 App 会显示操作窗口，也可以从 Dock 再次打开。捕获内容在本机处理，完成后自动复制到剪贴板。

- **⌃⌥5**：框选截图，复制 PNG。
- **⌃⌥6**：框选录制区域。框下点「开始」，再点「停止并保存」；也可再次按快捷键开始或停止，最长 15 秒。
- **GIF 图库**：展开列表即可预览已录制的 GIF、再次复制、另存为，或移到废纸篓。录制完成会自动保存并复制。
- **Esc**：取消框选。
- 菜单栏 → **快捷键设置**：点击要修改的快捷键并按下新组合键。

首次使用时，在主窗口点「申请录屏权限…」直达系统设置的「录屏与系统录音」，允许 snap-gif 后重新打开应用。屏幕区域以发起捕获时指针所在的显示器为准。GIF 最长边限制为 720 像素，目标采样率为每秒 8 帧。支持 GIF 的应用可粘贴动图，只读取 PNG 的应用会粘贴首帧。

GIF 存在 `~/Library/Application Support/snap-gif/GIFs`，重开 App 后仍可查看。

需要 macOS 14 或更新版本。安装 Xcode Command Line Tools 后，可运行：

```sh
./build.sh
open build/snap-gif.app
```

## 安装与更新

从 [GitHub Releases](https://github.com/hydrogenhe/snap-gif/releases/latest) 下载适合你的 Mac 的 ZIP，解压后将 App 放到可写目录。需要 macOS 14 或更新版本，可选 Apple 芯片版（arm64）或 Intel 版（x86_64）。

下载和 App 内更新都无需 GitHub 登录。App 启动时和常驻期间每 6 小时检查更新，也可从菜单栏点「检查更新…」。有新版时会弹出提示。点「下载并安装」会校验更新包、替换 App 并重新打开。v0.3.3 及更新版本可直接通过 App 升级。

当前安装包未经 Apple 公证，首次从浏览器下载并打开时，macOS 可能会拦截。参见 [Apple 的说明](https://support.apple.com/zh-cn/102445)。
