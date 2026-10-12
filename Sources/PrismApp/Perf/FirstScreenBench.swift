// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import DiffCore
import Foundation

/// Headless first-screen bench for the performance suite
/// (`scripts/perf/run.sh`): `Prism --bench-first-screen [options] A B`.
///
/// Runs the work between opening a text comparison and its first paint,
/// without showing anything: no window is ordered in and no run loop
/// runs; the entry point (`PrismAppMain`) also sets the activation policy
/// to `.prohibited`, so there is no Dock icon or menu bar.
///
///   read    both files through the importer the app uses
///   build   the diff and the comparison model (ComparisonModel.build)
///   layout  the comparison view hosted in an offscreen window, sized,
///           shown the model and laid out
///   draw    the first screen drawn into an offscreen bitmap
///
/// Prints one JSON object with the times in milliseconds (`totalMs` is
/// read + build + layout + draw), the change and line counts, whether both
/// panes drew, and the resident memory. Exit status 0, or 2 on a usage or
/// read error.
@MainActor
enum FirstScreenBench {
    static let argument = "--bench-first-screen"

    static let usage = """
        usage: Prism \(argument) [--mode blocks|fluid|unified] [--wrap] [--width PT] [--height PT] A B
        """

    static func run(_ arguments: [String]) -> Int32 {
        var mode = ViewMode.blocks, wraps = false
        var size = NSSize(width: 1354, height: 800)
        var files: [String] = []
        var rest = arguments.makeIterator()
        while let argument = rest.next() {
            switch argument {
            case "--mode":
                guard let value = rest.next().flatMap(ViewMode.init(rawValue:)) else { return fail("bad --mode") }
                mode = value
            case "--wrap": wraps = true
            case "--width":
                guard let value = rest.next().flatMap(Double.init), value >= 200 else { return fail("bad --width") }
                size.width = value
            case "--height":
                guard let value = rest.next().flatMap(Double.init), value >= 200 else { return fail("bad --height") }
                size.height = value
            default:
                if argument.hasPrefix("-") { return fail("unknown option \(argument)") }
                files.append(argument)
            }
        }
        guard files.count == 2 else { return fail("needs two files") }

        _ = NSApplication.shared

        let clock = Clock()
        let source = TextSources.current
        let a: LoadedText, b: LoadedText
        do {
            a = try source.load(URL(filePath: files[0]))
            b = try source.load(URL(filePath: files[1]))
        } catch {
            return fail("cannot read: \(error.localizedDescription)")
        }
        let readMs = clock.lap()
        let model: ComparisonModel
        do {
            model = try ComparisonModel.build(a: a, b: b, whitespace: .exact)
        } catch {
            return fail("diff failed: \(error)")
        }
        let buildMs = clock.lap()

        let view = BlocksDiffView(font: .monospacedSystemFont(ofSize: TextSettings.defaultFontSize, weight: .regular), theme: BuiltinThemes.multicolorLight)
        var painted = false
        view.onFirstPaint = { painted = true }
        // Never ordered in: the window only gives the view a backing scale
        // and a size.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.setMode(mode)
        view.setWrapsLines(wraps)
        view.show(model)
        view.layoutSubtreeIfNeeded()
        let layoutMs = clock.lap()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return fail("cannot allocate the offscreen bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let drawMs = clock.lap()

        let result: [String: Any] = [
            "event": "firstScreen",
            "mode": mode.rawValue,
            "wraps": wraps,
            "width": Double(size.width),
            "height": Double(size.height),
            "readMs": PerfLog.rounded(readMs),
            "diffMs": PerfLog.rounded(model.diffMilliseconds),
            "buildMs": PerfLog.rounded(buildMs),
            "layoutMs": PerfLog.rounded(layoutMs),
            "drawMs": PerfLog.rounded(drawMs),
            "totalMs": PerfLog.rounded(readMs + buildMs + layoutMs + drawMs),
            "changes": model.changeCount,
            "linesA": model.a.lineCount,
            "linesB": model.b.lineCount,
            "painted": painted,
            "rssMB": PerfLog.rounded(PerfLog.residentMegabytes()),
        ]
        withExtendedLifetime(window) {}
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else {
            return fail("cannot encode the result")
        }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("Prism \(argument): \(message)\n\(usage)\n".utf8))
        return 2
    }

    /// Milliseconds between successive laps.
    private final class Clock {
        private var last = DispatchTime.now().uptimeNanoseconds

        func lap() -> Double {
            let now = DispatchTime.now().uptimeNanoseconds
            defer { last = now }
            return Double(now - last) / 1e6
        }
    }
}
