import AppKit
import UniformTypeIdentifiers

struct GIFStore {
    let directory: URL
    private static let preferenceKey = "gifStoragePath"

    static let local = GIFStore(directory: URL.applicationSupportDirectory
        .appending(path: "snap-gif", directoryHint: .isDirectory)
        .appending(path: "GIFs", directoryHint: .isDirectory))

    static func preferred(defaults: UserDefaults = .standard) -> GIFStore {
        guard let path = defaults.string(forKey: preferenceKey), !path.isEmpty else { return .local }
        return GIFStore(directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    static func select(_ directory: URL, defaults: UserDefaults = .standard) throws -> GIFStore {
        let store = GIFStore(directory: directory.standardizedFileURL)
        let folder = try store.preparedDirectory()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSURLErrorKey: folder])
        }
        defaults.set(folder.path, forKey: preferenceKey)
        return store
    }

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
func copyCapture(_ data: Data, gifFile: URL? = nil, to pasteboard: NSPasteboard = .general) throws {
    let item = NSPasteboardItem()
    let type: NSPasteboard.PasteboardType = gifFile == nil ? .png : .init(UTType.gif.identifier)
    guard item.setData(data, forType: type) else { throw CaptureError.clipboard }
    if let gifFile {
        guard item.setString(gifFile.absoluteString, forType: .fileURL) else {
            throw CaptureError.clipboard
        }
    }
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else { throw CaptureError.clipboard }
}

@MainActor
func copyGIFWithoutSaving(_ data: Data, to pasteboard: NSPasteboard = .general,
                          directory: URL = URL.cachesDirectory.appending(path: "snap-gif/Clipboard")) throws {
    // The file representation must survive after the overlay closes, including for a later paste.
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appending(path: "snap-gif-copy-\(UUID().uuidString).gif")
    try data.write(to: file, options: .atomic)
    do {
        try copyCapture(data, gifFile: file, to: pasteboard)
    } catch {
        try? manager.removeItem(at: file)
        throw error
    }
    if let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        let prefix = "snap-gif-copy-"
        for old in files where old.lastPathComponent != file.lastPathComponent && old.pathExtension == "gif" &&
            old.lastPathComponent.hasPrefix(prefix) &&
            UUID(uuidString: String(old.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))) != nil {
            try? manager.removeItem(at: old)
        }
    }
}

@MainActor
final class GIFLibraryView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private var store: GIFStore
    private let table = NSTableView()
    private let preview = NSImageView()
    private let emptyPreview: NSStackView = {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .regular))
        symbol.contentTintColor = .secondaryLabelColor
        symbol.setAccessibilityElement(false)
        let message = NSTextField(labelWithString: "没有可预览的 GIF")
        message.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [symbol, message])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        return stack
    }()
    private let playback = NSButton(title: "暂停预览", target: nil, action: nil)
    private let caption = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
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
        table.rowHeight = 30
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 248).isActive = true
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        preview.setAccessibilityLabel("GIF 预览")
        let previewContent = NSView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        emptyPreview.translatesAutoresizingMaskIntoConstraints = false
        previewContent.addSubview(preview)
        previewContent.addSubview(emptyPreview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewContent.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewContent.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewContent.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewContent.bottomAnchor),
            emptyPreview.centerXAnchor.constraint(equalTo: previewContent.centerXAnchor),
            emptyPreview.centerYAnchor.constraint(equalTo: previewContent.centerYAnchor)
        ])
        let previewSurface = InsetSurface(previewContent, padding: 12)
        let browser = NSStackView(views: [scroll, previewSurface])
        browser.spacing = 16
        browser.alignment = .top
        browser.heightAnchor.constraint(equalToConstant: 200).isActive = true
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalTo: browser.heightAnchor),
            previewSurface.heightAnchor.constraint(equalTo: browser.heightAnchor),
            previewSurface.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])

        copyButton.target = self
        copyButton.action = #selector(copySelected)
        exportButton.target = self
        exportButton.action = #selector(exportSelected)
        deleteButton.target = self
        deleteButton.action = #selector(trashSelected)
        playback.target = self
        playback.action = #selector(togglePlayback)
        playback.setContentHuggingPriority(.required, for: .horizontal)
        let actions = NSStackView(views: [copyButton, exportButton, deleteButton, NSView(), playback])
        actions.spacing = 8
        caption.textColor = .secondaryLabelColor
        details.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let metadata = NSStackView(views: [details, NSView(), caption])
        metadata.alignment = .firstBaseline
        metadata.spacing = 10
        let inner = NSStackView(views: [browser, metadata, actions])
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
            browser.widthAnchor.constraint(equalTo: inner.widthAnchor),
            metadata.widthAnchor.constraint(equalTo: inner.widthAnchor),
            actions.widthAnchor.constraint(equalTo: inner.widthAnchor)
        ])
        reload()
    }

    required init?(coder: NSCoder) { nil }

    func useStore(_ store: GIFStore) {
        self.store = store
        reload()
    }

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
        preview.isHidden = preview.image == nil
        emptyPreview.isHidden = preview.image != nil
        playback.isEnabled = preview.image != nil
        playback.title = preview.animates ? "暂停预览" : "播放预览"
        details.stringValue = file.flatMap { GIFOutputDetails(file: $0)?.summary } ?? ""
        details.isHidden = file == nil
        [copyButton, exportButton, deleteButton].forEach { $0.isEnabled = file != nil }
        caption.stringValue = entries.isEmpty ? "还没有 GIF。完成首次录制后会自动保存在这里。" :
            "显示最近 \(entries.count) 条 · 共 \(totalCount) 个 GIF"
    }

    @objc private func togglePlayback() {
        preview.animates.toggle()
        playback.title = preview.animates ? "暂停预览" : "播放预览"
    }

    @objc private func copySelected() {
        guard let file = selected else { return }
        do {
            try copyCapture(Data(contentsOf: file), gifFile: file)
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
