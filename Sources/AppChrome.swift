import AppKit

@MainActor
final class InsetSurface: NSView {
    private let fill: NSColor
    private let radius: CGFloat

    init(_ content: NSView, padding: CGFloat = 16, radius: CGFloat = 12,
         fill: NSColor = .controlBackgroundColor) {
        self.fill = fill
        self.radius = radius
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
func symbolButton(_ title: String, symbol: String, target: AnyObject?, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    button.imagePosition = .imageLeading
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}
