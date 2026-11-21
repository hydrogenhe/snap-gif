import AppKit
import ImageIO
import UniformTypeIdentifiers

struct GIFStore {
    let directory: URL

    static let local = GIFStore(directory: URL.applicationSupportDirectory
        .appending(path: "snap-gif", directoryHint: .isDirectory)
        .appending(path: "GIFs", directoryHint: .isDirectory))

    func entries() throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: preparedDirectory(),
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        return files.compactMap { file -> (url: URL, date: Date)? in
            guard file.pathExtension.lowercased() == "gif",
                  let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (file, values.creationDate ?? values.contentModificationDate ?? .distantPast)
        }.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.url.lastPathComponent.compare(rhs.url.lastPathComponent, options: .numeric) == .orderedDescending
        }.map(\.url)
    }

    func save(_ data: Data) throws -> URL {
        let directory = try preparedDirectory()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let prefix = "GIF \(formatter.string(from: Date()))"
        var file = directory.appending(path: "\(prefix).gif")
        var suffix = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = directory.appending(path: "\(prefix) (\(suffix)).gif")
            suffix += 1
        }
        try data.write(to: file, options: .atomic)
        return file
    }

    func trash(_ file: URL) throws {
        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
    }

    func preparedDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
func copyCapture(_ data: Data, gif: Bool, to pasteboard: NSPasteboard = .general) throws {
    let item = NSPasteboardItem()
    guard item.setData(data, forType: gif ? .init(UTType.gif.identifier) : .png)
    else { throw CaptureError.clipboard }
    if gif, let source = CGImageSourceCreateWithData(data as CFData, nil),
       let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
       let preview = try? encode([Frame(image: image, time: 0)], end: 0, gif: false) {
        item.setData(preview, forType: .png)
    }
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { throw CaptureError.clipboard }
}

@MainActor
final class GIFLibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: GIFStore
    private let table = NSTableView()
    private let preview = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "复制 GIF", target: nil, action: nil)
    private let exportButton = NSButton(title: "另存为…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "移到废纸篓", target: nil, action: nil)
    private var entries: [URL] = []
    private var totalCount = 0
    private var selected: URL? { entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil }

    init(store: GIFStore) {
        self.store = store
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("gif"))
        column.title = "录制文件"
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 210).isActive = true
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.animates = true
        preview.setAccessibilityLabel("GIF 预览")
        let browser = NSStackView(views: [scroll, preview])
        browser.spacing = 16
        browser.alignment = .top
        browser.heightAnchor.constraint(equalToConstant: 180).isActive = true
        preview.heightAnchor.constraint(equalTo: browser.heightAnchor).isActive = true

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        exportButton.target = self
        exportButton.action = #selector(exportSelected)
        deleteButton.target = self
        deleteButton.action = #selector(trashSelected)
        let actions = NSStackView(views: [copyButton, exportButton, deleteButton])
        actions.spacing = 8
        caption.textColor = .secondaryLabelColor
        let inner = NSStackView(views: [browser, actions, caption])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: topAnchor),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor),
            browser.widthAnchor.constraint(equalTo: inner.widthAnchor)
        ])
        reload()
    }

    required init?(coder: NSCoder) { nil }

    func reload(select file: URL? = nil) {
        let previous = file ?? selected
        do {
            let files = try store.entries()
            totalCount = files.count
            entries = Array(files.prefix(10))
        } catch {
            entries = []
            totalCount = 0
            table.reloadData()
            updateSelection()
            caption.stringValue = "无法读取图库 · \(error.localizedDescription)"
            return
        }
        table.reloadData()
        if let previous, let row = entries.firstIndex(of: previous) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else if !entries.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: entries[row].deletingPathExtension().lastPathComponent)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

    private func updateSelection() {
        let file = selected
        preview.image = file.flatMap { NSImage(contentsOf: $0) }
        [copyButton, exportButton, deleteButton].forEach { $0.isEnabled = file != nil }
        caption.stringValue = entries.isEmpty ? "还没有 GIF。完成首次录制后会自动保存在这里。" :
            "显示最近 \(entries.count) 条 · 共 \(totalCount) 个 GIF"
    }

    @objc private func copySelected() {
        guard let file = selected else { return }
        do {
            try copyCapture(Data(contentsOf: file), gif: true)
            caption.stringValue = "GIF 已复制"
        } catch {
            showError("无法复制 GIF", error)
        }
    }

    @objc private func exportSelected() {
        guard let file = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = file.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(contentsOf: file).write(to: destination, options: .atomic)
            caption.stringValue = "已另存为 \(destination.lastPathComponent)"
        } catch {
            showError("无法导出 GIF", error)
        }
    }

    @objc private func trashSelected() {
        guard let file = selected else { return }
        do {
            try store.trash(file)
            reload()
            caption.stringValue = "已移到废纸篓"
        } catch {
            showError("无法移到废纸篓", error)
        }
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }
}
