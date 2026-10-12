// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import CoreText

/// Colours of the conflict family (yellow), for light and dark themes.
struct ConflictPalette {
    private(set) var band, word, gutter, border: CGColor
    private(set) var selectedBand, selectedWord, selectedGutter, selectedNumber: CGColor

    init(dark: Bool, increaseContrast: Bool = false) {
        defer { if increaseContrast { strengthen(dark: dark) } }
        func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
        }
        if dark {
            band = rgb(0x26, 0x23, 0x13)
            border = rgb(0x80, 0x75, 0x40)
            word = rgb(0x4A, 0x42, 0x20)
            gutter = rgb(0x3A, 0x35, 0x19)
            selectedBand = rgb(0x59, 0x52, 0x2D)
            selectedWord = rgb(0x80, 0x75, 0x40)
            selectedGutter = rgb(0x6B, 0x62, 0x36)
            selectedNumber = rgb(0xFF, 0xFF, 0xFF)
        } else {
            band = rgb(255, 245, 203, 0.8)
            border = rgb(255, 229, 128, 0.7)
            word = rgb(255, 229, 128)
            gutter = rgb(255, 236, 160)
            selectedBand = rgb(0xFF, 0xE8, 0x8C)
            selectedWord = rgb(0xF2, 0xCC, 0x4A)
            selectedGutter = rgb(0xEB, 0xC9, 0x55)
            selectedNumber = rgb(0x33, 0x2B, 0x00)
        }
    }

    /// Increase Contrast: the band, word and number cells move towards
    /// the border colour, and the border towards the text colour.
    private mutating func strengthen(dark: Bool) {
        func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
            let x = a.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
            let y = b.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
            return CGColor(srgbRed: x[0] + (y[0] - x[0]) * t, green: x[1] + (y[1] - x[1]) * t,
                           blue: x[2] + (y[2] - x[2]) * t, alpha: 1)
        }
        let ink = dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : CGColor(srgbRed: 0.2, green: 0.17, blue: 0, alpha: 1)
        let edge = mix(border, ink, 0.35)
        band = mix(band, border, 0.4)
        word = mix(word, edge, 0.4)
        gutter = mix(gutter, border, 0.5)
        selectedBand = mix(selectedBand, edge, 0.3)
        selectedGutter = mix(selectedGutter, edge, 0.3)
        border = edge
    }
}

/// Where one column of the merge view lies, in view points.
struct MergeColumnFrame: Equatable {
    /// Left edge of the column (its gutter).
    var x: CGFloat
    var width: CGFloat
    /// Width of the line-number gutter at its left.
    var gutter: CGFloat
    /// Two number cells (A and B) instead of one: the unified column.
    var twoNumbers: Bool

    var textX: CGFloat { x + gutter }
    var maxX: CGFloat { x + width }
}

/// The three-way merge view: A | result | B (Blocks, Fluid) or the
/// interleaved A/B column and the result (Unified), in one vertical
/// scroller. Long lines are clipped at their column's edge.
@MainActor
final class MergeView: NSView {
    let scrollView = NSScrollView()
    let canvas = MergeCanvas()

    var display = MergeDisplay() { didSet { relayout() } }
    private(set) var mode: ViewMode = .unified
    var theme: Theme { didSet { canvas.palette = ThemePalette(theme); canvas.conflict = ConflictPalette(dark: theme.dark, increaseContrast: theme.isContrasted)
                                canvas.needsDisplay = true } }
    var metrics: TextMetrics { didSet { relayout() } }
    /// The selected region (an index into `display.regions`).
    var selectedRegion: Int? { didSet { canvas.needsDisplay = true } }
    /// Called when the user clicks a region where A and B differ.
    var onSelect: ((Int) -> Void)?
    /// Called on a double click in the result column.
    var onEdit: ((Int) -> Void)?
    /// Called when the column frames change (the header follows them).
    var onColumnsChange: (([MergeColumnFrame]) -> Void)?

    private(set) var layoutModel = MergeLayout(MergeDisplay(), mode: .unified)
    private(set) var columnFrames: [MergeColumnFrame] = []

    /// Gap between columns in Fluid, where the connectors are drawn.
    static let connectorGap: CGFloat = 72

    init(font: NSFont, theme: Theme) {
        self.theme = theme
        metrics = TextMetrics(font: font)
        super.init(frame: .zero)
        canvas.host = self
        canvas.palette = ThemePalette(theme)
        canvas.conflict = ConflictPalette(dark: theme.dark, increaseContrast: theme.isContrasted)
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        setAccessibilityIdentifier("prism.mergeView")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func setMode(_ mode: ViewMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        relayout()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        relayout()
    }

    /// Rebuilds the rows and the column frames, and resizes the canvas.
    func relayout() {
        layoutModel = MergeLayout(display, mode: mode)
        let width = max(scrollView.contentSize.width, 200)
        columnFrames = Self.columnFrames(width: width, mode: mode, metrics: metrics,
                                         maxLine: max(display.linesA.count, display.linesB.count,
                                                      (display.regions.last.map { $0.outputStart + $0.output.count } ?? 0)))
        let height = metrics.y(ofRow: layoutModel.rowCount) + metrics.lineHeight
        canvas.frame = NSRect(x: 0, y: 0, width: width, height: max(height, scrollView.contentSize.height))
        canvas.needsDisplay = true
        onColumnsChange?(columnFrames)
    }

    static func columnFrames(width: CGFloat, mode: ViewMode, metrics: TextMetrics, maxLine: Int) -> [MergeColumnFrame] {
        let digits = CGFloat(max(String(max(maxLine, 1)).count, 2))
        let cell = ceil(digits * metrics.charWidth + 18)
        switch mode {
        case .unified:
            let left = floor(width / 2)
            return [MergeColumnFrame(x: 0, width: left, gutter: cell * 2, twoNumbers: true),
                    MergeColumnFrame(x: left + 1, width: width - left - 1, gutter: cell, twoNumbers: false)]
        case .blocks, .fluid:
            let gap: CGFloat = mode == .fluid ? connectorGap : 1
            let column = floor((width - 2 * gap) / 3)
            return (0 ..< 3).map { k in
                MergeColumnFrame(x: CGFloat(k) * (column + gap), width: k == 2 ? width - 2 * (column + gap) : column,
                                 gutter: cell, twoNumbers: false)
            }
        }
    }

    // MARK: navigation

    /// Scrolls region `index` into view (centred when it is off screen).
    func reveal(region index: Int) {
        guard layoutModel.spans.first?.indices.contains(index) == true else { return }
        let rows = layoutModel.spans.map { $0[index] }
        let top = rows.map { metrics.y(ofRow: $0.lowerBound) }.min() ?? 0
        let bottom = rows.map { metrics.y(ofRow: max($0.upperBound, $0.lowerBound + 1)) }.max() ?? top
        let visible = scrollView.contentView.bounds
        guard top < visible.minY || bottom > visible.maxY else { return }
        let y = max(0, min(top - (visible.height - (bottom - top)) / 2, canvas.frame.height - visible.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The canvas rectangle of the result column's text for region `index`
    /// (at least one row high), for the editor.
    func outputRect(region index: Int) -> NSRect? {
        guard layoutModel.spans.count > 1, layoutModel.spans[1].indices.contains(index) else { return nil }
        let rows = layoutModel.spans[1][index]
        let frame = columnFrames[1]
        let all = layoutModel.spans.map { $0[index] }
        let height = max(all.map(\.count).max() ?? 1, 1)
        return NSRect(x: frame.textX + 2, y: metrics.y(ofRow: rows.lowerBound),
                      width: frame.width - frame.gutter - 4, height: CGFloat(height) * metrics.lineHeight)
    }

    /// The region at a canvas point, and whether it is in the result column.
    func hit(_ point: NSPoint) -> (region: Int, output: Bool)? {
        guard let column = columnFrames.firstIndex(where: { point.x >= $0.x && point.x < $0.maxX }) else { return nil }
        let row = metrics.row(atY: point.y)
        let rows = layoutModel.columns[column]
        guard rows.indices.contains(row) else { return nil }
        return (rows[row].region, column == layoutModel.outputColumn)
    }
}

/// Draws the rows of the merge view's columns (the scroller's document).
@MainActor
final class MergeCanvas: NSView {
    weak var host: MergeView?
    var palette = ThemePalette(BuiltinThemes.multicolorLight)
    var conflict = ConflictPalette(dark: false)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: accessibility

    /// Elements of the visible rows, by column and row, kept while the
    /// layout stays the same so assistive apps see stable objects.
    private var lineElements: [Int: LineAccessibilityElement] = [:]
    private var elementsLayout: MergeLayout?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        host?.mode == .unified ? "Merge: A and B, and the result" : "Merge: A, the result, and B"
    }

    override func accessibilityChildren() -> [Any]? {
        guard let host else { return [] }
        let layout = host.layoutModel
        if elementsLayout != layout {
            lineElements.removeAll()
            elementsLayout = layout
        }
        let visible = visibleRect
        let first = max(host.metrics.row(atY: visible.minY), 0)
        let last = host.metrics.row(atY: visible.maxY) + 1
        var children: [Any] = []
        for column in layout.columns.indices {
            let rows = layout.columns[column]
            guard first < rows.count else { continue }
            for row in first ..< min(last, rows.count) {
                if let element = lineElement(column: column, row: row) { children.append(element) }
            }
        }
        return children
    }

    /// The element for one row of one column (nil for padding rows).
    private func lineElement(column: Int, row: Int) -> LineAccessibilityElement? {
        guard let host, let description = Self.describe(host.layoutModel.columns[column][row],
                                                        display: host.display) else { return nil }
        let key = column << 32 | row
        let element = lineElements[key] ?? {
            let element = LineAccessibilityElement(row: row)
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.staticText)
            lineElements[key] = element
            return element
        }()
        element.setAccessibilityLabel(description.label)
        element.setAccessibilityValue(description.value)
        if let window, host.columnFrames.indices.contains(column) {
            let frame = host.columnFrames[column]
            let rect = NSRect(x: frame.x, y: host.metrics.y(ofRow: row), width: frame.width, height: host.metrics.lineHeight)
            element.setAccessibilityFrame(window.convertToScreen(convert(rect, to: nil)))
        }
        return element
    }

    /// What VoiceOver reads for a row: "Result line 4, conflict" and the
    /// line's text. Nil for padding.
    static func describe(_ row: MergeRow, display: MergeDisplay) -> (label: String, value: String)? {
        let region = display.regions.indices.contains(row.region) ? display.regions[row.region] : nil
        let note: String
        switch region?.kind {
        case .conflict?: note = region?.resolved == true ? ", resolved conflict" : ", conflict"
        case .auto?: note = ", change"
        default: note = ""
        }
        switch row.content {
        case .filler:
            return nil
        case let .placeholder(number):
            return ("Result line \(number)\(note)", "unresolved")
        case let .line(source, line, number, numberB):
            switch source {
            case .a:
                let text = display.linesA.indices.contains(line) ? display.linesA[line] : ""
                return ("A line \(number ?? line + 1)\(numberB.map { ", B line \($0)" } ?? "")\(note)", text)
            case .b:
                let text = display.linesB.indices.contains(line) ? display.linesB[line] : ""
                return ("B line \(numberB ?? number ?? line + 1)\(note)", text)
            case .output:
                guard let region else { return nil }
                let k = line - region.outputStart
                return ("Result line \(line + 1)\(note)", region.output.indices.contains(k) ? region.output[k] : "")
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let host else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = host.hit(point) else { return }
        if event.clickCount >= 2, hit.output {
            host.onEdit?(hit.region)
        } else if host.display.regions.indices.contains(hit.region), host.display.regions[hit.region].kind != .equal {
            host.onSelect?(hit.region)
        }
    }

    private func line(_ text: String, font: NSFont, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: color) ?? .textColor,
        ]))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let host, let context = NSGraphicsContext.current?.cgContext else { return }
        context.setFillColor(palette.background)
        context.fill(dirtyRect)
        let metrics = host.metrics
        let layout = host.layoutModel
        let display = host.display
        let frames = host.columnFrames
        guard frames.count == layout.columns.count else { return }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let first = max(metrics.row(atY: dirtyRect.minY), 0)
        let last = metrics.row(atY: dirtyRect.maxY) + 1

        for (k, frame) in frames.enumerated() {
            let rows = layout.columns[k]
            // Gutter background and its edge.
            context.setFillColor(palette.gutterBackground)
            context.fill(CGRect(x: frame.x, y: dirtyRect.minY, width: frame.gutter, height: dirtyRect.height))
            if first < rows.count {
                for row in first ..< min(last, rows.count) {
                    drawRow(rows[row], row: row, frame: frame, context: context, metrics: metrics, display: display)
                }
            }
            context.setFillColor(palette.gutterBorder)
            context.fill(CGRect(x: frame.x + frame.gutter - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height))
            if frame.twoNumbers {
                context.fill(CGRect(x: frame.x + frame.gutter / 2 - 1, y: dirtyRect.minY, width: 1,
                                    height: dirtyRect.height))
            }
        }
        // Dividers between columns (Blocks, Unified) or connectors (Fluid).
        if host.mode == .fluid {
            drawConnectors(context, frames: frames, layout: layout, display: display, metrics: metrics)
        }
        context.setFillColor(palette.divider)
        for frame in frames.dropFirst() where host.mode != .fluid {
            context.fill(CGRect(x: frame.x - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height))
        }
        if host.mode == .fluid {
            for frame in frames {
                context.fill(CGRect(x: frame.maxX, y: dirtyRect.minY, width: 1, height: dirtyRect.height))
                context.fill(CGRect(x: frame.x - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height))
            }
        }
    }

    /// Band, word and gutter colours of region `index`, nil for equal text.
    private func colors(_ index: Int, display: MergeDisplay) -> (band: CGColor, word: CGColor, gutter: CGColor,
                                                                 number: CGColor, border: CGColor)? {
        guard display.regions.indices.contains(index) else { return nil }
        let region = display.regions[index]
        let selected = host?.selectedRegion == index
        switch region.kind {
        case .equal:
            return nil
        case .conflict:
            return selected
                ? (conflict.selectedBand, conflict.selectedWord, conflict.selectedGutter, conflict.selectedNumber, conflict.border)
                : (conflict.band, conflict.word, conflict.gutter, palette.lineNumber, conflict.border)
        case .auto:
            let kind: ThemePalette.Difference = switch region.shape {
            case .insert: palette.insert
            case .delete: palette.delete
            case .change: palette.change
            }
            return selected
                ? (kind.selectedBand, kind.selectedWord, kind.selectedGutter, kind.selectedNumber, kind.border)
                : (kind.band, kind.word, kind.gutter, palette.lineNumber, kind.border)
        }
    }

    private func drawRow(_ row: MergeRow, row index: Int, frame: MergeColumnFrame, context: CGContext,
                         metrics: TextMetrics, display: MergeDisplay) {
        let top = metrics.y(ofRow: index)
        let colors = colors(row.region, display: display)
        let textRect = CGRect(x: frame.textX, y: top, width: frame.width - frame.gutter, height: metrics.lineHeight)
        let gutterRect = CGRect(x: frame.x, y: top, width: frame.gutter, height: metrics.lineHeight)
        switch row.content {
        case .filler:
            context.setFillColor(colors == nil ? palette.background : palette.spacer)
            context.fill(textRect)
            return
        case .placeholder(let number):
            if let colors {
                context.setFillColor(colors.band)
                context.fill(textRect)
                context.setFillColor(colors.gutter)
                context.fill(gutterRect)
            }
            drawNumber(number, in: gutterRect, color: colors?.number ?? palette.lineNumber, context: context, metrics: metrics)
            drawEndMark(at: frame.textX + metrics.textInset, top: top, context: context, metrics: metrics)
            return
        case let .line(source, line, number, numberB):
            if let colors {
                context.setFillColor(colors.band)
                context.fill(textRect)
                context.setFillColor(colors.gutter)
                context.fill(frame.twoNumbers && number == nil
                             ? CGRect(x: frame.x + frame.gutter / 2, y: top, width: frame.gutter / 2, height: metrics.lineHeight)
                             : frame.twoNumbers && numberB == nil
                             ? CGRect(x: frame.x, y: top, width: frame.gutter / 2, height: metrics.lineHeight)
                             : gutterRect)
            }
            let numberColor = colors?.number ?? palette.lineNumber
            if frame.twoNumbers {
                let half = CGRect(x: frame.x, y: top, width: frame.gutter / 2, height: metrics.lineHeight)
                if let number { drawNumber(number, in: half, color: numberColor, context: context, metrics: metrics) }
                if let numberB {
                    drawNumber(numberB, in: half.offsetBy(dx: frame.gutter / 2, dy: 0), color: numberColor,
                               context: context, metrics: metrics)
                }
                if colors != nil {
                    let letterRect = number != nil ? half : half.offsetBy(dx: frame.gutter / 2, dy: 0)
                    drawLetter(number != nil ? "A" : "B", in: letterRect, context: context, metrics: metrics)
                }
            } else if let number {
                drawNumber(number, in: gutterRect, color: numberColor, context: context, metrics: metrics)
            }
            let text: String
            let words: [Range<Int>]
            switch source {
            case .a:
                text = display.linesA.indices.contains(line) ? display.linesA[line] : ""
                words = colors != nil ? display.wordsA[line] ?? [] : []
            case .b:
                text = display.linesB.indices.contains(line) ? display.linesB[line] : ""
                words = colors != nil ? display.wordsB[line] ?? [] : []
            case .output:
                let region = display.regions[row.region]
                let k = line - region.outputStart
                text = region.output.indices.contains(k) ? region.output[k] : ""
                words = []
            }
            context.saveGState()
            context.clip(to: textRect)
            let ctLine = self.line(text, font: metrics.font, color: colors == nil ? palette.equalText : palette.text)
            let x = frame.textX + metrics.textInset
            if let colors, !words.isEmpty {
                context.setFillColor(colors.word)
                for range in words where !range.isEmpty {
                    let start = CTLineGetOffsetForStringIndex(ctLine, range.lowerBound, nil)
                    let end = CTLineGetOffsetForStringIndex(ctLine, range.upperBound, nil)
                    context.fill(CGRect(x: x + start, y: top + 1, width: max(end - start, 1), height: metrics.lineHeight - 2))
                }
            }
            context.textPosition = CGPoint(x: x, y: top + metrics.baseline)
            CTLineDraw(ctLine, context)
            if colors != nil {
                let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                drawEndMark(at: x + width + 2, top: top, context: context, metrics: metrics)
            }
            context.restoreGState()
        }
    }

    private func drawNumber(_ number: Int, in rect: CGRect, color: CGColor, context: CGContext, metrics: TextMetrics) {
        let ctLine = line(String(number), font: metrics.numberFont, color: color)
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        context.textPosition = CGPoint(x: rect.maxX - 8 - width, y: rect.minY + metrics.baseline)
        CTLineDraw(ctLine, context)
    }

    private func drawLetter(_ letter: String, in rect: CGRect, context: CGContext, metrics: TextMetrics) {
        let font = NSFont.systemFont(ofSize: max(metrics.numberFont.pointSize - 2, 6), weight: .medium)
        let ctLine = line(letter, font: font, color: palette.lineNumber)
        context.textPosition = CGPoint(x: rect.minX + 4, y: rect.minY + metrics.baseline)
        CTLineDraw(ctLine, context)
    }

    private func drawEndMark(at x: CGFloat, top: CGFloat, context: CGContext, metrics: TextMetrics) {
        let ctLine = line("\u{00AC}", font: metrics.font, color: palette.invisible)
        context.textPosition = CGPoint(x: x, y: top + metrics.baseline)
        CTLineDraw(ctLine, context)
    }

    /// Fluid: a band from each differing region's rows in one column to its
    /// rows in the next, through the gap between them.
    private func drawConnectors(_ context: CGContext, frames: [MergeColumnFrame], layout: MergeLayout,
                                display: MergeDisplay, metrics: TextMetrics) {
        for index in display.regions.indices {
            guard let colors = colors(index, display: display) else { continue }
            for k in 0 ..< frames.count - 1 {
                let left = layout.spans[k][index], right = layout.spans[k + 1][index]
                let x0 = frames[k].maxX, x1 = frames[k + 1].x
                let l0 = metrics.y(ofRow: left.lowerBound), l1 = metrics.y(ofRow: left.upperBound)
                let r0 = metrics.y(ofRow: right.lowerBound), r1 = metrics.y(ofRow: right.upperBound)
                let path = CGMutablePath()
                let mid = (x0 + x1) / 2
                path.move(to: CGPoint(x: x0, y: l0))
                path.addCurve(to: CGPoint(x: x1, y: r0), control1: CGPoint(x: mid, y: l0), control2: CGPoint(x: mid, y: r0))
                path.addLine(to: CGPoint(x: x1, y: r1))
                path.addCurve(to: CGPoint(x: x0, y: l1), control1: CGPoint(x: mid, y: r1), control2: CGPoint(x: mid, y: l1))
                path.closeSubpath()
                context.addPath(path)
                context.setFillColor(colors.band)
                context.fillPath()
                context.addPath(path)
                context.setStrokeColor(colors.border)
                context.setLineWidth(1)
                context.strokePath()
            }
        }
    }
}

/// The header above the merge view: "A <file>", the state of the merge in
/// the middle (a red count and "Unresolved Conflicts", or "Resolved
/// Document"), and "B <file>". In Unified, A and B sit together over the
/// interleaved column and the state over the result.
@MainActor
final class MergeHeaderView: BarView {
    let labelA = NSTextField(labelWithString: "A")
    let nameA = NSTextField(labelWithString: "")
    let labelB = NSTextField(labelWithString: "B")
    let nameB = NSTextField(labelWithString: "")
    let countBadge = CountBadge()
    let statusLabel = NSTextField(labelWithString: "")
    private var columns: [MergeColumnFrame] = []
    private var unified = false

    init() {
        super.init(hairline: .bottom)
        for label in [labelA, labelB] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = .secondaryLabelColor
        }
        for field in [nameA, nameB, statusLabel] {
            field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small) + 1)
            field.lineBreakMode = .byTruncatingMiddle
        }
        nameA.setAccessibilityIdentifier("prism.mergeNameA")
        nameB.setAccessibilityIdentifier("prism.mergeNameB")
        statusLabel.setAccessibilityIdentifier("prism.mergeStatus")
        for view in [labelA, nameA, labelB, nameB, countBadge, statusLabel] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setNames(a: String, b: String) {
        nameA.stringValue = a
        nameB.stringValue = b
        needsLayout = true
    }

    /// Shows the number of unresolved conflicts, or that the merge is
    /// resolved when there is none.
    func setUnresolved(_ count: Int) {
        countBadge.count = count
        countBadge.isHidden = count == 0
        statusLabel.stringValue = count == 0 ? "Resolved Document" : "Unresolved Conflicts"
        statusLabel.setAccessibilityValue(count == 0 ? "Resolved Document" : "\(count) Unresolved Conflicts")
        needsLayout = true
    }

    var statusText: String { countBadge.isHidden ? statusLabel.stringValue : "(\(countBadge.count)) \(statusLabel.stringValue)" }

    func setColumns(_ columns: [MergeColumnFrame], unified: Bool) {
        self.columns = columns
        self.unified = unified
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height - 1
        func center(_ view: NSView) -> CGFloat { floor((height - view.frame.height) / 2) }
        for field in [labelA, nameA, labelB, nameB, statusLabel] { field.sizeToFit() }
        countBadge.frame.size = countBadge.intrinsicContentSize
        func place(_ label: NSTextField, _ name: NSTextField, at x: CGFloat, limit: CGFloat) -> CGFloat {
            label.frame.origin = NSPoint(x: x, y: center(label))
            let nameX = label.frame.maxX + 8
            name.frame = NSRect(x: nameX, y: center(name), width: max(min(name.frame.width, limit - nameX), 0),
                                height: name.frame.height)
            return name.frame.maxX
        }
        let first = columns.first ?? MergeColumnFrame(x: 0, width: bounds.width / 3, gutter: 0, twoNumbers: false)
        let middle = columns.count > 1 ? columns[1] : first
        let statusWidth = (countBadge.isHidden ? 0 : countBadge.frame.width + 6) + statusLabel.frame.width
        let statusX = floor(middle.x + (middle.width - statusWidth) / 2)
        if unified {
            let end = place(labelA, nameA, at: first.x + 12, limit: first.maxX / 2 + first.x / 2)
            _ = place(labelB, nameB, at: end + 24, limit: first.maxX - 8)
        } else {
            _ = place(labelA, nameA, at: first.x + 12, limit: first.maxX - 8)
            let last = columns.last ?? first
            _ = place(labelB, nameB, at: last.x + 12, limit: last.maxX - 8)
        }
        countBadge.frame.origin = NSPoint(x: statusX, y: center(countBadge))
        statusLabel.frame.origin = NSPoint(x: statusX + (countBadge.isHidden ? 0 : countBadge.frame.width + 6),
                                           y: center(statusLabel))
    }
}

/// A small red-outlined circle with a number in it.
@MainActor
final class CountBadge: NSView {
    var count = 0 { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }

    private var text: NSAttributedString {
        NSAttributedString(string: String(count), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    override var intrinsicContentSize: NSSize {
        let size = text.size()
        return NSSize(width: max(ceil(size.width) + 10, 18), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(srgbRed: 0.98, green: 0.84, blue: 0.84, alpha: 1).setFill()
        path.fill()
        NSColor(srgbRed: 0.71, green: 0.27, blue: 0.27, alpha: 1).setStroke()
        path.stroke()
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityValue() -> Any? { String(count) }
}
