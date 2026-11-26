import AppKit
import Carbon
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

enum Action: UInt32, CaseIterable {
    case screenshot = 1, gif
    var title: String { self == .screenshot ? "截取屏幕区域" : "录制区域 GIF" }
    var initialKey: UInt32 { self == .screenshot ? UInt32(kVK_ANSI_5) : UInt32(kVK_ANSI_6) }
}

struct Shortcut {
    let key: UInt32
    let modifiers: UInt32
    let label: String
}

final class SelectionView: NSView {
    var finish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    private var region: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill()
        bounds.fill()
        if let region {
            NSColor.clear.setFill()
            region.fill(using: .copy)
            NSColor.white.setStroke()
            NSBezierPath(rect: region.insetBy(dx: -0.5, dy: -0.5)).stroke()
        } else {
            let message = "拖动框选区域 · Esc 取消" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let size = message.size(withAttributes: attributes)
            let rect = CGRect(x: (bounds.width - size.width) / 2 - 16, y: 48,
                              width: size.width + 32, height: size.height + 20)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            message.draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 10), withAttributes: attributes)
        }
    }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        current = CGPoint(x: min(max(0, point.x), bounds.width), y: min(max(0, point.y), bounds.height))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if let region, region.width >= 4, region.height >= 4 { finish?(region.integral) }
        else { start = nil; current = nil; needsDisplay = true }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape { finish?(nil) }
        else { super.keyDown(with: event) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}

final class SelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum CaptureError: LocalizedError {
    case display, encoding, clipboard
    var errorDescription: String? {
        switch self {
        case .display: return "找不到选中的屏幕，请重新框选。"
        case .encoding: return "无法生成图片，请重试。"
        case .clipboard: return "无法写入剪贴板，请重试。"
        }
    }
}

struct Frame {
    let image: CGImage
    let time: TimeInterval
}

func encode(_ frames: [Frame], end: TimeInterval, gif: Bool, highRateFPS: Int? = nil) throws -> Data {
    let bytes = NSMutableData()
    let type = gif ? UTType.gif : UTType.png
    guard !frames.isEmpty,
          let output = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, frames.count, nil)
    else { throw CaptureError.encoding }
    if gif {
        CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0
        ]] as CFDictionary)
    }
    var writtenTicks = 0
    for (index, frame) in frames.enumerated() {
        let next = index + 1 < frames.count ? frames[index + 1].time : end
        var props: CFDictionary?
        if gif {
            var delay = [kCGImagePropertyGIFDelayTime: max(0.02, next - frame.time)]
            if let highRateFPS {
                // GIF stores centiseconds. Round cumulative time so 30 and 60 fps do not drift.
                let desiredTicks = Int((100 * (next - frames[0].time)).rounded())
                let ticks = max(highRateFPS == 60 ? 1 : 2, desiredTicks - writtenTicks)
                writtenTicks += ticks
                delay[kCGImagePropertyGIFUnclampedDelayTime] = Double(ticks) / 100
                delay[kCGImagePropertyGIFDelayTime] = Double(ticks) / 100
            }
            props = [kCGImagePropertyGIFDictionary: delay] as CFDictionary
        }
        CGImageDestinationAddImage(output, frame.image, props)
    }
    guard CGImageDestinationFinalize(output) else { throw CaptureError.encoding }
    return bytes as Data
}

@MainActor
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private lazy var status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var controls: NSWindow?
    private var didFinishLaunching = false
    private var quietLaunch = false
    private var controlStatus: NSTextField?
    private var controlScreenshot: NSButton?
    private var controlGIF: NSButton?
    private var controlPermission: NSButton?
    private var resettingScreenRecordingPermission = false
    private var controlUpdate: NSButton?
    private var libraryDisclosure: NSButton?
    private var libraryView: GIFLibraryView?
    private var libraryExpanded = false
    private var gifStore = GIFStore.preferred()
    private var storageButton: NSButton?
    private var overlay: RecordingOverlay?
    private var startSelectedRecording: (() -> Void)?
    private var readyToRecord: Bool {
        startSelectedRecording != nil && busy && !recording && pausedAt == nil && pendingGIF == nil
    }
    private var selection: SelectionWindow?
    private var settings: NSPanel?
    private var monitor: Any?
    private var editing: Action?
    private var buttons: [Action: NSButton] = [:]
    private var hotkeys: [Action: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var state = "就绪"
    private var busy = false
    private var recording = false
    private var pausedAt: TimeInterval?
    private var discardRecording = false
    private var pendingGIF: Data?
    private var updateTimer: Timer?
    private let declinedUpdateKey = "declinedUpdateTag"
    private var checkingUpdate = false
    private var updateInstalling = false
    private var availableUpdate: (ReleaseUpdater, GitHubRelease)?
    private let signature: OSType = 0x53474946

    func applicationDidFinishLaunching(_ notification: Notification) {
        if installHotKeyHandler() {
            let unavailable = Action.allCases.filter { !register($0, shortcut($0)) }
            if !unavailable.isEmpty {
                state = "快捷键不可用：\(unavailable.map { shortcut($0).label }.joined(separator: "、"))"
            }
        } else {
            state = "无法监听快捷键，请重新打开 App"
        }
        let launchReason = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        quietLaunch = launchReason == OSType(keyAELaunchedAsLogInItem) ||
            launchReason == OSType(keyAELaunchedAsServiceItem)
        didFinishLaunching = true
        refresh()
        if NSApp.isActive && !quietLaunch { presentControls(activate: false) }
        startUpdateCheck(manual: false)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startUpdateCheck(manual: false) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        status.isVisible = true
        showControls()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if didFinishLaunching && controls == nil && !quietLaunch && !busy {
            presentControls(activate: false)
        }
        refreshPermissionButton()
        refresh()
    }

    func applicationDidResignActive(_ notification: Notification) {
        settings?.orderOut(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        for reference in hotkeys.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func installHotKeyHandler() -> Bool {
        if handler != nil { return true }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let result = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x53474946,
                  let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<App>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { app.perform(action) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        return result == noErr && handler != nil
    }

    private func shortcut(_ action: Action) -> Shortcut {
        guard let values = UserDefaults.standard.dictionary(forKey: "shortcut.\(action.rawValue)"),
              let key = values["key"] as? UInt32, let modifiers = values["modifiers"] as? UInt32,
              let label = values["label"] as? String else {
            return Shortcut(key: action.initialKey, modifiers: UInt32(controlKey | optionKey),
                            label: action == .screenshot ? "⌃⌥5" : "⌃⌥6")
        }
        return Shortcut(key: key, modifiers: modifiers, label: label)
    }

    private func register(_ action: Action, _ shortcut: Shortcut) -> Bool {
        guard installHotKeyHandler() else { return false }
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.key, shortcut.modifiers,
                                         EventHotKeyID(signature: signature, id: action.rawValue),
                                         GetEventDispatcherTarget(), 0, &reference)
        guard result == noErr, let reference else { return false }
        hotkeys[action] = reference
        return true
    }

    @objc private func showControls() { presentControls(activate: true) }

    private func presentControls(activate: Bool) {
        if controls == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 708, height: 292),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "snap-gif"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            window.titleVisibility = .hidden

            let title = NSTextField(labelWithString: "snap-gif")
            title.font = .systemFont(ofSize: 24, weight: .semibold)
            let icon = NSImageView(image: NSApp.applicationIconImage)
            icon.setAccessibilityElement(false)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
            let summary = NSTextField(wrappingLabelWithString: "先框选区域，再点「开始」。停止后可只复制，或保存并复制。")
            summary.textColor = .secondaryLabelColor
            let screenshot = symbolButton("截图", symbol: "camera", target: self, action: #selector(captureScreenshot))
            let gif = symbolButton("录制区域 GIF", symbol: "record.circle", target: self, action: #selector(captureGIF))
            gif.bezelColor = .systemIndigo
            gif.controlSize = .large
            screenshot.controlSize = .large
            let preferences = symbolButton("快捷键设置…", symbol: "keyboard", target: self, action: #selector(showSettings))
            let permission = NSButton(title: "申请权限", target: self,
                                      action: #selector(manageScreenRecordingPermission))
            let actions = NSStackView(views: [gif, screenshot])
            actions.spacing = 10
            let options = GIFRecordingSettings()
            let fps = NSPopUpButton()
            fps.addItems(withTitles: GIFRecordingSettings.frameRates.map(GIFRecordingSettings.label))
            fps.selectItem(at: GIFRecordingSettings.frameRates.firstIndex(of: options.fps)!)
            fps.target = self
            fps.action = #selector(setGIFFrameRate(_:))
            fps.setAccessibilityLabel("GIF 帧率")
            fps.toolTip = "高帧率的最长录制时间随区域大小变化。部分应用会放慢 60 fps GIF。"
            let resolution = NSPopUpButton()
            resolution.addItems(withTitles: GIFRecordingSettings.resolutions.map { "\($0) px" })
            resolution.selectItem(at: GIFRecordingSettings.resolutions.firstIndex(of: options.longestEdge)!)
            resolution.target = self
            resolution.action = #selector(setGIFResolution(_:))
            resolution.setAccessibilityLabel("GIF 清晰度")
            resolution.toolTip = "GIF 最长边的像素上限"
            let quality = NSStackView(views: [NSTextField(labelWithString: "帧率"), fps,
                                            NSTextField(labelWithString: "清晰度"), resolution])
            quality.spacing = 8
            quality.alignment = .centerY
            let statusText = NSTextField(labelWithString: state)
            statusText.textColor = .secondaryLabelColor
            statusText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let updateButton = symbolButton("检查更新…", symbol: "arrow.down.circle",
                                            target: self, action: #selector(checkUpdates))
            let header = NSStackView(views: [icon, title, NSView(), preferences, updateButton])
            header.spacing = 10
            header.alignment = .centerY

            let captureTitle = NSTextField(labelWithString: "屏幕捕获")
            captureTitle.font = .systemFont(ofSize: 17, weight: .semibold)
            let captureHeader = NSStackView(views: [captureTitle, NSView(), statusText])
            captureHeader.alignment = .firstBaseline
            quality.addArrangedSubview(NSView())
            quality.addArrangedSubview(permission)
            permission.setContentHuggingPriority(.required, for: .horizontal)
            let separator = NSBox()
            let captureBody = NSStackView(views: [captureHeader, summary, actions, separator, quality])
            captureBody.orientation = .vertical
            captureBody.alignment = .leading
            captureBody.spacing = 10
            separator.boxType = .separator
            separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
            NSLayoutConstraint.activate([
                captureHeader.widthAnchor.constraint(equalTo: captureBody.widthAnchor),
                quality.widthAnchor.constraint(equalTo: captureBody.widthAnchor),
                separator.widthAnchor.constraint(equalTo: captureBody.widthAnchor)
            ])
            let captureCard = InsetSurface(captureBody)

            let disclosure = NSButton(title: "", target: self, action: #selector(toggleLibrary))
            disclosure.setButtonType(.onOff)
            disclosure.bezelStyle = .disclosure
            disclosure.setAccessibilityLabel("展开 GIF 图库")
            let libraryLabel = NSTextField(labelWithString: "最近的 GIF")
            libraryLabel.font = .systemFont(ofSize: 17, weight: .semibold)
            let folder = symbolButton("打开存储文件夹", symbol: "folder", target: self, action: #selector(openGIFFolder))
            folder.setContentHuggingPriority(.required, for: .horizontal)
            let storage = NSButton(title: "更改存储位置…", target: self, action: #selector(changeGIFFolder))
            storage.setContentHuggingPriority(.required, for: .horizontal)
            storage.toolTip = gifStore.directory.path
            let libraryHeader = NSStackView(views: [disclosure, libraryLabel, NSView(), storage, folder])
            libraryHeader.alignment = .centerY
            libraryHeader.spacing = 7
            let library = GIFLibraryView(store: gifStore)
            library.isHidden = true
            let stack = NSStackView(views: [header, captureCard, libraryHeader, library])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 15
            stack.translatesAutoresizingMaskIntoConstraints = false
            guard let content = window.contentView else { return }
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                header.widthAnchor.constraint(equalTo: stack.widthAnchor),
                captureCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
                libraryHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
                library.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
            controls = window
            controlStatus = statusText
            controlScreenshot = screenshot
            controlGIF = gif
            controlPermission = permission
            controlUpdate = updateButton
            libraryDisclosure = disclosure
            libraryView = library
            storageButton = storage
            setLibraryExpanded(true)
            window.center()
        } else if libraryExpanded {
            libraryView?.reload()
        }
        refresh()
        refreshPermissionButton()
        controls?.deminiaturize(nil)
        if activate { NSApp.activate() }
        controls?.makeKeyAndOrderFront(nil)
    }

    @objc private func setGIFFrameRate(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if GIFRecordingSettings.frameRates.indices.contains(index) {
            UserDefaults.standard.set(GIFRecordingSettings.frameRates[index], forKey: GIFRecordingSettings.frameRateKey)
        }
    }

    @objc private func setGIFResolution(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if GIFRecordingSettings.resolutions.indices.contains(index) {
            UserDefaults.standard.set(GIFRecordingSettings.resolutions[index], forKey: GIFRecordingSettings.resolutionKey)
        }
    }

    @objc private func changeGIFFolder() {
        guard !busy, let controls else { return }
        busy = true
        refresh()
        let panel = NSOpenPanel()
        panel.title = "选择 GIF 存储文件夹"
        panel.message = "新录制将存到这里，已有 GIF 会留在原位置。"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = gifStore.directory
        panel.beginSheetModal(for: controls) { [weak self] response in
            guard let self else { return }
            defer { busy = false; refresh() }
            guard response == .OK, let folder = panel.url else { return }
            do {
                gifStore = try GIFStore.select(folder)
                storageButton?.toolTip = gifStore.directory.path
                libraryView?.useStore(gifStore)
                state = "新 GIF 将存到 \(folder.lastPathComponent)"
            } catch {
                showAlert("无法使用该文件夹", error.localizedDescription)
            }
        }
    }

    @objc private func openGIFFolder() {
        do {
            let directory = try gifStore.preparedDirectory()
            if NSWorkspace.shared.open(directory) { return }
            showAlert("无法打开存储文件夹", directory.path)
        } catch {
            showAlert("无法打开存储文件夹", error.localizedDescription)
        }
    }

    @objc private func toggleLibrary() {
        setLibraryExpanded(!libraryExpanded)
    }

    private func setLibraryExpanded(_ expanded: Bool, select file: URL? = nil) {
        libraryView?.reload(select: file)
        guard libraryExpanded != expanded, let controls else { return }
        libraryExpanded = expanded
        libraryDisclosure?.state = expanded ? .on : .off
        libraryDisclosure?.setAccessibilityLabel(expanded ? "收起 GIF 图库" : "展开 GIF 图库")
        libraryView?.isHidden = !expanded
        let delta: CGFloat = expanded ? 322 : -322
        var frame = controls.frame
        frame.origin.y -= delta
        frame.size.height += delta
        if let screen = controls.screen, frame.minY < screen.visibleFrame.minY {
            frame.origin.y = screen.visibleFrame.minY
        }
        controls.setFrame(frame, display: true, animate: false)
    }

    private func refreshPermissionButton() {
        guard let controlPermission else { return }
        controlPermission.title = CGPreflightScreenCaptureAccess() ? "录屏权限设置…" : "申请权限"
        controlPermission.isEnabled = !resettingScreenRecordingPermission
    }

    @objc private func manageScreenRecordingPermission() {
        if CGPreflightScreenCaptureAccess() {
            requestScreenRecordingPermission()
        } else {
            resetScreenRecordingPermission()
        }
    }

    private func requestScreenRecordingPermission(force: Bool = false) {
        if force || !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        let pane = if #available(macOS 26, *) {
            "com.apple.settings.PrivacySecurity.extension"
        } else {
            "com.apple.preference.security"
        }
        if let url = URL(string: "x-apple.systempreferences:\(pane)?Privacy_ScreenCapture"),
           NSWorkspace.shared.open(url) { return }
        showAlert("无法打开录屏权限设置",
                  "请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」开启 snap-gif。")
    }

    private func refresh() {
        let symbol = recording ? "record.circle.fill" : (pendingGIF == nil ? "viewfinder" : "pause.circle")
        status.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "snap-gif")
        status.button?.title = "GIF"
        status.button?.imagePosition = .imageLeading
        status.button?.setAccessibilityLabel("snap-gif")
        status.button?.toolTip = "snap-gif · \(state)"
        let menu = NSMenu()
        let statusRow = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())
        let screenshot = menu.addItem(withTitle: "\(Action.screenshot.title)    \(shortcut(.screenshot).label)",
                                       action: #selector(captureScreenshot), keyEquivalent: "")
        screenshot.target = self
        overlay?.update(recording: recording, stopping: pausedAt != nil)
        let gifTitle = recording ? "停止录制" : (readyToRecord ? "开始录制" :
            (pendingGIF == nil ? Action.gif.title : "只复制 GIF"))
        controlStatus?.stringValue = state
        controlScreenshot?.title = "截图  \(shortcut(.screenshot).label)"
        controlScreenshot?.isEnabled = !busy && pendingGIF == nil
        storageButton?.isEnabled = !busy
        controlGIF?.title = "\(gifTitle)  \(shortcut(.gif).label)"
        controlGIF?.isEnabled = (!busy || recording || readyToRecord) && pausedAt == nil
        let gif = menu.addItem(withTitle: "\(gifTitle)    \(shortcut(.gif).label)",
                                action: #selector(captureGIF), keyEquivalent: "")
        gif.target = self
        menu.autoenablesItems = false
        screenshot.isEnabled = !busy && pendingGIF == nil
        gif.isEnabled = (!busy || recording || readyToRecord) && pausedAt == nil
        if pendingGIF != nil && !busy {
            let discard = menu.addItem(withTitle: "丢弃本次录制", action: #selector(discardGIF), keyEquivalent: "")
            discard.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开 snap-gif", action: #selector(showControls), keyEquivalent: "").target = self
        menu.addItem(withTitle: "快捷键设置…", action: #selector(showSettings), keyEquivalent: "").target = self
        let update = menu.addItem(withTitle: checkingUpdate ? "正在检查更新…" : "检查更新…",
                                  action: #selector(checkUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = !busy && pendingGIF == nil && !checkingUpdate && !updateInstalling
        controlUpdate?.title = update.title
        controlUpdate?.isEnabled = update.isEnabled
        menu.addItem(withTitle: "退出 snap-gif", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        if availableUpdate != nil && canPresentUpdate {
            DispatchQueue.main.async { [weak self] in self?.offerUpdate() }
        }
    }

    @objc private func checkUpdates() {
        if !NSApp.isActive || controls?.isKeyWindow != true { showControls() }
        startUpdateCheck(manual: true)
    }

    private func startUpdateCheck(manual: Bool) {
        guard !checkingUpdate, !updateInstalling, availableUpdate == nil else { return }
        checkingUpdate = true
        refresh()
        Task {
            defer { checkingUpdate = false; refresh() }
            do {
                let result = try await Task.detached {
                    let updater = ReleaseUpdater()
                    return (updater, try await updater.latest())
                }.value
                if let release = result.1 {
                    if manual || UserDefaults.standard.string(forKey: declinedUpdateKey) != release.tag_name {
                        availableUpdate = (result.0, release)
                    }
                } else if manual {
                    state = "已是最新版本"
                }
            } catch {
                if manual { state = "检查更新失败，请重试" }
            }
        }
    }

    private var canPresentUpdate: Bool {
        NSApp.isActive && controls?.isKeyWindow == true && controls?.attachedSheet == nil &&
            !busy && pendingGIF == nil && editing == nil && overlay?.isComplete != true
    }

    private func offerUpdate() {
        guard canPresentUpdate, let controls, let (updater, release) = availableUpdate else { return }
        availableUpdate = nil
        busy = true
        refresh()
        let alert = NSAlert()
        alert.messageText = "发现 snap-gif \(release.version)"
        alert.informativeText = "下载并安装后，snap-gif 会自动重新打开。"
        alert.addButton(withTitle: "是，下载并安装")
        let decline = alert.addButton(withTitle: "否，暂不更新")
        decline.keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: controls) { [weak self] outcome in
            guard let self else { return }
            guard outcome == .alertFirstButtonReturn else {
                UserDefaults.standard.set(release.tag_name, forKey: declinedUpdateKey)
                busy = false
                refresh()
                return
            }
            installUpdate(updater, release: release)
        }
    }

    private func installUpdate(_ updater: ReleaseUpdater, release: GitHubRelease) {
        updateInstalling = true
        state = "正在下载并安装 \(release.version)…"
        refresh()
        Task {
            do {
                try await Task.detached { try await updater.install(release) }.value
                try updater.relaunchAfterExit()
                NSApp.terminate(nil)
            } catch {
                updateInstalling = false
                busy = false
                state = "更新未完成"
                refresh()
                showAlert("无法完成更新", error.localizedDescription)
            }
        }
    }

    @objc private func captureScreenshot() { perform(.screenshot) }
    @objc private func captureGIF() { perform(.gif) }

    private func perform(_ action: Action) {
        guard editing == nil else { return }
        if recording, action == .gif, pausedAt == nil {
            pausedAt = ProcessInfo.processInfo.systemUptime
            state = "已停止 · 正在生成 GIF"
            refresh()
            return
        }
        if action == .gif, readyToRecord {
            startSelectedRecording?()
            return
        }
        if action == .gif, pendingGIF != nil, !busy {
            resolvePendingGIF(save: false)
            return
        }
        guard !busy, pendingGIF == nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        guard let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        overlay?.close()
        overlay = nil
        busy = true
        let returnToControls = NSApp.isActive && controls?.isVisible == true
        controls?.orderOut(nil)
        state = "正在框选"
        refresh()
        let window = SelectionWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.hidesOnDeactivate = false
        window.isRestorable = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window.contentView = view
        view.finish = { [weak self] region in
            guard let self else { return }
            selection?.orderOut(nil)
            selection = nil
            if let region {
                if action == .gif {
                    prepareRecording(region: region, screen: screen, display: display,
                                     returnToControls: returnToControls)
                } else {
                    Task { await self.capture(action, display: display, region: region,
                                              scale: screen.backingScaleFactor, returnToControls: returnToControls) }
                }
            } else {
                busy = false
                state = "已取消"
                refresh()
            }
        }
        selection = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func prepareRecording(region: CGRect, screen: NSScreen, display: CGDirectDisplayID,
                                  returnToControls: Bool) {
        overlay = RecordingOverlay(region: region, screen: screen, action: { [weak self] in
            self?.perform(.gif)
        }, cancel: { [weak self] in
            guard let self else { return }
            cancelRecordingOverlay()
        })
        startSelectedRecording = { [weak self] in
            guard let self else { return }
            pausedAt = nil
            discardRecording = false
            recording = true
            state = "正在录制 GIF · 最长 15 秒"
            refresh()
            Task { await self.capture(.gif, display: display, region: region,
                                      scale: screen.backingScaleFactor, returnToControls: returnToControls) }
        }
        state = "区域已选定 · 等待开始"
        refresh()
        overlay?.show()
    }

    private func cancelRecordingOverlay() {
        if recording {
            guard pausedAt == nil else { return }
            discardRecording = true
            pausedAt = ProcessInfo.processInfo.systemUptime
            state = "已丢弃录制"
            overlay?.close()
            refresh()
        } else if pendingGIF != nil {
            discardGIF()
        } else {
            busy = false
            closeGIFOverlay(status: "已取消")
        }
    }

    @objc private func discardGIF() {
        guard pendingGIF != nil && !busy else { return }
        pendingGIF = nil
        closeGIFOverlay(status: "已丢弃录制")
    }

    private func closeGIFOverlay(status: String) {
        overlay?.close()
        overlay = nil
        startSelectedRecording = nil
        state = status
        refresh()
    }

    private func prepareNextClip(status: String) {
        guard let overlay, startSelectedRecording != nil else {
            closeGIFOverlay(status: status)
            return
        }
        busy = true
        state = status
        overlay.prepareNextClip()
        refresh()
    }

    private func resolvePendingGIF(save: Bool) {
        guard let data = pendingGIF, !busy else { return }
        if save {
            let file: URL
            do {
                file = try gifStore.save(data)
            } catch {
                showAlert("无法保存 GIF", error.localizedDescription)
                return
            }
            pendingGIF = nil
            do {
                try copyCapture(data, gifFile: file)
                prepareNextClip(status: "GIF 已保存并复制 · 可录下一段")
            } catch {
                prepareNextClip(status: "GIF 已保存 · 可在图库复制")
                showAlert("GIF 已保存，但复制失败", error.localizedDescription)
            }
            // Restore the recording controls before decoding the new library preview.
            DispatchQueue.main.async { [weak self] in
                self?.libraryView?.reload(select: file)
            }
        } else {
            do {
                try copyGIFWithoutSaving(data)
                pendingGIF = nil
                prepareNextClip(status: "已复制 GIF · 可录下一段")
            } catch {
                showAlert("无法复制 GIF", error.localizedDescription)
            }
        }
    }

    private func capture(_ action: Action, display: CGDirectDisplayID, region: CGRect, scale: CGFloat,
                         returnToControls: Bool) async {
        defer {
            let wasDiscarded = discardRecording
            recording = false
            pausedAt = nil
            discardRecording = false
            busy = false
            if overlay?.isComplete == true {
                refresh()
            } else {
                overlay?.close()
                overlay = nil
                startSelectedRecording = nil
                if !wasDiscarded && returnToControls && NSApp.isActive { presentControls(activate: false) } else { refresh() }
            }
        }
        let gif = action == .gif
        let options = GIFRecordingSettings()
        do {
            try await Task.sleep(for: .milliseconds(160))
            guard !discardRecording else { return }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !discardRecording else { return }
            guard let screen = content.displays.first(where: { $0.displayID == display }) else { throw CaptureError.display }
            let ownApplications = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            let filter = SCContentFilter(display: screen, excludingApplications: ownApplications,
                                         exceptingWindows: [])
            let config = SCStreamConfiguration()
            let ratio = gif ? options.outputScale(for: region, displayScale: scale) : scale
            config.sourceRect = region
            config.width = max(2, Int(region.width * ratio))
            config.height = max(2, Int(region.height * ratio))
            config.showsCursor = false
            if !gif {
                state = "正在截图"
                refresh()
            }
            let highRate = gif && options.fps >= 30
            let frames: [Frame]
            let end: TimeInterval
            if highRate {
                (frames, end) = try await captureHighRate(filter: filter, config: config, fps: options.fps)
            } else {
                var captured: [Frame] = []
                let start = ProcessInfo.processInfo.systemUptime
                repeat {
                    let time = ProcessInfo.processInfo.systemUptime - start
                    let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    if pausedAt == nil || captured.isEmpty {
                        captured.append(Frame(image: frame, time: time))
                    }
                    if gif && pausedAt == nil {
                        let remaining = options.frameInterval - (ProcessInfo.processInfo.systemUptime - start - time)
                        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                    }
                } while gif && pausedAt == nil && ProcessInfo.processInfo.systemUptime - start < 15
                frames = captured
                end = (pausedAt ?? ProcessInfo.processInfo.systemUptime) - start
            }
            guard !discardRecording else { return }
            recording = false
            if gif { pausedAt = ProcessInfo.processInfo.systemUptime }
            state = gif ? "录制结束 · 正在生成 GIF" : "正在复制到剪贴板"
            refresh()
            let data = try await Task.detached(priority: .userInitiated) { [frames] in
                try encode(frames, end: end, gif: gif, highRateFPS: highRate ? options.fps : nil)
            }.value
            if gif {
                pendingGIF = data
                state = "GIF 已生成 · 等待选择"
                overlay?.finish(details: GIFOutputDetails(data: data)?.summary, copy: { [weak self] in
                    self?.resolvePendingGIF(save: false)
                }, save: { [weak self] in
                    self?.resolvePendingGIF(save: true)
                })
            } else {
                try copyCapture(data)
                state = "截图已复制"
            }
        } catch {
            guard !discardRecording else { return }
            state = "捕获失败"
            overlay?.close()
            if (error as? SCStreamError)?.code == .userDeclined {
                showCapturePermissionAlert()
            } else {
                showAlert("无法完成捕获", error.localizedDescription)
            }
        }
    }

    private func captureHighRate(filter: SCContentFilter, config: SCStreamConfiguration,
                                 fps: Int) async throws -> ([Frame], TimeInterval) {
        let budget = HighRateCaptureBudget(width: config.width, height: config.height, fps: fps)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.colorSpaceName = CGColorSpace.sRGB
        let receiver = HighRateCapture(frameLimit: budget.frameLimit)
        let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
        try await stream.startCapture()
        let start = ProcessInfo.processInfo.systemUptime
        if !discardRecording {
            state = "正在录制 GIF · \(fps) fps · 最长 \(String(format: "%.1f", budget.duration)) 秒"
            refresh()
        }
        while !Task.isCancelled && pausedAt == nil && !receiver.didFinish &&
            ProcessInfo.processInfo.systemUptime - start < budget.duration {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let stopTime = pausedAt ?? ProcessInfo.processInfo.systemUptime
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(receiver, type: .screen)
        return try receiver.finish(at: stopTime)
    }

    private func showCapturePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "macOS 拒绝了屏幕采集"
        alert.informativeText = "申请时会清除 snap-gif 的旧录屏授权。请在 macOS 提示中允许录屏。"
        alert.addButton(withTitle: "申请录屏权限")
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\u{1b}"
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            resetScreenRecordingPermission()
        }
    }

    private func resetScreenRecordingPermission() {
        guard !resettingScreenRecordingPermission,
              let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else { return }
        resettingScreenRecordingPermission = true
        refreshPermissionButton()
        Task {
            defer {
                resettingScreenRecordingPermission = false
                refreshPermissionButton()
            }
            let reset = await Task.detached {
                let command = Process()
                command.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                command.arguments = ["reset", "ScreenCapture", identifier]
                command.standardOutput = FileHandle.nullDevice
                command.standardError = FileHandle.nullDevice
                do {
                    try command.run()
                    command.waitUntilExit()
                    return command.terminationStatus == 0
                } catch {
                    return false
                }
            }.value
            if !reset {
                showAlert("无法清除旧录屏授权",
                          "将继续申请权限。如果系统仍显示失效的旧条目，请在「录屏与系统录音」中点减号移除后再申请。")
            }
            requestScreenRecordingPermission(force: reset)
        }
    }

    private func showAlert(_ title: String, _ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    @objc private func showSettings() {
        if settings == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 174),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "snap-gif 快捷键"
            panel.isReleasedWhenClosed = false
            panel.isRestorable = false
            panel.hidesOnDeactivate = true
            panel.delegate = self
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            for action in Action.allCases {
                let label = NSTextField(labelWithString: action.title)
                let button = NSButton(title: shortcut(action).label, target: self, action: #selector(editShortcut(_:)))
                button.tag = Int(action.rawValue)
                button.setAccessibilityLabel("设置\(action.title)快捷键")
                button.widthAnchor.constraint(equalToConstant: 170).isActive = true
                let row = NSStackView(views: [label, NSView(), button])
                row.spacing = 12
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                buttons[action] = button
            }
            let help = NSTextField(wrappingLabelWithString: "可分别设置截图和 GIF 快捷键。点击按钮后按下新组合键，Esc 取消。请使用 ⌘、⌥ 或 ⌃ 加字母、数字等按键。")
            help.textColor = .secondaryLabelColor
            stack.addArrangedSubview(help)
            help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            guard let content = panel.contentView else { return }
            stack.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22)
            ])
            panel.center()
            settings = panel
        }
        NSApp.activate()
        updateShortcutButtons()
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc private func editShortcut(_ sender: NSButton) {
        guard let action = Action(rawValue: UInt32(sender.tag)) else { return }
        finishEditing()
        editing = action
        sender.title = "按下新快捷键"
        // Let the recorder receive shortcuts currently registered by either action.
        for reference in hotkeys.values { UnregisterEventHotKey(reference) }
        hotkeys.removeAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let action = editing else { return event }
            guard settings?.isKeyWindow == true else { finishEditing(); return event }
            if event.keyCode == kVK_Escape { finishEditing(); return nil }
            let flags = event.modifierFlags
            var modifiers: UInt32 = 0
            var label = ""
            for (flag, value, glyph) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"),
                                          (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"),
                                          (.command, cmdKey, "⌘")] where flags.contains(flag) {
                modifiers |= UInt32(value)
                label += glyph
            }
            guard !flags.intersection([.command, .option, .control]).isEmpty,
                  let key = event.characters(byApplyingModifiers: [])?.uppercased(),
                  key.count == 1, let scalar = key.unicodeScalars.first,
                  (33...126).contains(scalar.value) else {
                NSSound.beep()
                return nil
            }
            let candidate = Shortcut(key: UInt32(event.keyCode), modifiers: modifiers, label: label + key)
            let applied = applyShortcut(candidate, to: action)
            finishEditing()
            if !applied {
                showAlert("快捷键已被占用", "请选择另一个组合键，原设置已保留。")
            }
            return nil
        }
    }

    private func applyShortcut(_ candidate: Shortcut, to action: Action) -> Bool {
        let other = shortcut(action == .gif ? .screenshot : .gif)
        guard candidate.key != other.key || candidate.modifiers != other.modifiers,
              register(action, candidate) else { return false }
        UserDefaults.standard.set(["key": candidate.key, "modifiers": candidate.modifiers, "label": candidate.label],
                                  forKey: "shortcut.\(action.rawValue)")
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === controls {
            refresh()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if editing != nil { finishEditing() }
    }

    func windowWillClose(_ notification: Notification) {
        if editing != nil { finishEditing() }
    }

    private func updateShortcutButtons() {
        for action in Action.allCases where action != editing {
            let label = shortcut(action).label
            buttons[action]?.title = hotkeys[action] == nil ? "\(label) · 不可用" : label
        }
    }

    private func finishEditing() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if editing != nil {
            for action in Action.allCases where hotkeys[action] == nil {
                _ = register(action, shortcut(action))
            }
        }
        editing = nil
        updateShortcutButtons()
        refresh()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
