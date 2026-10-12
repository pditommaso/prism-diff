// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit

/// Plain, system-styled About window: icon, name, version, licence,
/// disclaimer and a link to the source code.
@MainActor
final class AboutWindowController: NSWindowController {
    static let windowTitle = "About Prism"

    let content: AboutContent

    init(content: AboutContent = .current) {
        self.content = content
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = Self.windowTitle
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = makeContentView()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows the window and brings it to the front.
    func present() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        AppFocus.activate()
    }

    private func makeContentView() -> NSView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibleName("\(content.title) icon")
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
        ])

        let title = NSTextField(labelWithString: content.title)
        title.font = .boldSystemFont(ofSize: 18)

        let version = label(content.versionLine, size: NSFont.smallSystemFontSize)
        let license = label(content.licenseLine, size: NSFont.smallSystemFontSize)
        let disclaimer = NSTextField(wrappingLabelWithString: content.disclaimer)
        disclaimer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        disclaimer.textColor = .secondaryLabelColor
        disclaimer.alignment = .center
        disclaimer.preferredMaxLayoutWidth = 300

        let link = NSButton(title: "Source code", target: self, action: #selector(openSource(_:)))
        link.bezelStyle = .inline

        let stack = NSStackView(views: [icon, title, version, license, disclaimer, link])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.setCustomSpacing(12, after: icon)
        stack.setCustomSpacing(14, after: disclaimer)
        return stack
    }

    private func label(_ text: String, size: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = .secondaryLabelColor
        return field
    }

    @objc private func openSource(_ sender: Any?) {
        NSWorkspace.shared.open(content.sourceURL)
    }
}
