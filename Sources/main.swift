import AppKit
import Carbon
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

final class SelectionWindow: NSWindow {
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

func encode(_ frames: [Frame], end: TimeInterval, gif: Bool) throws -> Data {
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
    for (index, frame) in frames.enumerated() {
        let next = index + 1 < frames.count ? frames[index + 1].time : end
        let props: CFDictionary? = gif ? [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: max(0.02, next - frame.time)
        ]] as CFDictionary : nil
        CGImageDestinationAddImage(output, frame.image, props)
    }
    guard CGImageDestinationFinalize(output) else { throw CaptureError.encoding }
    return bytes as Data
}

@MainActor
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
    private var pendingGIF: Data?
    private var updateTimer: Timer?
    private var checkingUpdate = false
    private var updateInstalling = false
    private var availableUpdate: (ReleaseUpdater, GitHubRelease)?
    private let signature: OSType = 0x53474946

    func applicationDidFinishLaunching(_ notification: Notification) {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
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
        let unavailable = Action.allCases.filter { !register($0, shortcut($0)) }
        if !unavailable.isEmpty { state = "部分快捷键不可用，请在设置中修改" }
        refresh()
        startUpdateCheck(manual: false)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startUpdateCheck(manual: false) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
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
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.key, shortcut.modifiers,
                                         EventHotKeyID(signature: signature, id: action.rawValue),
                                         GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else { return false }
        hotkeys[action] = reference
        return true
    }

    private func refresh() {
        let symbol = recording ? "record.circle.fill" : (pendingGIF == nil ? "viewfinder" : "pause.circle")
        status.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "snap-gif")
        status.button?.toolTip = "snap-gif · \(state)"
        let menu = NSMenu()
        let statusRow = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())
        let screenshot = menu.addItem(withTitle: "\(Action.screenshot.title)    \(shortcut(.screenshot).label)",
                                       action: #selector(captureScreenshot), keyEquivalent: "")
        screenshot.target = self
        let gifTitle = recording ? "暂停录制" : (pendingGIF == nil ? Action.gif.title : "保存 GIF…")
        let gif = menu.addItem(withTitle: "\(gifTitle)    \(shortcut(.gif).label)",
                                action: #selector(captureGIF), keyEquivalent: "")
        gif.target = self
        menu.autoenablesItems = false
        screenshot.isEnabled = !busy
        gif.isEnabled = (!busy || recording) && pausedAt == nil
        if pendingGIF != nil && !busy {
            let discard = menu.addItem(withTitle: "丢弃本次录制", action: #selector(discardGIF), keyEquivalent: "")
            discard.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "快捷键设置…", action: #selector(showSettings), keyEquivalent: "").target = self
        let update = menu.addItem(withTitle: checkingUpdate ? "正在检查更新…" : "检查更新…",
                                  action: #selector(checkUpdates), keyEquivalent: "")
        update.target = self
        update.isEnabled = !busy && pendingGIF == nil && !checkingUpdate && !updateInstalling
        menu.addItem(withTitle: "退出 snap-gif", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        if availableUpdate != nil && !busy && pendingGIF == nil && editing == nil {
            DispatchQueue.main.async { [weak self] in self?.offerUpdate() }
        }
    }

    @objc private func checkUpdates() { startUpdateCheck(manual: true) }

    private func startUpdateCheck(manual: Bool) {
        guard !checkingUpdate, !updateInstalling, availableUpdate == nil else { return }
        checkingUpdate = true
        refresh()
        Task {
            defer { checkingUpdate = false; refresh() }
            do {
                let result = try await Task.detached {
                    let updater = try ReleaseUpdater()
                    return (updater, try updater.latest())
                }.value
                if let release = result.1 {
                    availableUpdate = (result.0, release)
                } else if manual {
                    showAlert("已是最新版本", "当前没有可用的新版。")
                }
            } catch {
                if manual { showAlert("无法检查更新", error.localizedDescription) }
            }
        }
    }

    private func offerUpdate() {
        guard !busy, pendingGIF == nil, editing == nil,
              let (updater, release) = availableUpdate else { return }
        availableUpdate = nil
        busy = true
        refresh()
        let alert = NSAlert()
        alert.messageText = "发现 snap-gif \(release.version)"
        alert.informativeText = "下载并安装后，snap-gif 会自动重新打开。"
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "稍后")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            busy = false
            refresh()
            return
        }

        updateInstalling = true
        state = "正在下载并安装 \(release.version)…"
        refresh()
        Task {
            do {
                try await Task.detached { try updater.install(release) }.value
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
            state = "已暂停 · 正在生成 GIF"
            refresh()
            return
        }
        if action == .gif, pendingGIF != nil, !busy {
            saveGIF()
            return
        }
        guard !busy, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            showAlert("需要屏幕录制权限", "在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」允许 snap-gif，然后重新打开应用。")
            return
        }
        guard let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        busy = true
        state = "正在框选"
        refresh()
        let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless,
                                     backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
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
                Task { await self.capture(action, display: display, region: region, scale: screen.backingScaleFactor) }
            } else {
                busy = false
                state = "已取消"
                refresh()
            }
        }
        selection = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    @objc private func discardGIF() {
        guard pendingGIF != nil, !busy else { return }
        pendingGIF = nil
        state = "已丢弃录制"
        refresh()
    }

    private func saveGIF() {
        guard let data = pendingGIF else { return }
        busy = true
        refresh()
        defer { busy = false; refresh() }

        let panel = NSSavePanel()
        panel.title = "保存录制"
        panel.allowedContentTypes = [.gif]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "snap-gif \(formatter.string(from: Date())).gif"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try savePendingGIF(data, to: url)
        } catch {
            showAlert("无法保存 GIF", error.localizedDescription)
        }
    }

    private func savePendingGIF(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        pendingGIF = nil
        state = "已保存 \(url.lastPathComponent)"
    }

    private func capture(_ action: Action, display: CGDirectDisplayID, region: CGRect, scale: CGFloat) async {
        defer { recording = false; pausedAt = nil; busy = false; refresh() }
        let gif = action == .gif
        do {
            try await Task.sleep(for: .milliseconds(160))
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let screen = content.displays.first(where: { $0.displayID == display }) else { throw CaptureError.display }
            let filter = SCContentFilter(display: screen, excludingWindows: [])
            let config = SCStreamConfiguration()
            let ratio = gif ? min(scale, 720 / max(region.width, region.height)) : scale
            config.sourceRect = region
            config.width = max(2, Int(region.width * ratio))
            config.height = max(2, Int(region.height * ratio))
            config.showsCursor = false
            pausedAt = nil
            recording = gif
            state = gif ? "正在录制 GIF · 最长 15 秒" : "正在截图"
            refresh()
            var frames: [Frame] = []
            let start = ProcessInfo.processInfo.systemUptime
            repeat {
                let time = ProcessInfo.processInfo.systemUptime - start
                let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if pausedAt == nil || frames.isEmpty {
                    frames.append(Frame(image: frame, time: time))
                }
                if gif && pausedAt == nil {
                    let remaining = 0.125 - (ProcessInfo.processInfo.systemUptime - start - time)
                    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                }
            } while gif && pausedAt == nil && ProcessInfo.processInfo.systemUptime - start < 15
            let end = (pausedAt ?? ProcessInfo.processInfo.systemUptime) - start
            recording = false
            state = gif ? "已暂停 · 正在生成 GIF" : "正在复制到剪贴板"
            refresh()
            let data = try await Task.detached(priority: .userInitiated) { [frames] in
                try encode(frames, end: end, gif: gif)
            }.value
            if gif { pendingGIF = data }
            let item = NSPasteboardItem()
            let type: NSPasteboard.PasteboardType = gif ? .init(UTType.gif.identifier) : .png
            guard item.setData(data, forType: type) else { throw CaptureError.clipboard }
            if gif, let first = frames.first {
                let preview = try? encode([first], end: 0, gif: false)
                if let preview { item.setData(preview, forType: .png) }
            }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([item]) else { throw CaptureError.clipboard }
            state = gif ? "已暂停 · GIF 已复制，可保存" : "截图已复制"
        } catch {
            state = pendingGIF != nil ? "GIF 可保存" : "捕获失败"
            showAlert("无法完成捕获", error.localizedDescription)
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
            let help = NSTextField(wrappingLabelWithString: "点击快捷键后按下新组合键，Esc 取消。录制时按 GIF 快捷键暂停，再按一次保存。")
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
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc private func editShortcut(_ sender: NSButton) {
        guard let action = Action(rawValue: UInt32(sender.tag)) else { return }
        finishEditing()
        editing = action
        sender.title = "按下新快捷键"
        if let reference = hotkeys.removeValue(forKey: action) { UnregisterEventHotKey(reference) }
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
            guard register(action, candidate) else {
                finishEditing()
                showAlert("快捷键已被占用", "请选择另一个组合键。")
                return nil
            }
            UserDefaults.standard.set(["key": candidate.key, "modifiers": candidate.modifiers, "label": candidate.label],
                                      forKey: "shortcut.\(action.rawValue)")
            finishEditing()
            refresh()
            return nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        finishEditing()
    }

    private func finishEditing() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let action = editing {
            if hotkeys[action] == nil { _ = register(action, shortcut(action)) }
            buttons[action]?.title = shortcut(action).label
        }
        editing = nil
        refresh()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
