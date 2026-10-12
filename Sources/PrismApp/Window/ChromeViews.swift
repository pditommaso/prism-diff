// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// A bar with a flat background and a 1 pt hairline on one edge.
@MainActor
class BarView: NSView {
    enum Edge { case top, bottom }
    let hairlineEdge: Edge

    init(hairline edge: Edge) {
        hairlineEdge = edge
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        let y = hairlineEdge == .top ? 0 : bounds.height - 1
        NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
    }
}

/// The tab strip: one tab for the comparison, "📄 a | b", with a badge
/// counting the files. Multiple tabs come later.
@MainActor
final class TabStripView: BarView {
    let titleField = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "2")
    private let icon = NSImageView()

    init() {
        super.init(hairline: .bottom)
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Text comparison")
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        titleField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.setAccessibilityIdentifier("prism.tabTitle")
        badge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 7.5
        badge.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        badge.toolTip = "Files in this comparison"
        for view in [icon, titleField, badge] as [NSView] { addSubview(view) }
    }

    func setTitle(_ title: String, fileCount: Int) {
        titleField.stringValue = title
        badge.stringValue = String(fileCount)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        titleField.sizeToFit()
        let height = bounds.height
        let titleWidth = min(titleField.frame.width, max(bounds.width - 120, 40))
        let total = 16 + 4 + titleWidth
        let x = floor((bounds.width - total) / 2)
        icon.frame = NSRect(x: x, y: floor((height - 16) / 2), width: 16, height: 16)
        titleField.frame = NSRect(x: x + 20, y: floor((height - titleField.frame.height) / 2),
                                  width: titleWidth, height: titleField.frame.height)
        badge.sizeToFit()
        let badgeWidth = max(badge.frame.width + 10, 18)
        badge.frame = NSRect(x: bounds.width - badgeWidth - 12, y: floor((height - 15) / 2), width: badgeWidth, height: 15)
    }
}

/// The path bar: "A" and the A breadcrumbs, the swap button, "B" and the B
/// breadcrumbs, and at the far right the file-shelf toggle.
@MainActor
final class PathBarView: BarView {
    enum Side { case a, b }

    let pathA = BreadcrumbView()
    let pathB = BreadcrumbView()
    let swapButton: NSButton
    let shelfButton: NSButton
    private let labelA = NSTextField(labelWithString: "A")
    private let labelB = NSTextField(labelWithString: "B")
    /// A sibling chosen in a breadcrumb menu (compare it on that side).
    var onChoose: ((Side, URL) -> Void)?
    static let shelfButtonWidth: CGFloat = 30

    init(target: AnyObject?, swapAction: Selector) {
        swapButton = NSButton(image: NSImage(systemSymbolName: "arrow.left.arrow.right",
                                             accessibilityDescription: "Swap A and B")!,
                              target: target, action: swapAction)
        shelfButton = NSButton(image: NSImage(systemSymbolName: "square.on.square",
                                              accessibilityDescription: "Toggle File Shelf")!,
                               target: nil, action: #selector(DocumentWindowController.toggleFileShelf(_:)))
        super.init(hairline: .bottom)
        swapButton.isBordered = false
        swapButton.toolTip = "Swap A and B (\u{2318}\\)"
        swapButton.setAccessibilityIdentifier("prism.swap")
        shelfButton.isBordered = false
        shelfButton.contentTintColor = .secondaryLabelColor
        shelfButton.toolTip = "Show or hide the file shelf (\u{2318}/)"
        shelfButton.setAccessibilityIdentifier("prism.shelfToggle")
        for label in [labelA, labelB] {
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        pathA.setAccessibilityIdentifier("prism.path.a")
        pathB.setAccessibilityIdentifier("prism.path.b")
        pathA.onChoose = { [weak self] url in self?.onChoose?(.a, url) }
        pathB.onChoose = { [weak self] url in self?.onChoose?(.b, url) }
        for view in [labelA, pathA, swapButton, labelB, pathB, shelfButton] as [NSView] { addSubview(view) }
    }

    /// How a side's location is shown.
    enum Display: Equatable, Sendable {
        /// The breadcrumbs of the full path.
        case path
        /// Only the file name (a private copy of a temporary file).
        case nameOnly
        /// No file on this side (an added or removed file).
        case absent
    }

    func setURLs(a: URL, b: URL, display: (a: Display, b: Display) = (.path, .path)) {
        pathA.show(a, display: display.a)
        pathB.show(b, display: display.b)
    }

    /// Marks the sides that have unsaved changes with a dot after their
    /// letter.
    func setEdited(a: Bool, b: Bool) {
        labelA.stringValue = a ? "A \u{2022}" : "A"
        labelB.stringValue = b ? "B \u{2022}" : "B"
        labelA.setAccessibilityValue(a ? "edited" : nil)
        labelB.setAccessibilityValue(b ? "edited" : nil)
        needsLayout = true
    }

    /// The letters shown, for tests.
    var sideLabels: (a: String, b: String) { (labelA.stringValue, labelB.stringValue) }

    /// x of the divider between the panes, so B lines up with its pane.
    var splitX: CGFloat = 0 { didSet { needsLayout = true } }

    override func layout() {
        super.layout()
        let height = bounds.height - 1
        let split = splitX > 0 ? splitX : floor(bounds.width / 2)
        let swapWidth: CGFloat = 28
        func place(_ label: NSTextField, _ path: BreadcrumbView, from x: CGFloat, to end: CGFloat) {
            label.sizeToFit()
            label.frame.origin = NSPoint(x: x, y: floor((height - label.frame.height) / 2))
            let pathX = x + label.frame.width + 8
            path.frame = NSRect(x: pathX, y: floor((height - 22) / 2), width: max(end - pathX, 0), height: 22)
        }
        place(labelA, pathA, from: 12, to: split - swapWidth / 2 - 8)
        swapButton.frame = NSRect(x: split - swapWidth / 2, y: floor((height - 20) / 2), width: swapWidth, height: 20)
        let shelfX = bounds.width - Self.shelfButtonWidth - 4
        place(labelB, pathB, from: split + swapWidth / 2 + 8, to: shelfX - 4)
        shelfButton.frame = NSRect(x: shelfX, y: floor((height - 20) / 2), width: Self.shelfButtonWidth, height: 20)
    }
}

/// The bottom bar: layout switcher on the left, the merge arrows in the
/// middle (they act from a later milestone), and on the right the
/// whitespace checkbox and the change stepper.
@MainActor
final class BottomBarView: BarView {
    let layoutControl: NSSegmentedControl
    let mergeControl: NSSegmentedControl
    let ignoreWhitespaceButton = NSButton(checkboxWithTitle: "Ignore whitespace", target: nil, action: nil)
    let changeLabel = NSTextField(labelWithString: "")
    let previousButton: NSButton
    let nextButton: NSButton

    /// VoiceOver names of the merge arrows, left to right.
    static let mergeLabels = ["More ways to merge from A", "Copy to the right", "Copy to the left",
                              "More ways to merge from B"]

    init(target: AnyObject?, previous: Selector, next: Selector) {
        let images = ["rectangle.split.2x1", "rectangle.righthalf.inset.filled", "line.3.horizontal"]
            .map { NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage() }
        layoutControl = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        let mergeImages = zip(["chevron.down", "arrow.right.to.line", "arrow.left.to.line", "chevron.down"],
                              BottomBarView.mergeLabels)
            .map { NSImage(systemSymbolName: $0, accessibilityDescription: $1) ?? NSImage() }
        mergeControl = NSSegmentedControl(images: mergeImages, trackingMode: .momentary, target: nil, action: nil)
        previousButton = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Previous change")!,
                                  target: target, action: previous)
        nextButton = NSButton(image: NSImage(systemSymbolName: "arrow.down", accessibilityDescription: "Next change")!,
                              target: target, action: next)
        super.init(hairline: .top)
        for (index, label) in ["Blocks", "Fluid", "Unified"].enumerated() {
            layoutControl.setLabel(label, forSegment: index)
            layoutControl.setImageScaling(.scaleProportionallyDown, forSegment: index)
            layoutControl.setWidth(0, forSegment: index)
            layoutControl.setToolTip("\(label) (\u{2318}\(index + 1))", forSegment: index)
        }
        layoutControl.controlSize = .small
        layoutControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        layoutControl.selectedSegment = 0
        layoutControl.setAccessibilityIdentifier("prism.layout")
        layoutControl.setAccessibleName("Layout")
        mergeControl.controlSize = .small
        for (index, tip) in ["More ways to merge", "Copy to the right", "Copy to the left", "More ways to merge"]
            .enumerated() {
            mergeControl.setToolTip(tip, forSegment: index)
            mergeControl.setEnabled(false, forSegment: index)
        }
        mergeControl.setAccessibilityIdentifier("prism.merge")
        mergeControl.setAccessibleName("Merge")
        ignoreWhitespaceButton.controlSize = .small
        ignoreWhitespaceButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        ignoreWhitespaceButton.toolTip = "Ignore spaces and tabs at the start and end of lines (\u{21E7}\u{2318}')"
        ignoreWhitespaceButton.setAccessibilityIdentifier("prism.ignoreWhitespace")
        changeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        changeLabel.alignment = .right
        changeLabel.setAccessibilityIdentifier("prism.changeLabel")
        for button in [previousButton, nextButton] {
            button.bezelStyle = .smallSquare
            button.controlSize = .small
        }
        previousButton.toolTip = "Previous change (\u{2318}\u{2191})"
        nextButton.toolTip = "Next change (\u{2318}\u{2193})"
        previousButton.setAccessibilityIdentifier("prism.previousChange")
        nextButton.setAccessibilityIdentifier("prism.nextChange")
        for view in [layoutControl, mergeControl, ignoreWhitespaceButton, changeLabel, previousButton, nextButton]
            as [NSView] { addSubview(view) }
    }

    func setChange(_ index: Int?, of count: Int, loading: Bool = false) {
        if loading {
            changeLabel.stringValue = ""
        } else if count == 0 {
            changeLabel.stringValue = "No Changes"
        } else if let index {
            changeLabel.stringValue = "Change \(index + 1) of \(count)"
        } else {
            changeLabel.stringValue = count == 1 ? "1 Change" : "\(count) Changes"
        }
        previousButton.isEnabled = count > 0 && !loading
        nextButton.isEnabled = count > 0 && !loading
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        layoutControl.sizeToFit()
        layoutControl.frame.origin = NSPoint(x: 12, y: floor((height - layoutControl.frame.height) / 2))
        mergeControl.sizeToFit()
        let mergeX = max(floor((bounds.width - mergeControl.frame.width) / 2), layoutControl.frame.maxX + 16)
        mergeControl.frame.origin = NSPoint(x: mergeX, y: floor((height - mergeControl.frame.height) / 2))
        let buttonSize = NSSize(width: 28, height: 22)
        nextButton.frame = NSRect(origin: NSPoint(x: bounds.width - 12 - buttonSize.width,
                                                  y: floor((height - buttonSize.height) / 2)), size: buttonSize)
        previousButton.frame = nextButton.frame.offsetBy(dx: -buttonSize.width - 4, dy: 0)
        changeLabel.sizeToFit()
        let labelWidth = max(changeLabel.frame.width, 60)
        changeLabel.frame = NSRect(x: previousButton.frame.minX - 12 - labelWidth,
                                   y: floor((height - changeLabel.frame.height) / 2),
                                   width: labelWidth, height: changeLabel.frame.height)
        ignoreWhitespaceButton.sizeToFit()
        let checkX = changeLabel.frame.minX - 20 - ignoreWhitespaceButton.frame.width
        ignoreWhitespaceButton.frame.origin = NSPoint(x: checkX,
                                                      y: floor((height - ignoreWhitespaceButton.frame.height) / 2))
        // In a narrow window the merge arrows give way first, then the
        // checkbox; the stepper always stays.
        mergeControl.isHidden = mergeControl.frame.maxX > checkX - 8
        ignoreWhitespaceButton.isHidden = checkX < layoutControl.frame.maxX + 8
    }
}

/// Centered message shown instead of the comparison: a spinner while it
/// loads, or an error.
@MainActor
final class PlaceholderView: NSView {
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        spinner.style = .spinning
        spinner.controlSize = .regular
        // Nothing shows until a load passes the placeholder threshold.
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 15)
        label.setAccessibilityIdentifier("prism.placeholder")
        addSubview(spinner)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func showLoading() {
        label.stringValue = "Comparing\u{2026}"
        spinner.isHidden = false
        spinner.startAnimation(nil)
        needsLayout = true
    }

    func showMessage(_ message: String) {
        label.stringValue = message
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        needsLayout = true
    }

    var message: String { label.stringValue }

    /// True while the spinner is on screen.
    var isSpinnerVisible: Bool { !spinner.isHidden }

    override func layout() {
        super.layout()
        let width = min(bounds.width - 40, 480)
        label.preferredMaxLayoutWidth = width
        let labelHeight = label.sizeThatFits(NSSize(width: width, height: 1000)).height
        let spinnerHeight: CGFloat = spinner.isHidden ? 0 : 32 + 12
        let top = floor((bounds.height - spinnerHeight - labelHeight) / 2)
        spinner.frame = NSRect(x: floor((bounds.width - 32) / 2), y: top, width: 32, height: 32)
        label.frame = NSRect(x: floor((bounds.width - width) / 2), y: top + spinnerHeight, width: width, height: labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
