import AllspotCore
import AppKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// 결과 목록. 수백만 줄도 보이는 줄만 그리도록 NSTableView를 그대로 쓴다.
struct ResultsTableView: NSViewRepresentable {
    @ObservedObject var model: SearchModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsNSTableView()
        table.model = model
        table.style = .fullWidth
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.intercellSpacing = NSSize(width: 6, height: 0)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortKey.rawValue, ascending: true)
            if column == .size {
                tableColumn.headerCell.alignment = .right
            }
            table.addTableColumn(tableColumn)
        }
        table.autosaveName = "AllspotResultColumns"
        table.autosaveTableColumns = true
        table.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)]

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menu = context.coordinator.makeMenu(for: table)
        model.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.reloadIfNeeded(table)
    }

    enum Column: String, CaseIterable {
        case name, path, size, modified

        var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
        var title: String {
            switch self {
            case .name: return "이름"
            case .path: return "경로"
            case .size: return "크기"
            case .modified: return "수정한 날짜"
            }
        }
        var width: CGFloat {
            switch self {
            case .name: return 300
            case .path: return 420
            case .size: return 90
            case .modified: return 140
            }
        }
        var sortKey: SortKey {
            switch self {
            case .name: return .name
            case .path: return .path
            case .size: return .size
            case .modified: return .modified
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: SearchModel
        private var shownVersion = -1
        private let icons = IconCache()

        static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f
        }()
        static let sizeFormatter: ByteCountFormatter = {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return f
        }()

        init(model: SearchModel) { self.model = model }

        func reloadIfNeeded(_ table: NSTableView) {
            guard shownVersion != model.resultsVersion else { return }
            shownVersion = model.resultsVersion
            // 결과가 바뀌어도 고른 항목은 그대로 고른 채 둔다.
            let selectedIds = Set(table.selectedRowIndexes.prefix(50).compactMap { row in
                model.info(row: row).map { $0.fullPath }
            })
            table.reloadData()
            guard !selectedIds.isEmpty, model.results.count < 2_000_000 else { return }
            var rows = IndexSet()
            let visibleLimit = min(model.results.count, 200_000)
            for row in 0..<visibleLimit where rows.count < selectedIds.count {
                if let info = model.info(row: row), selectedIds.contains(info.fullPath) { rows.insert(row) }
            }
            if !rows.isEmpty { table.selectRowIndexes(rows, byExtendingSelection: false) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { model.results.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? NSTableCellView) ?? makeCell(column)
            guard let info = model.info(row: row) else {
                cell.textField?.stringValue = ""
                cell.imageView?.image = nil
                return cell
            }
            switch column {
            case .name:
                cell.textField?.stringValue = info.name
                cell.imageView?.image = icons.icon(for: info)
            case .path:
                cell.textField?.stringValue = info.parentPath
            case .size:
                if info.isDirectory {
                    // 폴더는 안의 파일 크기를 모두 더한다(뒤에서 세는 동안은 비워 둔다).
                    let total = info.isSymlink ? nil : model.folderSize(row: row, id: info.id)
                    cell.textField?.stringValue = total.map { Self.sizeFormatter.string(fromByteCount: $0) } ?? ""
                } else {
                    cell.textField?.stringValue = Self.sizeFormatter.string(fromByteCount: info.size)
                }
            case .modified:
                cell.textField?.stringValue = info.modified.timeIntervalSince1970 > 0 ? Self.dateFormatter.string(from: info.modified) : ""
            }
            return cell
        }

        private func makeCell(_ column: Column) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = column.identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = column == .path ? .byTruncatingMiddle : .byTruncatingTail
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            if column == .size {
                text.alignment = .right
                text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            }
            if column == .path || column == .modified {
                text.textColor = .secondaryLabelColor
            }
            cell.addSubview(text)
            cell.textField = text
            if column == .name {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key, let sort = SortKey(rawValue: key) else { return }
            model.setSort(sort, ascending: descriptor.ascending)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            if let panel = QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil, panel.isVisible {
                panel.reloadData()
            }
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let info = model.info(row: row) else { return nil }
            return NSURL(fileURLWithPath: info.fullPath)
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0 else { return }
            model.open(rows: rowsForAction(sender))
        }

        // MARK: 오른쪽 클릭 메뉴

        func makeMenu(for table: NSTableView) -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
                ("열기", #selector(openItems(_:)), "", []),
                ("Finder에서 보기", #selector(revealItems(_:)), "r", [.command]),
                ("경로 복사", #selector(copyPathItems(_:)), "c", [.command, .shift]),
                ("이름 복사", #selector(copyNameItems(_:)), "", []),
                ("훑어보기", #selector(quickLookItems(_:)), " ", []),
                ("휴지통으로 이동", #selector(trashItems(_:)), "\u{8}", [.command]),
            ]
            for (index, item) in items.enumerated() {
                if index == 4 || index == 5 { menu.addItem(.separator()) }
                let menuItem = NSMenuItem(title: item.0, action: item.1, keyEquivalent: item.2)
                menuItem.keyEquivalentModifierMask = item.3
                menuItem.target = self
                menu.addItem(menuItem)
            }
            return menu
        }

        private func rowsForAction(_ table: NSTableView?) -> IndexSet {
            guard let table else { return [] }
            let clicked = table.clickedRow
            if clicked >= 0 && !table.selectedRowIndexes.contains(clicked) { return [clicked] }
            return table.selectedRowIndexes
        }

        @objc func openItems(_ sender: Any?) { model.open(rows: rowsForAction(model.tableView)) }
        @objc func revealItems(_ sender: Any?) { model.reveal(rows: rowsForAction(model.tableView)) }
        @objc func copyPathItems(_ sender: Any?) { model.copyPaths(rows: rowsForAction(model.tableView)) }
        @objc func copyNameItems(_ sender: Any?) { model.copyNames(rows: rowsForAction(model.tableView)) }
        @objc func trashItems(_ sender: Any?) { model.moveToTrash(rows: rowsForAction(model.tableView)) }
        @objc func quickLookItems(_ sender: Any?) { (model.tableView as? ResultsNSTableView)?.togglePreview() }
    }
}

/// 키보드: 엔터=열기, ⌘엔터/⌘R=Finder에서 보기, 스페이스=훑어보기, ⌘C=경로 복사, ⌘⌫=휴지통,
/// 글자를 치면 검색창으로 돌아가 이어서 입력, 맨 위에서 ↑ 누르면 검색창으로.
final class ResultsNSTableView: NSTableView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var model: SearchModel?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let model else { return super.keyDown(with: event) }
        switch Int(event.keyCode) {
        case 36, 76: // return, enter
            if flags.contains(.command) { model.reveal(rows: selectedRowIndexes) } else { model.open(rows: selectedRowIndexes) }
            return
        case 49 where flags.isEmpty: // space
            togglePreview()
            return
        case 51 where flags.contains(.command): // ⌘⌫
            model.moveToTrash(rows: selectedRowIndexes)
            return
        case 15 where flags == .command: // ⌘R
            model.reveal(rows: selectedRowIndexes)
            return
        case 126 where selectedRow <= 0: // ↑ at top
            model.focusSearch(selectAll: false)
            return
        default:
            break
        }
        if event.specialKey == nil, flags.subtracting([.shift, .capsLock]).isEmpty,
           let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            model.focusSearch(selectAll: false)
            model.searchField?.currentEditor()?.insertText(characters)
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        model?.copyPaths(rows: selectedRowIndexes)
    }

    // MARK: 훑어보기(Quick Look)

    private var previewURLs: [URL] = []

    func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs = model?.urls(rows: selectedRowIndexes) ?? []
        return previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 125 || event.keyCode == 126 {
            keyDown(with: event)
            return true
        }
        return false
    }
}

/// 확장자별 아이콘을 한 번만 만든다. 앱 같은 패키지는 경로별로 따로 기억한다.
@MainActor
final class IconCache {
    private var byExtension: [String: NSImage] = [:]
    private let byPath = NSCache<NSString, NSImage>()
    private lazy var folder = NSWorkspace.shared.icon(for: .folder)
    private lazy var plain = NSWorkspace.shared.icon(for: .data)
    private static let packageExtensions: Set<String> = ["app", "bundle", "framework", "pkg", "mpkg", "prefpane", "photoslibrary", "plugin", "kext", "xcodeproj", "playground", "rtfd", "pages", "numbers", "key"]

    init() { byPath.countLimit = 500 }

    func icon(for info: EntryInfo) -> NSImage {
        let ext = (info.name as NSString).pathExtension.lowercased()
        if info.isDirectory {
            guard Self.packageExtensions.contains(ext) else { return folder }
            if let cached = byPath.object(forKey: info.fullPath as NSString) { return cached }
            let image = NSWorkspace.shared.icon(forFile: info.fullPath)
            byPath.setObject(image, forKey: info.fullPath as NSString)
            return image
        }
        if ext.isEmpty { return plain }
        if let cached = byExtension[ext] { return cached }
        let image = UTType(filenameExtension: ext).map { NSWorkspace.shared.icon(for: $0) } ?? plain
        byExtension[ext] = image
        return image
    }
}
