// A3 Monitor — turns the Lenovo ThinkReality A3 into a normal 2D monitor on macOS.
//
// 1. Creates a 1920×1080 virtual display that macOS treats like a regular monitor.
// 2. Captures it live with ScreenCaptureKit.
// 3. Draws the same image into both halves of the A3's 3840×1080 side-by-side panel
//    (or only one half), so both eyes see one flat screen.
// 4. Turns the glasses' display on over USB-HID (HostInfo command) when needed.

import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import IOKit.hid
import QuartzCore
import ServiceManagement
import WebKit

// MARK: - Glasses (USB-HID)

enum Glasses {
    static let vendorID = 0x17EF
    static let productID = 0xB813

    /// Sends HostInfo(host = 0, mode) on the 128-byte command interface.
    /// Packet: 'O' 'B' 03 C1 <host> <mode> ... (128 bytes, report ID 0).
    @discardableResult
    static func sendHostInfo(mode: UInt8 = 1) -> Bool {
        let none = IOOptionBits(kIOHIDOptionsTypeNone)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, none)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: 0x8C,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, none)
        defer { IOHIDManagerClose(manager, none) }
        if openResult != kIOReturnSuccess {
            NSLog("A3: IOHIDManagerOpen failed (\(openResult))")
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            return false
        }
        for device in devices {
            let size = (IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? NSNumber)?.intValue ?? 0
            guard size == 128 else { continue }
            var packet = [UInt8](repeating: 0, count: 128)
            packet[0] = 0x4F; packet[1] = 0x42; packet[2] = 0x03; packet[3] = 0xC1
            packet[4] = 0; packet[5] = mode
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &packet, packet.count)
            NSLog("A3: HostInfo(0, \(mode)) -> \(result == kIOReturnSuccess ? "OK" : "error \(result)")")
            return result == kIOReturnSuccess
        }
        NSLog("A3: 128-byte command interface not found")
        return false
    }
}

// MARK: - Virtual display

final class VirtualScreen {
    private var display: CGVirtualDisplay?
    var displayID: CGDirectDisplayID { display?.displayID ?? 0 }

    func create(width: Int, height: Int) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Glasses Screen"
        descriptor.maxPixelsWide = 1920
        descriptor.maxPixelsHigh = 1080
        descriptor.sizeInMillimeters = CGSize(width: 487, height: 274)  // behaves like a ~22" monitor
        descriptor.vendorID = 0x7A3A
        descriptor.productID = 0xA3A3
        descriptor.serialNum = 1
        display = CGVirtualDisplay(descriptor: descriptor)
        apply(width: width, height: height)
    }

    func apply(width: Int, height: Int) {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: 60)]
        if display?.apply(settings) != true {
            NSLog("A3: applying virtual display settings failed")
        }
    }

    var pixelSize: PixelSize {
        let id = displayID
        return PixelSize(w: CGDisplayPixelsWide(id), h: CGDisplayPixelsHigh(id))
    }
}

struct PixelSize: Equatable {
    var w: Int
    var h: Int
}

// MARK: - Capture

final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "a3.capture", qos: .userInteractive)
    var onFrame: ((IOSurface) -> Void)?
    var onStop: (() -> Void)?

    func start(displayID: CGDirectDisplayID, size: PixelSize, completion: @escaping (Bool, String) -> Void) {
        stop()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error {
                DispatchQueue.main.async {
                    completion(false, "Screen Recording permission needed (\(error.localizedDescription))")
                }
                return
            }
            guard let content, let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                DispatchQueue.main.async { completion(false, "Waiting for virtual display…") }
                return
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = size.w
            config.height = size.h
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = true
            config.queueDepth = 6

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
            } catch {
                DispatchQueue.main.async { completion(false, "Capture setup failed: \(error.localizedDescription)") }
                return
            }
            self.stream = stream
            stream.startCapture { error in
                DispatchQueue.main.async {
                    if let error {
                        completion(false, "Capture failed: \(error.localizedDescription)")
                    } else {
                        completion(true, "")
                    }
                }
            }
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let unmanaged = CVPixelBufferGetIOSurface(pixelBuffer)
        else { return }
        let surface: IOSurface = unmanaged.takeUnretainedValue()
        DispatchQueue.main.async { [weak self] in self?.onFrame?(surface) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("A3: stream stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            self?.stream = nil
            self?.onStop?()
        }
    }
}

// MARK: - Output window on the glasses

enum EyeMode: String {
    case both, left, right
}

final class EyeWindow {
    let window: NSWindow
    private let containers = [CALayer(), CALayer()]
    private let images = [CALayer(), CALayer()]
    var mode: EyeMode = .both
    var shift: CGFloat = 0  // horizontal shift per eye, in pixels (changes perceived distance)
    var lift: CGFloat = 0   // vertical offset in pixels, positive = up
    var scale: CGFloat = 1  // image size within each eye (1 = full)
    var headOrientation: TrackingQuaternion = .identity
    var horizontalFOV: Double = 42  // approximate optical FOV; adjustable in tracking UI

    init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.canHide = false

        let noAnim: [String: CAAction] = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "frame": NSNull(),
            "transform": NSNull(),
        ]
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        for i in 0..<2 {
            containers[i].masksToBounds = true
            containers[i].backgroundColor = NSColor.black.cgColor
            containers[i].actions = noAnim
            images[i].contentsGravity = .resizeAspect
            images[i].magnificationFilter = .linear
            images[i].minificationFilter = .linear
            images[i].actions = noAnim
            containers[i].addSublayer(images[i])
            root.addSublayer(containers[i])
        }
        window.contentView = view
    }

    func place(on screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        for layer in images { layer.contentsScale = screen.backingScaleFactor }
        layout()
        window.orderFrontRegardless()
    }

    func layout() {
        let size = window.frame.size
        let half = size.width / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<2 {
            containers[i].frame = CGRect(x: CGFloat(i) * half, y: 0, width: half, height: size.height)
            let dx: CGFloat = mode == .both ? (i == 0 ? shift : -shift) : 0
            let w = half * scale, h = size.height * scale
            // Do not set frame on a transformed CALayer. Bounds describe the
            // source plane; position is the projection's fixed optical centre.
            images[i].bounds = CGRect(x: 0, y: 0, width: w, height: h)
            images[i].position = CGPoint(x: half / 2, y: size.height / 2)
            let projection = MonitorProjection(head: headOrientation,
                width: Double(half), height: Double(size.height), scale: Double(scale),
                shift: Double(dx), lift: Double(lift), horizontalFOV: horizontalFOV)
            var transform = CATransform3DIdentity
            transform.m11 = CGFloat(projection.m11); transform.m12 = CGFloat(projection.m12)
            transform.m14 = CGFloat(projection.m14)
            transform.m21 = CGFloat(projection.m21); transform.m22 = CGFloat(projection.m22)
            transform.m24 = CGFloat(projection.m24)
            transform.m41 = CGFloat(projection.m41); transform.m42 = CGFloat(projection.m42)
            transform.m44 = CGFloat(projection.m44)
            images[i].transform = transform
            images[i].isHidden = !projection.isVisible
        }
        containers[0].isHidden = mode == .right
        containers[1].isHidden = mode == .left
        CATransaction.commit()
    }

    func updateTracking(head: TrackingQuaternion, horizontalFOV: Double) {
        headOrientation = head
        self.horizontalFOV = horizontalFOV
        layout()
    }

    func show(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        images[0].contents = surface
        images[1].contents = surface
        CATransaction.commit()
    }

    func hide() {
        window.orderOut(nil)
        images.forEach { $0.contents = nil }
    }
}


// MARK: - Prompter (control window on the Mac, display drawn straight onto the glasses)

/// Avoids the retain cycle WKUserContentController → handler.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

final class Prompter: NSObject, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    private var controlWindow: NSWindow?
    private var displayWindow: NSWindow?
    private var controlWeb: WKWebView?
    private var displayWeb: WKWebView?
    var onClose: (() -> Void)?

    var isOpen: Bool { controlWindow != nil }

    private var pageURL: URL? { Bundle.main.url(forResource: "a3_prompter", withExtension: "html") }

    private func makeWebView(role: String) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptHandler(self), name: "a3")
        config.userContentController.addUserScript(
            WKUserScript(source: "window.__A3_ROLE = '\(role)';", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        if role == "display" {
            web.setValue(false, forKey: "drawsBackground")  // stay black (= transparent on the glasses) while loading
        }
        return web
    }

    func open(on target: NSScreen?) {
        if let w = controlWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        guard let url = pageURL else { NSLog("A3: a3_prompter.html missing from app bundle"); return }

        // Control window on the main screen
        let web = makeWebView(role: "control")
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "A3 Prompter"
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.delegate = self
        if let main = NSScreen.screens.first {
            let f = main.visibleFrame
            win.setFrameOrigin(NSPoint(x: f.midX - 590, y: f.midY - 380))
        }
        controlWeb = web
        controlWindow = win
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(web)

        // Display window on the virtual Glasses Screen
        let dweb = makeWebView(role: "display")
        let dwin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        dwin.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        dwin.backgroundColor = .black
        dwin.isOpaque = true
        dwin.hasShadow = false
        dwin.ignoresMouseEvents = true
        dwin.isReleasedWhenClosed = false
        dwin.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        dwin.canHide = false
        dwin.contentView = dweb
        displayWeb = dweb
        displayWindow = dwin
        place(on: target)
        // The display page is loaded once the control page is ready (see didFinish), so its "hello" is heard.
    }

    /// The display page goes full-screen on the 1920×1080 virtual "Glasses Screen";
    /// the monitor mirror then copies it to both eyes, exactly like the desktop.
    func place(on target: NSScreen?) {
        guard let dwin = displayWindow else { return }
        if let g = target {
            dwin.setFrame(g.frame, display: true)
            dwin.orderFrontRegardless()
        } else {
            dwin.orderOut(nil)
        }
    }

    func close() {
        controlWindow?.close()
    }

    // Control page loaded → load the display page
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === controlWeb, let url = pageURL, let dweb = displayWeb, dweb.url == nil {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.fragment = "display"
            if let durl = comps?.url {
                dweb.loadFileURL(durl, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }
    }

    // Relay messages between the two pages
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let json = message.body as? String else { return }
        let target = message.webView === controlWeb ? displayWeb : controlWeb
        target?.evaluateJavaScript("window.__a3Receive && window.__a3Receive(\(json));", completionHandler: nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === controlWindow else { return }
        displayWindow?.orderOut(nil)
        displayWeb?.configuration.userContentController.removeScriptMessageHandler(forName: "a3")
        controlWeb?.configuration.userContentController.removeScriptMessageHandler(forName: "a3")
        displayWindow = nil
        displayWeb = nil
        controlWeb = nil
        controlWindow = nil
        onClose?()
    }
}

// MARK: - Helpers

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let virtualScreen = VirtualScreen()
    private let capturer = Capturer()
    private let prompter = Prompter()
    private let rotationWindow = RotationWindow()
    private var monitorHead: TrackingQuaternion = .identity
    private var monitorFOV: Double = 42
    private var eyeWindow: EyeWindow?
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private var modeItems: [EyeMode: NSMenuItem] = [:]
    private var resolutionItems: [NSMenuItem] = []
    private var loginItem: NSMenuItem?

    private let defaults = UserDefaults.standard
    private var mode: EyeMode = .both
    private var shift: CGFloat = 0
    private var lift: CGFloat = 0
    private var scale: CGFloat = 1
    private var sizeItems: [NSMenuItem] = []
    private var resolution = PixelSize(w: 1920, h: 1080)

    private var streaming = false
    private var starting = false
    private var streamSize = PixelSize(w: 0, h: 0)
    private var pendingRefresh: DispatchWorkItem?
    private var lastKick = Date.distantPast
    private var lastGoodMouse: NSPoint?
    private var askedForCapture = false

    private let resolutions = [
        PixelSize(w: 1920, h: 1080), PixelSize(w: 1600, h: 900),
        PixelSize(w: 1280, h: 720), PixelSize(w: 1024, h: 576),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        mode = EyeMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .both
        shift = CGFloat(defaults.double(forKey: "shift"))
        lift = CGFloat(defaults.double(forKey: "lift"))
        let savedScale = defaults.double(forKey: "scale")
        scale = savedScale.isFinite && savedScale > 0 ? CGFloat(min(1, max(0.5, savedScale))) : 1
        rotationWindow.setImageScale(Double(scale))
        let w = defaults.integer(forKey: "resW"), h = defaults.integer(forKey: "resH")
        if w > 0 && h > 0 { resolution = PixelSize(w: w, h: h) }

        virtualScreen.create(width: resolution.w, height: resolution.h)
        buildMenu()
        buildEditMenu()
        prompter.onClose = { NSApp.deactivate() }  // never NSApp.hide: that would hide the glasses window too

        rotationWindow.onMonitorOrientation = { [weak self] head, fov in
            guard let self else { return }
            self.monitorHead = head ?? .identity
            self.monitorFOV = fov
            self.eyeWindow?.updateTracking(head: self.monitorHead, horizontalFOV: fov)
        }
        rotationWindow.onImageScaleChange = { [weak self] scale in
            guard let self, scale.isFinite else { return }
            self.scale = CGFloat(min(1, max(0.5, scale)))
            self.applyLayout()
        }

        capturer.onFrame = { [weak self] surface in self?.eyeWindow?.show(surface) }
        capturer.onStop = { [weak self] in
            self?.streaming = false
            self?.scheduleRefresh(after: 1)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Every few seconds: if the glasses are plugged in but their display is off, turn it on.
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.autoKick() }
        autoKick()
        scheduleRefresh(after: 1)

        // Keep the mouse out of the physical "Think A3" area (it's covered by our window).
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.guardMouse() }
    }

    private func guardMouse() {
        let p = NSEvent.mouseLocation
        guard let glasses = glassesScreen(), glasses.frame.contains(p) else {
            lastGoodMouse = p
            return
        }
        // Send the cursor back to where it was just before it entered the glasses area.
        guard let back = lastGoodMouse, let mainHeight = NSScreen.screens.first?.frame.height else { return }
        CGWarpMouseCursorPosition(CGPoint(x: back.x, y: mainHeight - back.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func applicationWillTerminate(_ notification: Notification) {
        capturer.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard rotationWindow.isRunning else { return .terminateNow }
        // Keep the run loop alive until Python has stopped its tracking session.
        rotationWindow.stop { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    // MARK: Screens

    private func glassesScreen() -> NSScreen? {
        let vid = virtualScreen.displayID
        let others = NSScreen.screens.filter { $0.displayID != vid }
        return others.first { $0.localizedName.contains("Think A3") }
            ?? others.first { $0.frame.width == 3840 && $0.frame.height == 1080 }
    }

    /// The glasses must run at their native 3840×1080 (1:1, not scaled), otherwise the two eye halves
    /// don't line up. macOS sometimes picks a scaled mode (e.g. "looks like 3008×846"); switch it back.
    /// Returns true if a mode change was requested.
    private var lastModeFix = Date.distantPast
    private func ensureNativeMode(_ screen: NSScreen) -> Bool {
        let id = screen.displayID
        guard let current = CGDisplayCopyDisplayMode(id) else { return false }
        if current.width == 3840 && current.height == 1080 && current.pixelWidth == 3840 && current.pixelHeight == 1080 {
            return false
        }
        guard Date().timeIntervalSince(lastModeFix) > 5 else { return false }
        lastModeFix = Date()
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let native = modes.first(where: {
                  $0.width == 3840 && $0.height == 1080 && $0.pixelWidth == 3840 && $0.pixelHeight == 1080
              })
        else {
            setStatus("Glasses not at 3840×1080 — set it in System Settings › Displays")
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, native, nil)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        NSLog("A3: switched glasses back to native 3840×1080 (\(result.rawValue))")
        setStatus("Restoring glasses resolution…")
        scheduleRefresh(after: 1.5)
        return result == .success
    }

    private func autoKick() {
        guard glassesScreen() == nil, Date().timeIntervalSince(lastKick) > 10 else { return }
        if Glasses.sendHostInfo() {
            lastKick = Date()
            setStatus("Turning on glasses display…")
        }
    }

    @objc private func screensChanged() {
        scheduleRefresh(after: 0.5)
        prompter.place(on: virtualNSScreen())
    }

    private func scheduleRefresh(after seconds: Double) {
        pendingRefresh?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func refresh() {
        guard let screen = glassesScreen() else {
            rotationWindow.setOutputDisplay(nil)
            capturer.stop()
            streaming = false
            eyeWindow?.hide()
            setStatus("Glasses display not found")
            return
        }
        if ensureNativeMode(screen) { return }  // mode switch triggers another refresh
        rotationWindow.setOutputDisplay(screen.displayID)
        if eyeWindow == nil { eyeWindow = EyeWindow() }
        eyeWindow!.mode = mode
        eyeWindow!.shift = shift
        eyeWindow!.lift = lift
        eyeWindow!.scale = scale
        eyeWindow!.headOrientation = monitorHead
        eyeWindow!.horizontalFOV = monitorFOV
        eyeWindow!.place(on: screen)

        // Ask for Screen Recording permission once; don't keep retrying (that re-triggers the prompt).
        if !CGPreflightScreenCaptureAccess() {
            if !askedForCapture {
                askedForCapture = true
                CGRequestScreenCaptureAccess()
            }
            setStatus("Allow Screen Recording, then quit & reopen A3 Monitor")
            return
        }

        var size = virtualScreen.pixelSize
        if size.w == 0 || size.h == 0 { size = resolution }
        if (streaming && size == streamSize) || starting { return }

        starting = true
        setStatus("Starting capture…")
        capturer.start(displayID: virtualScreen.displayID, size: size) { [weak self] ok, message in
            guard let self else { return }
            self.starting = false
            self.streaming = ok
            self.streamSize = size
            if ok {
                self.setStatus("Running · \(size.w)×\(size.h)")
            } else {
                self.setStatus(message)
                self.scheduleRefresh(after: 2)
            }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "A3"

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(item("Turn on glasses display", #selector(turnOn)))
        menu.addItem(item("Prompter…", #selector(openPrompter), key: "p"))
        menu.addItem(item("Head tracking…", #selector(openRotation), key: "t"))
        menu.addItem(item("Recenter monitor", #selector(recenterMonitor), key: "r"))
        menu.addItem(item("Stop head tracking", #selector(stopTracking)))
        menu.addItem(.separator())

        for (m, title) in [(EyeMode.both, "Both eyes"), (.left, "Left eye only"), (.right, "Right eye only")] {
            let it = item(title, #selector(pickMode(_:)))
            it.representedObject = m.rawValue
            modeItems[m] = it
            menu.addItem(it)
        }
        menu.addItem(.separator())

        let resMenu = NSMenu()
        for r in resolutions {
            let it = item("\(r.w) × \(r.h)", #selector(pickResolution(_:)))
            it.representedObject = [r.w, r.h]
            resolutionItems.append(it)
            resMenu.addItem(it)
        }
        let resItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        resItem.submenu = resMenu
        menu.addItem(resItem)

        let sizeMenu = NSMenu()
        for pct in [100, 95, 90, 85, 80, 75, 70, 60, 50] {
            let it = item("\(pct)%", #selector(pickSize(_:)))
            it.representedObject = pct
            sizeItems.append(it)
            sizeMenu.addItem(it)
        }
        let sizeItem = NSMenuItem(title: "Image size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(item("Move image up", #selector(moveUp)))
        menu.addItem(item("Move image down", #selector(moveDown)))
        menu.addItem(item("Image nearer", #selector(nearer)))
        menu.addItem(item("Image farther", #selector(farther)))
        menu.addItem(item("Reset position, size & distance", #selector(resetShift)))
        menu.addItem(.separator())
        let login = item("Open at login", #selector(toggleLogin))
        loginItem = login
        menu.addItem(login)
        menu.addItem(item("Quit A3 Monitor", #selector(quit), key: "q"))
        statusItem.menu = menu
        updateChecks()
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(recenterMonitor) { return rotationWindow.canRecenter }
        if menuItem.action == #selector(stopTracking) { return rotationWindow.isRunning }
        return true
    }

    private func updateChecks() {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for (m, it) in modeItems { it.state = m == mode ? .on : .off }
        for it in sizeItems { it.state = (it.representedObject as? Int) == Int((scale * 100).rounded()) ? .on : .off }
        for it in resolutionItems {
            let v = it.representedObject as? [Int] ?? []
            it.state = v == [resolution.w, resolution.h] ? .on : .off
        }
    }

    private func setStatus(_ text: String) {
        statusLine.title = text
        statusItem?.button?.title = streaming ? "A3" : "A3 ·"
    }

    private func applyLayout() {
        eyeWindow?.mode = mode
        eyeWindow?.shift = shift
        eyeWindow?.lift = lift
        eyeWindow?.scale = scale
        eyeWindow?.layout()
        rotationWindow.setImageScale(Double(scale))
        defaults.set(mode.rawValue, forKey: "mode")
        defaults.set(Double(shift), forKey: "shift")
        defaults.set(Double(lift), forKey: "lift")
        defaults.set(Double(scale), forKey: "scale")
        updateChecks()
    }

    @objc private func turnOn() {
        lastKick = Date()
        setStatus(Glasses.sendHostInfo() ? "Turning on glasses display…" : "Glasses not found on USB")
        scheduleRefresh(after: 5)
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        mode = EyeMode(rawValue: sender.representedObject as? String ?? "") ?? .both
        applyLayout()
    }

    @objc private func pickResolution(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [Int], v.count == 2 else { return }
        resolution = PixelSize(w: v[0], h: v[1])
        defaults.set(v[0], forKey: "resW")
        defaults.set(v[1], forKey: "resH")
        virtualScreen.apply(width: v[0], height: v[1])
        updateChecks()
        capturer.stop()
        streaming = false
        scheduleRefresh(after: 1)
    }

    @objc private func nearer() { shift += 4; applyLayout() }
    @objc private func farther() { shift -= 4; applyLayout() }
    @objc private func resetShift() { shift = 0; lift = 0; scale = 1; applyLayout() }
    @objc private func moveUp() { lift += 20; applyLayout() }
    @objc private func moveDown() { lift -= 20; applyLayout() }
    @objc private func pickSize(_ sender: NSMenuItem) {
        guard let pct = sender.representedObject as? Int else { return }
        scale = CGFloat(pct) / 100
        applyLayout()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openRotation() { rotationWindow.open() }
    @objc private func recenterMonitor() {
        setStatus(rotationWindow.recenter() ? "Monitor recentered" : "Recenter unavailable; hold still briefly")
    }
    @objc private func stopTracking() { rotationWindow.stop() }

    @objc private func openPrompter() {
        prompter.open(on: virtualNSScreen())
        if glassesScreen() == nil { setStatus("Prompter open · glasses display not found") }
    }

    private func virtualNSScreen() -> NSScreen? {
        let vid = virtualScreen.displayID
        return NSScreen.screens.first { $0.displayID == vid }
    }

    /// Menu-bar apps have no Edit menu by default, so ⌘C / ⌘V / ⌘A wouldn't work in the text box.
    private func buildEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("Head tracking…", #selector(openRotation), key: "t"))
        appMenu.addItem(item("Recenter monitor", #selector(recenterMonitor), key: "r"))
        appMenu.addItem(item("Stop head tracking", #selector(stopTracking)))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit A3 Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            setStatus("Login item error: \(error.localizedDescription)")
        }
        updateChecks()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
