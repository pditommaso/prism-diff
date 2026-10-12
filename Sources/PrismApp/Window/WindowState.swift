// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import PrismProtocol

/// A document window as saved at quit: its frame, its tabs and which one
/// is selected.
struct WindowState: Codable, Equatable, Sendable {
    struct Frame: Codable, Equatable, Sendable {
        var x: Double, y: Double, width: Double, height: Double

        init(_ rect: NSRect) {
            x = rect.minX
            y = rect.minY
            width = rect.width
            height = rect.height
        }

        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    var frame: Frame
    var tabs: [TabState]
    var selected: Int
}

/// One tab as saved at quit.
enum TabState: Codable, Equatable, Sendable {
    case text(TextTabState)
    case folder(FolderTabState)
}

/// A text comparison: its files (the shelf), A and B, and how it was
/// shown.
struct TextTabState: Codable, Equatable, Sendable {
    var files: [String]
    /// Files shown by name only (clipboard snippets).
    var nameOnly: [Bool]
    var a: Int
    var b: Int
    var mode: String
    var wrapsLines: Bool
    var ignoresWhitespace: Bool
    var shelfVisible: Bool
    /// A fixed tab title (a file pair opened from a folder level).
    var title: String?
}

extension TextTabState {
    @MainActor
    init(_ controller: ComparisonWindowController, title: String? = nil, key: String = "") {
        files = controller.shelf.files.map { $0.url.path(percentEncoded: false) }
        nameOnly = controller.shelf.files.map { $0.display == .nameOnly }
        a = controller.shelf.a
        b = controller.shelf.b
        mode = controller.blocksView.mode.rawValue
        wrapsLines = controller.blocksView.wrapsLines
        ignoresWhitespace = controller.ignoreWhitespace
        shelfVisible = controller.isShelfVisible
        self.title = title
    }
}

/// A folder level: the two roots and the level's path below them.
struct FolderTabState: Codable, Equatable, Sendable {
    var left: String
    var right: String
    var relativePath: String
}

/// Saves the document windows when Prism quits and keeps its windows, and
/// brings them back at the next plain launch.
@MainActor
enum StateRestoration {
    /// Test override of the state file (honoured only with
    /// PRISM_TESTING=1, so a stray variable never hides a user's windows).
    nonisolated static let pathVariable = "PRISM_STATE_PATH"

    /// The state file: the user's, or under PRISM_TESTING=1 only the one
    /// PRISM_STATE_PATH names. A test run without it has no state file, so
    /// it never reads, deletes or overwrites the user's saved windows.
    static var fileURL: URL? {
        fileURL(environment: ProcessInfo.processInfo.environment)
    }

    nonisolated static func fileURL(environment: [String: String]) -> URL? {
        if environment[IPCEnvironment.testingVariable] == "1" {
            guard let path = environment[pathVariable], !path.isEmpty else { return nil }
            return URL(filePath: path)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Prism/Windows.json")
    }

    static func encode(_ windows: [WindowState]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(windows)
    }

    static func decode(_ data: Data) throws -> [WindowState] {
        try JSONDecoder().decode([WindowState].self, from: data)
    }

    /// Writes the state of `controllers` (front to back), or removes the
    /// file when there is nothing to bring back.
    @discardableResult
    static func save(_ controllers: [DocumentWindowController], to url: URL? = fileURL) -> [WindowState] {
        let states = controllers.compactMap(\.restorationState)
        guard let url else { return states }
        guard !states.isEmpty, let data = try? encode(states) else {
            discard(url)
            return []
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        PerfLog.record("stateSaved", ["windows": states.count, "tabs": states.map(\.tabs.count)])
        return states
    }

    /// Reads and removes the saved state.
    static func take(from url: URL? = fileURL) -> [WindowState] {
        guard let url else { return [] }
        defer { discard(url) }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decode(data)) ?? []
    }

    static func discard(_ url: URL? = fileURL) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Every file the states refer to (to keep their clipboard snippets).
    static func files(of states: [WindowState]) -> Set<String> {
        var files: Set<String> = []
        for state in states {
            for case let .text(text) in state.tabs { files.formUnion(text.files) }
        }
        return files
    }

    /// A level path that stays below the roots: relative, without "." or
    /// ".." components; nil otherwise.
    nonisolated static func safeLevel(_ path: String) -> String? {
        if path.isEmpty { return "" }
        guard !path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }

    /// The saved frame, if it still shows on one of `screens` (at least
    /// 100×60 points of it visible); its size never below `minimum`. Nil:
    /// center the window instead.
    nonisolated static func clampedFrame(_ rect: NSRect, screens: [NSRect], minimum: NSSize) -> NSRect? {
        guard rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite,
              rect.width > 0, rect.height > 0 else { return nil }
        var frame = rect
        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        guard let screen = screens.first(where: {
            let visible = $0.intersection(frame)
            return !visible.isNull && visible.width >= 100 && visible.height >= 60
        }) else { return nil }
        frame.size.width = min(frame.width, max(screen.width, minimum.width))
        frame.size.height = min(frame.height, max(screen.height, minimum.height))
        frame.origin.x = min(max(frame.minX, screen.minX), max(screen.maxX - frame.width, screen.minX))
        frame.origin.y = min(max(frame.minY, screen.minY), max(screen.maxY - frame.height, screen.minY))
        return frame
    }

    /// A window with the tabs of `state` whose files still exist; nil when
    /// none does. Folder levels of the same roots share one comparison.
    static func makeWindow(_ state: WindowState) -> DocumentWindowController? {
        var tabs: [WorkspaceTab] = []
        var documents: [String: FolderDocument] = [:]
        var selected = 0
        for (index, tab) in state.tabs.enumerated() {
            let made: WorkspaceTab?
            switch tab {
            case let .text(text): made = makeTextTab(text)
            case let .folder(folder):
                let key = folder.left + "\u{0}" + folder.right
                if !exists(folder.left, directory: true) || !exists(folder.right, directory: true) {
                    made = nil
                } else {
                    // A level that escapes the roots is refused; one that is
                    // gone falls back to the roots.
                    var level = safeLevel(folder.relativePath) ?? ""
                    if !level.isEmpty, !exists(folder.left + "/" + level, directory: true)
                        || !exists(folder.right + "/" + level, directory: true) {
                        level = ""
                    }
                    let document = documents[key] ?? FolderDocument(left: URL(filePath: folder.left, directoryHint: .isDirectory),
                                                                    right: URL(filePath: folder.right, directoryHint: .isDirectory))
                    documents[key] = document
                    made = document.makeTab(relativePath: level)
                }
            }
            guard let made else { continue }
            if index == state.selected { selected = tabs.count }
            tabs.append(made)
        }
        guard !tabs.isEmpty else { return nil }
        let controller = DocumentWindowController()
        for (index, tab) in tabs.enumerated() { controller.insert(tab, at: index) }
        controller.selectTab(selected)
        if let window = controller.window {
            let minimum = window.frameRect(forContentRect: NSRect(origin: .zero,
                                                                  size: ComparisonWindowController.minimumContentSize)).size
            if let frame = clampedFrame(state.frame.rect, screens: NSScreen.screens.map(\.visibleFrame), minimum: minimum) {
                window.setFrame(frame, display: false)
            } else {
                window.center()
            }
        }
        return controller
    }

    private static func exists(_ path: String, directory: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue == directory
    }

    private static func makeTextTab(_ state: TextTabState) -> TextTab? {
        var entries: [ShelfEntry] = []
        var a = state.a, b = state.b
        for (index, path) in state.files.enumerated() {
            guard exists(path, directory: false) else {
                // A missing file leaves the shelf; indices after it shift.
                if index < state.a { a -= 1 }
                if index < state.b { b -= 1 }
                continue
            }
            let nameOnly = state.nameOnly.indices.contains(index) && state.nameOnly[index]
            entries.append(ShelfEntry(url: URL(filePath: path), display: nameOnly ? .nameOnly : .path))
        }
        guard entries.count >= 2 else { return nil }
        let model = ShelfModel(files: entries, a: a, b: b)
        guard let first = model.entryA, let second = model.entryB else { return nil }
        let controller = ComparisonWindowController(a: first.url, b: second.url)
        controller.setShelfFiles(entries, a: model.a, b: model.b)
        controller.setShelfVisible(state.shelfVisible)
        if let mode = ViewMode(rawValue: state.mode) { controller.setMode(mode, remember: false) }
        if controller.blocksView.wrapsLines != state.wrapsLines { controller.blocksView.setWrapsLines(state.wrapsLines) }
        if controller.ignoreWhitespace != state.ignoresWhitespace { controller.setIgnoreWhitespace(state.ignoresWhitespace) }
        return TextTab(controller: controller, key: "text:\(UUID().uuidString)", title: state.title)
    }
}

/// The comparisons opened lately, for File > Open Recent: pairs of paths,
/// most recent first.
@MainActor
final class RecentComparisons {
    static let shared = RecentComparisons()
    static let key = "prism.recentComparisons"
    static let limit = 10

    var defaults: UserDefaults = AppDefaults.shared

    var entries: [[String]] {
        (defaults.array(forKey: Self.key) as? [[String]]) ?? []
    }

    /// Remembers a comparison of `urls` (two files or two folders).
    func note(_ urls: [URL]) {
        let paths = urls.map { $0.path(percentEncoded: false) }
        guard paths.count == 2, !paths.contains(where: { $0.hasPrefix(ClipboardSnippets.directory.path(percentEncoded: false)) })
        else { return }
        var list = entries.filter { $0 != paths }
        list.insert(paths, at: 0)
        defaults.set(Array(list.prefix(Self.limit)), forKey: Self.key)
    }

    func clear() { defaults.removeObject(forKey: Self.key) }

    /// "a | b"; equal names carry their folder: "x (left) | x (right)".
    static func title(for paths: [String]) -> String {
        let urls = paths.map { URL(filePath: $0) }
        let names = urls.map(\.lastPathComponent)
        guard names.count == 2 else { return names.joined(separator: " | ") }
        if names[0] != names[1] { return "\(names[0]) | \(names[1])" }
        let parents = urls.map { $0.deletingLastPathComponent().lastPathComponent }
        return "\(names[0]) (\(parents[0])) | \(names[1]) (\(parents[1]))"
    }
}

/// Fills File > Open Recent when it opens.
@MainActor
final class RecentMenu: NSObject, NSMenuDelegate {
    static let shared = RecentMenu()
    /// Receives `openRecent:` and `clearRecentComparisons:`.
    weak var target: AnyObject?

    /// The entries the menu shows (the app refreshes menus often in the
    /// background: rebuild only when they change).
    private var shown: [[String]]?

    func menuNeedsUpdate(_ menu: NSMenu) {
        let entries = RecentComparisons.shared.entries
        guard entries != shown || menu.numberOfItems == 0 else { return }
        shown = entries
        Self.fill(menu, entries: entries, target: target)
    }

    static func fill(_ menu: NSMenu, entries: [[String]], target: AnyObject?) {
        menu.removeAllItems()
        for paths in entries {
            let item = menu.addItem(withTitle: RecentComparisons.title(for: paths),
                                    action: #selector(AppDelegate.openRecent(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = paths
            item.toolTip = paths.joined(separator: "\n")
            let folder = paths.first.map { AppDelegate.isDirectory(URL(filePath: $0)) } ?? false
            item.image = NSImage(systemSymbolName: folder ? "folder" : "doc.text", accessibilityDescription: nil)
        }
        if !entries.isEmpty { menu.addItem(.separator()) }
        let clear = menu.addItem(withTitle: "Clear Menu",
                                 action: entries.isEmpty ? nil : #selector(AppDelegate.clearRecentComparisons(_:)),
                                 keyEquivalent: "")
        clear.target = target
    }
}
