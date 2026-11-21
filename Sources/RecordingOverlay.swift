import AppKit

@MainActor
final class RecordingOverlay: NSObject {
    private let outline: NSWindow
    private let panel: NSPanel
    private let actionButton: NSButton
    private let cancelButton: NSButton
    private let label = NSTextField(labelWithString: "准备录制")
    private let onAction: () -> Void
    private let onCancel: () -> Void
    private var onCopy: (() -> Bool)?
    private var onDone: (() -> Void)?
    private var completionDetails: String?
    var isComplete: Bool { onDone != nil }

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
        let size = CGSize(width: 424, height: 46)
        let x = min(max(rect.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        let below = rect.minY - size.height - 10
        let above = rect.maxY + 10
        let y = below >= visible.minY ? below : min(above, visible.maxY - size.height)
        panel = NSPanel(contentRect: CGRect(x: x, y: y, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.title = "GIF 录制控制"
        onAction = action
        onCancel = cancel

        actionButton = NSButton(title: "开始", target: nil, action: nil)
        cancelButton = NSButton(title: "取消", target: nil, action: nil)
        super.init()
        actionButton.target = self
        actionButton.action = #selector(performAction)
        cancelButton.target = self
        cancelButton.action = #selector(performCancel)
        actionButton.bezelColor = .systemIndigo
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, space, cancelButton, actionButton])
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
        actionButton.title = recording ? "停止并保存" : "开始"
        actionButton.isEnabled = !stopping
        cancelButton.isHidden = recording || stopping
        outline.contentView?.layer?.borderColor = (recording ? NSColor.systemRed : .systemBlue).cgColor
    }

    func finish(details: String?, copy: @escaping () -> Bool, done: @escaping () -> Void) {
        onCopy = copy
        onDone = done
        completionDetails = details
        updateCompletionLabel("已保存")
        actionButton.title = "复制 GIF"
        actionButton.isEnabled = true
        cancelButton.title = "完成"
        cancelButton.isHidden = false
        outline.contentView?.layer?.borderColor = NSColor.systemBlue.cgColor
    }

    private func updateCompletionLabel(_ status: String) {
        label.stringValue = completionDetails.map { "\(status) · \($0)" } ?? status
    }

    func close() {
        panel.orderOut(nil)
        outline.orderOut(nil)
    }

    @objc private func performAction() {
        if let onCopy {
            if onCopy() { updateCompletionLabel("已复制") }
        } else {
            onAction()
        }
    }

    @objc private func performCancel() {
        if let onDone { onDone() } else { onCancel() }
    }
}
