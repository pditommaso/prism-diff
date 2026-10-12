// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Paolo Di Tommaso

import AppKit
import QuartzCore

/// Scroll stress run, started when `PRISM_BENCH_SCROLL=1` and a perf log is
/// set. A display link at the screen's maximum rate moves the comparison by
/// a fixed step per frame and forces display and commit inside the frame.
/// A frame is missed when consecutive callbacks are more than 1.5 refresh
/// periods apart; each extra period counts as one missed frame.
///
/// Two passes, and a third for very wide documents:
/// - smooth: 24 pt per frame for 600 frames from the top;
/// - full document: 0.9 screenful per frame from the top to the bottom, so
///   every frame shows entirely new rows;
/// - horizontal (documents over four screens wide): 0.9 screen to the right
///   per frame, up to 300 frames.
@MainActor
final class ScrollBench: NSObject {
    private let view: BlocksDiffView
    private var link: CADisplayLink?
    private var step: ((Int) -> Bool)?
    private var finish: (() -> Void)?
    private var frame = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var work: [Double] = []
    private var nominal: Double = 1000.0 / 120
    private var alignmentWorst: CGFloat = 0
    private var results: [String: Any] = [:]

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["PRISM_BENCH_SCROLL"] == "1" && PerfLog.isEnabled
    }

    init(view: BlocksDiffView) {
        self.view = view
    }

    func run() {
        view.scroll(toY: 0)
        results["screenMaxFPS"] = view.window?.screen?.maximumFramesPerSecond ?? 0
        pass(named: "smooth", step: { [view] index in
            view.scroll(toY: CGFloat(index + 1) * 24)
            return index + 1 < 600
        }) { [weak self] in
            guard let self else { return }
            view.scroll(toY: 0)
            let stride = view.scrollA.contentView.bounds.height * 0.9
            pass(named: "fullDocument", step: { [view] index in
                let y = CGFloat(index + 1) * stride
                view.scroll(toY: y)
                return y < view.paneA.frame.height - view.scrollA.contentView.bounds.height
            }) { [weak self] in
                guard let self else { return }
                results["alignmentErrorMaxPt"] = Double(alignmentWorst)
                // A document much wider than the window (a very long line):
                // also sweep sideways, 0.9 screen per frame.
                let clip = view.scrollA.contentView.bounds
                guard view.paneA.frame.width > clip.width * 4 else {
                    PerfLog.record("scrollBench", results)
                    return
                }
                view.scroll(toY: 0)
                pass(named: "horizontal", step: { [view] index in
                    let x = CGFloat(index + 1) * clip.width * 0.9
                    view.scrollA.contentView.scroll(to: NSPoint(x: x, y: 0))
                    view.scrollA.reflectScrolledClipView(view.scrollA.contentView)
                    return index + 1 < 300 && x < view.paneA.frame.width - clip.width
                }) { [weak self] in
                    guard let self else { return }
                    results["documentWidth"] = Double(view.paneA.frame.width)
                    PerfLog.record("scrollBench", results)
                }
            }
        }
    }

    private func pass(named name: String, step: @escaping (Int) -> Bool, then: @escaping () -> Void) {
        frame = 0
        lastTimestamp = 0
        intervals = []
        work = []
        self.step = step
        finish = { [weak self] in
            guard let self else { return }
            results[name] = summary()
            then()
        }
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
        let more = step?(frame) ?? false
        view.window?.displayIfNeeded()
        CATransaction.flush()
        work.append((CACurrentMediaTime() - start) * 1000)
        if frame % 25 == 0 { alignmentWorst = max(alignmentWorst, view.visibleAlignmentError()) }
        frame += 1
        if !more {
            link.invalidate()
            self.link = nil
            finish?()
        }
    }

    private func summary() -> [String: Any] {
        var missed = 0
        for interval in intervals where interval > nominal * 1.5 {
            missed += Int((interval / nominal).rounded()) - 1
        }
        let sorted = work.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        return [
            "frames": work.count,
            "missedFrames": missed,
            "workAvgMs": PerfLog.rounded(work.isEmpty ? 0 : work.reduce(0, +) / Double(work.count)),
            "workP95Ms": PerfLog.rounded(p95),
            "workMaxMs": PerfLog.rounded(sorted.last ?? 0),
            "periodMs": PerfLog.rounded(nominal),
        ]
    }
}
