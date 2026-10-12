// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// The drop target of an empty window or tab: a large rounded triangle
/// (Prism's shape) holding a small still life of a folder, a document and
/// a picture, and a caption. Files or folders dropped on it, or chosen
/// after a click, start a comparison; a single file waits for its partner.
@MainActor
final class LaunchDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?

    let caption = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    private var highlighted = false { didSet { needsDisplay = true } }
    private var pendingNames: [String] = []

    static let dropCaption = "Drop Files Here to Compare"

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        caption.font = .systemFont(ofSize: 24, weight: .regular)
        caption.textColor = .tertiaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.setAccessibilityIdentifier("prism.launch.caption")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.alignment = .center
        subtitle.setAccessibilityIdentifier("prism.launch.subtitle")
        addSubview(caption)
        addSubview(subtitle)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("prism.launch")
        setAccessibilityHelp("Drop files or folders here, or press to choose them.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Files received so far (none, or one waiting for its partner).
    func setPending(_ files: [URL]) {
        pendingNames = files.map(\.lastPathComponent)
        if let name = pendingNames.first {
            caption.stringValue = "Drop One More File"
            subtitle.stringValue = "\u{201C}\(name)\u{201D} needs a second file to compare with."
        } else {
            caption.stringValue = Self.dropCaption
            subtitle.stringValue = "Or click to choose two files or two folders."
        }
        setAccessibilityLabel(caption.stringValue)
        setAccessibilityValue(pendingNames.first ?? "")
        needsLayout = true
        needsDisplay = true
    }

    /// The triangle with rounded sides, fitted in `rect`, apex up (in this
    /// flipped view, apex at the smallest y).
    static func trianglePath(in rect: NSRect) -> NSBezierPath {
        let side = min(rect.width, rect.height * 1.12)
        let height = side * 0.87
        let top = NSPoint(x: rect.midX, y: rect.midY - height / 2)
        let left = NSPoint(x: rect.midX - side / 2, y: rect.midY + height / 2)
        let right = NSPoint(x: rect.midX + side / 2, y: rect.midY + height / 2)
        // Each side bulges outward: a quadratic arc through a control point
        // pushed away from the centroid.
        let centroid = NSPoint(x: (top.x + left.x + right.x) / 3, y: (top.y + left.y + right.y) / 3)
        func control(_ p: NSPoint, _ q: NSPoint) -> NSPoint {
            let mid = NSPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
            let dx = mid.x - centroid.x, dy = mid.y - centroid.y
            let bulge: CGFloat = 0.55
            return NSPoint(x: mid.x + dx * bulge, y: mid.y + dy * bulge)
        }
        let path = NSBezierPath()
        path.move(to: top)
        for (p, q) in [(top, right), (right, left), (left, top)] {
            let c = control(p, q)
            // Quadratic to cubic.
            path.curve(to: q, controlPoint1: NSPoint(x: p.x + 2 / 3 * (c.x - p.x), y: p.y + 2 / 3 * (c.y - p.y)),
                       controlPoint2: NSPoint(x: q.x + 2 / 3 * (c.x - q.x), y: q.y + 2 / 3 * (c.y - q.y)))
        }
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    var triangleRect: NSRect {
        let width = min(bounds.width - 120, 280)
        let height = width * 0.98
        return NSRect(x: floor((bounds.width - width) / 2), y: max(floor(bounds.height * 0.42 - height / 2), 24),
                      width: width, height: height)
    }

    override func layout() {
        super.layout()
        let rect = triangleRect
        caption.sizeToFit()
        caption.frame = NSRect(x: 16, y: rect.maxY + 34, width: bounds.width - 32, height: caption.frame.height)
        subtitle.sizeToFit()
        subtitle.frame = NSRect(x: 16, y: caption.frame.maxY + 6, width: bounds.width - 32, height: subtitle.frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        let rect = triangleRect
        let path = Self.trianglePath(in: rect)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.03)).setFill()
        path.fill()
        path.lineWidth = highlighted ? 3 : 2
        (highlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
        drawStillLife(around: NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.08), size: rect.width * 0.42)
    }

    /// A folder behind, a text document on the right and a picture in
    /// front on the left, drawn from system symbols in soft colours.
    private func drawStillLife(around center: NSPoint, size: CGFloat) {
        func draw(_ symbol: String, _ color: NSColor, _ rect: NSRect, angle: CGFloat = 0) {
            let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .light)
                .applying(.init(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: angle)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        let s = size
        draw("folder.fill", NSColor.systemTeal.withAlphaComponent(0.45),
             NSRect(x: center.x - s * 0.55, y: center.y - s * 0.55, width: s * 0.8, height: s * 0.62))
        draw("doc.text.fill", NSColor.secondaryLabelColor.withAlphaComponent(0.55),
             NSRect(x: center.x + s * 0.02, y: center.y - s * 0.38, width: s * 0.5, height: s * 0.64), angle: 4)
        draw("photo.fill", NSColor.systemPurple.withAlphaComponent(0.5),
             NSRect(x: center.x - s * 0.42, y: center.y - s * 0.02, width: s * 0.6, height: s * 0.46), angle: -12)
    }

    // MARK: input

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if Self.trianglePath(in: triangleRect).contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    // Keyboard: the drop area takes the focus, shows the focus ring, and
    // Return, Enter or Space opens the file chooser, like a click.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if plain, Self.pressKeys.contains(event.keyCode) {
            onClick?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Return, keypad Enter and Space.
    static let pressKeys: Set<UInt16> = [36, 76, 49]

    override var focusRingMaskBounds: NSRect { triangleRect }

    override func drawFocusRingMask() {
        Self.trianglePath(in: triangleRect).fill()
    }

    private func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let ok = !fileURLs(sender).isEmpty
        highlighted = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlighted = false }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
