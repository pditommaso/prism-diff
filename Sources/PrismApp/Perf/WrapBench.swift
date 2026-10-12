// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import QuartzCore

/// Wrap stress run, started when `PRISM_BENCH_WRAP=1` and a perf log is
/// set. It turns Wrap Lines on, then resizes the window three times, one
/// step per display frame as a live resize does, ending at
/// `PRISM_BENCH_WRAP_WIDTH` points wide (default 600). After every resize
/// it checks that A and B are still aligned; at the final width it also
/// scrolls through part of the document. Missed frames are counted as in
/// `ScrollBench`.
@MainActor
final class WrapBench: NSObject {
    private let view: BlocksDiffView
    private let window: NSWindow
    private var driver: FrameDriver?
    private var results: [String: Any] = [:]
    private var resizes: [[String: Any]] = []
    private var alignmentWorst: CGFloat = 0

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["PRISM_BENCH_WRAP"] == "1" && PerfLog.isEnabled
    }

    static var finalWidth: CGFloat {
        CGFloat(Double(ProcessInfo.processInfo.environment["PRISM_BENCH_WRAP_WIDTH"] ?? "") ?? 600)
    }

    init(view: BlocksDiffView, window: NSWindow) {
        self.view = view
        self.window = window
    }

    func run() {
        view.setWrapsLines(true)
        view.selectChange(view.model.map { $0.changeCount / 2 }, scroll: true)
        let start = window.frame.width
        let widths = [max(start - 300, 900), 1100, Self.finalWidth]
        resize(through: widths[...], from: start)
    }

    private func resize(through widths: ArraySlice<CGFloat>, from width: CGFloat) {
        guard let target = widths.first else {
            scrollAtFinalWidth()
            return
        }
        let steps = 40
        let origin = window.frame.origin
        let height = window.frame.height
        driver = FrameDriver(view: view, frames: steps, step: { [window] index in
            let fraction = CGFloat(index + 1) / CGFloat(steps)
            let current = (width + (target - width) * fraction).rounded()
            window.setFrame(NSRect(x: origin.x, y: origin.y, width: current, height: height), display: true)
        }, done: { [weak self] summary in
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            let error = self.view.visibleAlignmentError()
            self.alignmentWorst = max(self.alignmentWorst, error)
            var entry = summary
            entry["width"] = Double(self.window.frame.width)
            entry["alignmentErrorPt"] = Double(error)
            entry["wrapColumns"] = [self.view.wrapColumns.a, self.view.wrapColumns.b]
            self.resizes.append(entry)
            self.resize(through: widths.dropFirst(), from: target)
        })
        driver?.start()
    }

    private func scrollAtFinalWidth() {
        let start = view.scrollY
        driver = FrameDriver(view: view, frames: 300, step: { [view] index in
            view.scroll(toY: start + CGFloat(index + 1) * 24)
        }, sample: { [weak self] in
            guard let self else { return }
            self.alignmentWorst = max(self.alignmentWorst, self.view.visibleAlignmentError())
        }, done: { [weak self] summary in
            guard let self else { return }
            self.results["resizes"] = self.resizes
            self.results["resizeMissedFrames"] = self.resizes.reduce(0) { $0 + ($1["missedFrames"] as? Int ?? 0) }
            self.results["scroll"] = summary
            self.results["alignmentErrorMaxPt"] = Double(self.alignmentWorst)
            self.results["windowWidth"] = Double(self.window.frame.width)
            self.results["wraps"] = self.view.wrapsLines
            self.results["screenMaxFPS"] = self.window.screen?.maximumFramesPerSecond ?? 0
            PerfLog.record("wrapBench", self.results)
        })
        driver?.start()
    }
}

/// Calls `step` once per display frame, `frames` times, forcing display
/// and commit inside the frame, then `done` with the frame statistics.
@MainActor
final class FrameDriver: NSObject {
    private let view: NSView
    private let frames: Int
    private let step: (Int) -> Void
    private let sample: (() -> Void)?
    private let done: ([String: Any]) -> Void
    private var link: CADisplayLink?
    private var frame = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var work: [Double] = []
    private var nominal: Double = 1000.0 / 120

    init(view: NSView, frames: Int, step: @escaping (Int) -> Void, sample: (() -> Void)? = nil,
         done: @escaping ([String: Any]) -> Void) {
        self.view = view
        self.frames = frames
        self.step = step
        self.sample = sample
        self.done = done
    }

    func start() {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(view.window?.screen?.maximumFramesPerSecond ?? 120)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp > 0 { intervals.append((link.timestamp - lastTimestamp) * 1000) }
        if link.duration > 0 { nominal = link.duration * 1000 }
        lastTimestamp = link.timestamp
        let start = CACurrentMediaTime()
        step(frame)
        view.window?.displayIfNeeded()
        CATransaction.flush()
        work.append((CACurrentMediaTime() - start) * 1000)
        if frame % 25 == 0 { sample?() }
        frame += 1
        if frame >= frames {
            link.invalidate()
            self.link = nil
            done(summary())
        }
    }

    private func summary() -> [String: Any] {
        var missed = 0
        for interval in intervals where interval > nominal * 1.5 {
            missed += Int((interval / nominal).rounded()) - 1
        }
        let sorted = work.sorted()
        let slow = work.enumerated().filter { $0.element > nominal * 1.5 }.prefix(10)
            .map { "\($0.offset):\(PerfLog.rounded($0.element))" }
        return [
            "slowFrames": Array(slow),
            "frames": work.count,
            "missedFrames": missed,
            "workAvgMs": PerfLog.rounded(work.isEmpty ? 0 : work.reduce(0, +) / Double(work.count)),
            "workMaxMs": PerfLog.rounded(sorted.last ?? 0),
            "periodMs": PerfLog.rounded(nominal),
        ]
    }
}
