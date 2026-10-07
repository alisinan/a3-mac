import AppKit
import QuartzCore
import CoreGraphics

/// CADisplayLink retains its target. A weak proxy keeps the driver free to
/// deinitialize and invalidate the link instead of forming a retain cycle.
@available(macOS 14.0, *)
private final class ScreenFrameTarget: NSObject {
    weak var owner: DisplayRefreshDriver?

    @objc func step(_ link: CADisplayLink) {
        owner?.displayFrame(targetTime: link.targetTimestamp)
    }
}

/// The physical A3 screen supplies the cadence. Callbacks run directly on the
/// main run loop; no background queue, C pointer or cross-thread lock is needed.
final class DisplayRefreshDriver {
    var onFrame: ((Double) -> Void)?
    private(set) var modeDescription = "Timer fallback 60 Hz"
    private(set) var isActive = false
    private var displayID: CGDirectDisplayID?
    // A cleanup closure owns the link without exposing a macOS-14-only stored
    // type. Older macOS versions can still use the existing timer fallback.
    private var invalidateLink: (() -> Void)?
    private var callbackTarget: NSObject?
    private var fallback: Timer?

    deinit { stop() }

    func setDisplay(_ id: CGDirectDisplayID?) {
        guard displayID != id else { return }
        displayID = id
        if isActive { start() }
    }

    func start() {
        stop()
        isActive = true
        if #available(macOS 14.0, *), let displayID,
           let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
            let target = ScreenFrameTarget()
            target.owner = self
            let link = screen.displayLink(target: target, selector: #selector(ScreenFrameTarget.step(_:)))
            callbackTarget = target
            invalidateLink = { link.invalidate() }
            link.add(to: .main, forMode: .common)
            modeDescription = "Display cadence (NSScreen.displayLink)"
            return
        }
        modeDescription = "Timer fallback 60 Hz"
        let timer = Timer(timeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.onFrame?(ProcessInfo.processInfo.systemUptime)
        }
        fallback = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        isActive = false
        invalidateLink?()
        invalidateLink = nil
        callbackTarget = nil
        fallback?.invalidate()
        fallback = nil
    }

    fileprivate func displayFrame(targetTime: CFTimeInterval) {
        guard isActive else { return }
        // Convert only the time DIFFERENCE: CA media time and process uptime
        // need not have the same absolute origin. Prediction stays <=20 ms.
        let ahead = targetTime - CACurrentMediaTime()
        onFrame?(ProcessInfo.processInfo.systemUptime + min(0.020, max(0, ahead)))
    }
}
