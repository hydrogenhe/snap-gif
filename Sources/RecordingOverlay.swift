import AppKit

private final class RecordingToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RecordingToolbarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class RecordingOverlay: NSObject {
    private let outline: NSWindow
    private let panel: NSPanel
    private let actionButton: NSButton
    private let cancelButton: NSButton
    private let saveButton: NSButton
    private let label = NSTextField(labelWithString: "准备录制")
    private let onAction: () -> Void
    private let onCancel: () -> Void
    private var onCopy: (() -> Void)?
    private var onSave: (() -> Void)?
    var isComplete: Bool { onCopy != nil }

    init(region: CGRect, screen: NSScreen, action: @escaping () -> Void, cancel: @escaping () -> Void) {
        let rect = CGRect(x: screen.frame.minX + region.minX,
                          y: screen.frame.maxY - region.maxY,
                          width: region.width, height: region.height)
        outline = NSWindow(contentRect: rect.insetBy(dx: -2, dy: -2), styleMask: .borderless,
                           backing: .buffered, defer: false)
        outline.isOpaque = false
        outline.backgroundColor = .clear
        outline.hasShadow = false
        outline.ignoresMouseEvents = true
        outline.level = .floating
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        outline.sharingType = .none
        let border = NSView(frame: CGRect(origin: .zero, size: outline.frame.size))
        border.wantsLayer = true
        border.layer?.borderWidth = 2
        border.layer?.borderColor = NSColor.systemBlue.cgColor
        outline.contentView = border

        let visible = screen.visibleFrame
        let size = CGSize(width: min(492, visible.width), height: 46)
        let x = min(max(rect.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let below = rect.minY - size.height - 10
        let above = rect.maxY + 10
        let y = below >= visible.minY ? below : min(above, visible.maxY - size.height)
        panel = RecordingToolbarPanel(contentRect: CGRect(x: x, y: y, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.title = "GIF 录制控制"
        onAction = action
        onCancel = cancel

        actionButton = RecordingToolbarButton(title: "开始", target: nil, action: nil)
        cancelButton = RecordingToolbarButton(title: "取消", target: nil, action: nil)
        saveButton = RecordingToolbarButton(title: "保存并复制", target: nil, action: nil)
        super.init()
        actionButton.target = self
        actionButton.action = #selector(performAction)
        cancelButton.target = self
        cancelButton.action = #selector(performCancel)
        saveButton.target = self
        saveButton.action = #selector(performSave)
        saveButton.isHidden = true
        actionButton.bezelColor = .systemIndigo
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, space, cancelButton, saveButton, actionButton])
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        let surface = InsetSurface(row, padding: 9, radius: 10)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = surface
    }

    func show() {
        outline.orderFrontRegardless()
        panel.orderFrontRegardless()
    }

    func update(recording: Bool, stopping: Bool) {
        guard !isComplete else { return }
        label.stringValue = stopping ? "正在生成 GIF" : (recording ? "正在录制" : "准备录制")
        actionButton.title = recording ? "停止" : "开始"
        actionButton.isEnabled = !stopping
        cancelButton.title = recording ? "停止并丢弃" : "取消"
        cancelButton.isHidden = stopping
        outline.contentView?.layer?.borderColor = (recording ? NSColor.systemRed : .systemBlue).cgColor
    }

    func finish(details: String?, copy: @escaping () -> Void, save: @escaping () -> Void) {
        onCopy = copy
        onSave = save
        label.stringValue = details ?? "GIF 已生成"
        actionButton.title = "只复制"
        actionButton.isEnabled = true
        cancelButton.title = "丢弃"
        cancelButton.isHidden = false
        saveButton.isHidden = false
        outline.contentView?.layer?.borderColor = NSColor.systemBlue.cgColor
    }

    func close() {
        panel.orderOut(nil)
        outline.orderOut(nil)
    }

    @objc private func performAction() {
        if let onCopy { onCopy() } else { onAction() }
    }

    @objc private func performCancel() { onCancel() }
    @objc private func performSave() { onSave?() }
}
