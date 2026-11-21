# snap-gif

macOS 菜单栏截图和 GIF 录制工具。捕获内容在本机处理，完成后自动复制到剪贴板。

- **⌃⌥5**：框选截图，复制 PNG。
- **⌃⌥6**：框选开始 GIF 录制。再按一次暂停并自动复制，最长 15 秒。暂停后再按一次选择保存位置，也可以在菜单栏点击「保存 GIF…」。
- **Esc**：取消框选。
- 菜单栏 → **快捷键设置**：点击要修改的快捷键并按下新组合键。

首次捕获时，在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」授予权限，并重新打开应用。屏幕区域以发起捕获时指针所在的显示器为准。GIF 最长边限制为 720 像素，目标采样率为每秒 8 帧。支持 GIF 的应用可粘贴动图，只读取 PNG 的应用会粘贴首帧。

需要 macOS 14 或更新版本。安装 Xcode Command Line Tools 后，可运行：

```sh
./build.sh
open build/snap-gif.app
```

## 安装与更新

从 [GitHub Releases](https://github.com/hydrogenhe/snap-gif/releases/latest) 下载适合你的 Mac 的 ZIP，解压后将 App 放到可写目录。需要 macOS 14 或更新版本，可选 Apple 芯片版（arm64）或 Intel 版（x86_64）。

下载和 App 内更新都无需 GitHub 登录。App 启动时和常驻期间每 6 小时检查更新，也可从菜单栏点「检查更新…」。有新版时会弹出提示。点「下载并安装」会校验更新包、替换 App 并重新打开。旧版可先手动替换为 v0.3.3。

当前安装包未经 Apple 公证，首次从浏览器下载并打开时，macOS 可能会拦截。参见 [Apple 的说明](https://support.apple.com/zh-cn/102445)。
