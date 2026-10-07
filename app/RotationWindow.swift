import AppKit
import SceneKit
import simd
import CoreGraphics

/// AppKit controls and SceneKit diagnostics. A callback sends head orientation
/// to the app, without making this window depend directly on EyeWindow.
final class RotationWindow: NSObject, NSWindowDelegate {
    var onMonitorOrientation: ((TrackingQuaternion?, Double) -> Void)?
    var onImageScaleChange: ((Double) -> Void)?
    private var window: NSWindow?
    private let bridge = PoseBridge()
    private var rotation = TrackingRotation()
    private var monitorAnchor = TrackingMonitorAnchor()
    private var worldUp = TrackingWorldUp()
    private var poseFilter = TrackingPoseFilter()
    private let frameDriver = DisplayRefreshDriver()
    private var latest: PoseBridgeMessage?
    private var lastArrival: TimeInterval = 0
    private var hasError = false
    private var stopping = false
    private var lastMonitorHead: TrackingQuaternion?
    private var lastMonitorFOV: Double?
    private var timer: Timer?
    private let model = SCNNode()

    private let pythonField = NSTextField(string: "")
    private let status = NSTextField(wrappingLabelWithString: "Ready. Connect the A3 and start head tracking.")
    private let values = NSTextField(wrappingLabelWithString: "No orientation received yet.")
    private let startButton = NSButton(title: "Start tracking", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private let recenterButton = NSButton(title: "Recenter", target: nil, action: nil)
    private let choosePythonButton = NSButton(title: "Choose Python…", target: nil, action: nil)
    private let basisChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    private let monitorToggle = NSButton(checkboxWithTitle: "World-fixed monitor", target: nil, action: nil)
    private let fovSlider = NSSlider(value: 42, minValue: 25, maxValue: 70, target: nil, action: nil)
    private let sizeSlider = NSSlider(value: 100, minValue: 50, maxValue: 100, target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "Monitor size: 100%")
    private let fovLabel = NSTextField(labelWithString: "Optical FOV: 42°")
    private let levelToggle = NSButton(checkboxWithTitle: "Level Recenter", target: nil, action: nil)
    private let predictionToggle = NSButton(checkboxWithTitle: "Short prediction", target: nil, action: nil)
    private let smoothingSlider = NSSlider(value: 8, minValue: 0, maxValue: 30, target: nil, action: nil)
    private let smoothingLabel = NSTextField(labelWithString: "Smoothing: 8 ms")
    private let sceneView = SCNView(frame: .zero)
    private let diagnostics = NSTextView(frame: .zero)

    override init() {
        super.init()
        frameDriver.onFrame = { [weak self] targetTime in
            guard let self else { return }
            self.publishMonitor(at: targetTime)
            if self.window?.isVisible == true { self.applyRotation(self.rotation.relative) }
        }
        bridge.onMessage = { [weak self] message in self?.receive(message) }
        bridge.onDiagnostic = { [weak self] text in self?.appendDiagnostic(text) }
        bridge.onExit = { [weak self] code in
            guard let self else { return }
            self.stopping = false
            self.publishMonitor()
            if self.window?.isVisible != true { self.invalidateTimer() }
            if !self.hasError {
                self.status.stringValue = code == 0 ? "Stopped. The diagnostic reference remains visible." : "Sensor process exited (\(code)). See details below."
            }
            self.updateButtons()
        }
    }

    var isRunning: Bool { bridge.isRunning }
    var canRecenter: Bool {
        bridge.isRunning && !stopping && !hasError && rotation.current != nil &&
            ProcessInfo.processInfo.systemUptime - lastArrival < 0.5
    }
    func setOutputDisplay(_ id: CGDirectDisplayID?) { frameDriver.setDisplay(id) }
    func setImageScale(_ scale: Double) {
        sizeSlider.doubleValue = min(100, max(50, scale.isFinite ? scale * 100 : 100))
        sizeLabel.stringValue = "Monitor size: \(Int(sizeSlider.doubleValue.rounded()))%"
    }

    func open() {
        if window == nil { buildWindow() }
        ensureTimer()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureTimer() {
        if !frameDriver.isActive { frameDriver.start() }
        if timer == nil {
            // Diagnostics are cheap at 10 Hz; monitor transforms use display cadence.
            let update = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.renderLatest()
            }
            timer = update
            // Continue projecting while a menu is open or a slider is dragged.
            RunLoop.main.add(update, forMode: .common)
        }
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
        frameDriver.stop()
    }

    func stop(completion: (() -> Void)? = nil) {
        stopping = bridge.isRunning
        publishMonitor()
        if stopping { status.stringValue = "Stopping tracking and releasing USB…" }
        updateButtons()
        bridge.stop(completion: completion)
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 850),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "A3 – Head tracking"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 800, height: 800)
        win.delegate = self
        // Keep diagnostics on the Mac instead of accidentally opening behind the
        // full-screen glasses output. Screen selection can be changed manually.
        if let screen = NSScreen.screens.first(where: { !$0.localizedName.contains("Think A3") && $0.frame.width != 3840 }) {
            win.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 430,
                                       y: screen.visibleFrame.midY - 425))
        } else { win.center() }
        window = win

        pythonField.stringValue = suggestedPythonPath()
        pythonField.placeholderString = "/Users/you/.venvs/a3-tools/bin/python"
        pythonField.toolTip = "Full path to the Python executable with PyUSB installed, not a folder, script, or activation command."
        choosePythonButton.target = self; choosePythonButton.action = #selector(choosePython)
        startButton.target = self; startButton.action = #selector(startLive)
        stopButton.target = self; stopButton.action = #selector(stopClicked)
        recenterButton.target = self; recenterButton.action = #selector(recenterClicked)
        recenterButton.keyEquivalent = "r"
        recenterButton.keyEquivalentModifierMask = .command
        basisChoice.addItems(withTitles: ["Axes: A3 display", "Axes: raw sensor"])
        basisChoice.target = self; basisChoice.action = #selector(basisChanged)
        let defaults = UserDefaults.standard
        func enabled(_ key: String) -> NSControl.StateValue {
            defaults.object(forKey: key) == nil || defaults.bool(forKey: key) ? .on : .off
        }
        monitorToggle.state = enabled("trackingWorldFixed")
        let savedFOV = defaults.double(forKey: "trackingHorizontalFOV")
        if (25.0...70.0).contains(savedFOV) { fovSlider.doubleValue = savedFOV }
        fovLabel.stringValue = "Optical FOV: \(Int(fovSlider.doubleValue.rounded()))°"
        let savedSmoothing = defaults.double(forKey: "trackingSmoothingMs")
        if defaults.object(forKey: "trackingSmoothingMs") != nil && (0.0...30.0).contains(savedSmoothing) {
            smoothingSlider.doubleValue = savedSmoothing
        }
        smoothingLabel.stringValue = "Smoothing: \(Int(smoothingSlider.doubleValue.rounded())) ms"
        sizeSlider.target = self; sizeSlider.action = #selector(sizeChanged)
        sizeSlider.isContinuous = true
        sizeSlider.toolTip = "Scales the virtual monitor without changing tracking calibration. Also available in A3 → Image size."
        monitorToggle.target = self; monitorToggle.action = #selector(monitorChanged)
        fovSlider.target = self; fovSlider.action = #selector(fovChanged)
        fovSlider.isContinuous = true
        fovSlider.toolTip = "Approximate optical calibration, not monitor size. Larger FOV means less movement per degree."
        levelToggle.state = enabled("trackingLevelRecenter")
        levelToggle.target = self; levelToggle.action = #selector(levelChanged)
        predictionToggle.state = enabled("trackingPrediction")
        predictionToggle.target = self; predictionToggle.action = #selector(predictionChanged)
        predictionToggle.toolTip = "Bias-corrected gyro predicts up to 20 ms toward the next display frame."
        smoothingSlider.target = self; smoothingSlider.action = #selector(smoothingChanged)
        smoothingSlider.isContinuous = true
        smoothingSlider.toolTip = "0 ms disables smoothing. Higher values reduce jitter but add delay. Faster motion reduces smoothing automatically."

        let pythonRow = NSStackView(views: [NSTextField(labelWithString: "Python:"), pythonField, choosePythonButton])
        pythonRow.orientation = .horizontal; pythonRow.spacing = 8
        pythonField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [startButton, stopButton, recenterButton, basisChoice])
        controls.orientation = .horizontal; controls.spacing = 8
        let trackingControls = NSStackView(views: [monitorToggle, sizeLabel, sizeSlider])
        trackingControls.orientation = .horizontal; trackingControls.spacing = 12
        let calibrationControls = NSStackView(views: [fovLabel, fovSlider])
        calibrationControls.orientation = .horizontal; calibrationControls.spacing = 12
        let calibrationHelp = NSTextField(wrappingLabelWithString: "Optical FOV calibrates head-motion compensation. Keep it near 42°; use Monitor size to resize the screen. A larger FOV reduces movement per degree of head rotation.")
        calibrationHelp.font = NSFont.systemFont(ofSize: 11)
        calibrationHelp.textColor = .secondaryLabelColor
        let pythonHelp = NSTextField(wrappingLabelWithString: "Enter the Python executable from your venv with PyUSB installed. Run python -c 'import sys; print(sys.executable)' in that environment and paste its output here.")
        pythonHelp.font = NSFont.systemFont(ofSize: 11)
        pythonHelp.textColor = .secondaryLabelColor
        pythonHelp.isSelectable = true
        let qualityControls = NSStackView(views: [levelToggle, predictionToggle, smoothingLabel, smoothingSlider])
        qualityControls.orientation = .horizontal; qualityControls.spacing = 12
        values.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        values.maximumNumberOfLines = 6
        status.maximumNumberOfLines = 2
        let hint = NSTextField(wrappingLabelWithString: "Level Recenter keeps your gaze direction and levels the monitor using gravity. Hold still briefly. When you tilt your head, a world-fixed monitor tilts the opposite way in your view. Closing this window keeps world-fixed tracking running. Stop ends it.")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        buildScene()
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        diagnostics.isEditable = false
        diagnostics.isSelectable = true
        diagnostics.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        diagnostics.autoresizingMask = [.width]
        diagnostics.isVerticallyResizable = true
        diagnostics.isHorizontallyResizable = false
        diagnostics.textContainer?.widthTracksTextView = true
        scroll.documentView = diagnostics

        let stack = NSStackView(views: [pythonRow, pythonHelp, controls, trackingControls, qualityControls, calibrationControls, calibrationHelp, status, sceneView, values, hint, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: win.contentLayoutRect)
        win.contentView = content
        content.addSubview(stack)
        var constraints = [stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                           stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                           stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                           stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
                           sceneView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
                           scroll.heightAnchor.constraint(equalToConstant: 60)]
        for view in [pythonRow, pythonHelp, controls, trackingControls, qualityControls, calibrationControls, calibrationHelp, status, sceneView, values, hint, scroll] as [NSView] {
            constraints.append(view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        updateButtons()
    }

    private func buildScene() {
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedWhite: 0.08, alpha: 1)
        sceneView.scene = scene
        sceneView.preferredFramesPerSecond = 60
        sceneView.antialiasingMode = .multisampling4X
        sceneView.allowsCameraControl = false
        sceneView.autoenablesDefaultLighting = true
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.position = SCNVector3(3.2, 2.1, 5.0)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        sceneView.pointOfView = camera

        let box = SCNBox(width: 1.6, height: 0.85, length: 1.0, chamferRadius: 0.08)
        box.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.55, alpha: 1)
        model.geometry = box
        scene.rootNode.addChildNode(model)
        let face = SCNNode(geometry: SCNBox(width: 1.3, height: 0.3, length: 0.02, chamferRadius: 0.015))
        face.geometry?.firstMaterial?.diffuse.contents = NSColor.systemGreen
        face.position = SCNVector3(0, 0.1, 0.51)
        model.addChildNode(face)
        // RGB axes are fixed in the scene so the moving body has a visual reference.
        for (axis, color, position) in [
            (SCNBox(width: 2.7, height: 0.018, length: 0.018, chamferRadius: 0), NSColor.systemRed, SCNVector3(0, -0.8, 0)),
            (SCNBox(width: 0.018, height: 2.7, length: 0.018, chamferRadius: 0), NSColor.systemGreen, SCNVector3(-1.5, 0, 0)),
            (SCNBox(width: 0.018, height: 0.018, length: 2.7, chamferRadius: 0), NSColor.systemBlue, SCNVector3(0, -0.8, 0))
        ] {
            let node = SCNNode(geometry: axis)
            node.geometry?.firstMaterial?.diffuse.contents = color
            node.position = position
            scene.rootNode.addChildNode(node)
        }
    }

    private func suggestedPythonPath() -> String {
        if let saved = UserDefaults.standard.string(forKey: "trackingPythonPath"), !saved.isEmpty { return saved }
        if let url = Bundle.main.url(forResource: "tracking-python", withExtension: "txt"),
           let path = try? String(contentsOf: url, encoding: .utf8), !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/bin/python3"
    }

    private func begin() {
        guard !bridge.isRunning else { return }
        rotation.reset()
        monitorAnchor = TrackingMonitorAnchor()
        worldUp = TrackingWorldUp()
        poseFilter = TrackingPoseFilter()
        poseFilter.smoothingSeconds = smoothingSlider.doubleValue / 1000
        latest = nil
        lastArrival = 0
        hasError = false
        stopping = false
        ensureTimer()
        publishMonitor()
        diagnostics.string = ""
        status.stringValue = "Starting sensor process…"
        values.stringValue = "Waiting for the first valid orientation…"
        applyRotation(.identity)
        let path = pythonField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try bridge.start(pythonPath: path)
            UserDefaults.standard.set(path, forKey: "trackingPythonPath")
        } catch {
            hasError = true
            status.stringValue = error.localizedDescription
        }
        updateButtons()
    }

    private func receive(_ message: PoseBridgeMessage) {
        switch message.type {
        case "pose":
            guard !stopping, let components = message.quaternion,
                  let quaternion = TrackingQuaternion(components: components) else { return }
            rotation.receive(quaternion)
            latest = message
            lastArrival = ProcessInfo.processInfo.systemUptime
            let gyro = corrected(message.gyro_rad_s, bias: message.gyro_bias_rad_s)
            let acceleration = corrected(message.accel_m_s2, bias: message.accel_bias_m_s2)
            let syncedIMU: Bool
            if let poseTime = message.timestamp_ns, let imuTime = message.imu_timestamp_ns {
                syncedIMU = abs(Double(poseTime) - Double(imuTime)) < 20_000_000
            } else { syncedIMU = false }
            if syncedIMU {
                worldUp.receive(head: quaternion, acceleration: acceleration, gyro: gyro, time: lastArrival)
            }
            poseFilter.receive(head: quaternion,
                deviceTime: message.timestamp_ns.map { Double($0) / 1e9 } ?? lastArrival,
                arrival: lastArrival, gyro: syncedIMU ? gyro : nil)
            if monitorAnchor.reference == nil { _ = recenterMonitor() }
        case "error":
            hasError = true
            status.stringValue = message.message ?? "Sensor error"
            appendDiagnostic((message.message ?? "Sensor error") + "\n")
        case "status":
            if !hasError && !stopping { status.stringValue = message.message ?? "" }
        case "end":
            if !hasError { status.stringValue = message.message ?? "Stopped" }
        default: break
        }
    }

    private func renderLatest() {
        guard window?.isVisible == true else { return }
        guard let current = rotation.current, let latest else { updateButtons(); return }
        let relative = rotation.relative
        applyRotation(relative)
        let age = ProcessInfo.processInfo.systemUptime - lastArrival
        if bridge.isRunning && !stopping && !hasError {
            status.stringValue = age < 1 ? (monitorAnchor.reference == nil ?
                "Hold still briefly and look roughly ahead to establish a level anchor…" :
                "Orientation received · Recenter with ⌘R · \(frameDriver.modeDescription)") :
                "No new orientation for \(String(format: "%.1f", age)) s"
        }
        let rate = latest.received_rate_hz.map { String(format: "%.0f Hz", $0) } ?? "—"
        values.stringValue = "q raw  [x y z w]: \(format(current.components))\n" +
            "q rel  [x y z w]: \(format(relative.components))   Angle: \(String(format: "%.1f", relative.angleDegrees))°\n" +
            "Gyro [rad/s]: \(format(latest.gyro_rad_s))   Accel [m/s²]: \(format(latest.accel_m_s2))\n" +
            "Sensor stream: \(rate)   Pose: \(latest.pose_packets ?? 0)   IMU: \(latest.imu_packets ?? 0)   Bridge: max. 240 Hz"
        updateButtons()
    }

    private func publishMonitor(at targetTime: Double? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let fresh = now - lastArrival < 0.5
        let enabled = monitorToggle.state == .on && bridge.isRunning &&
            !stopping && !hasError && rotation.current != nil && fresh
        let predicted = poseFilter.orientation(at: targetTime ?? now, predict: predictionToggle.state == .on)
        let head = enabled ? predicted.flatMap { monitorAnchor.relative(head: displayBasis($0)) } : nil
        let fov = fovSlider.doubleValue
        guard head != lastMonitorHead || fov != lastMonitorFOV else { return }
        lastMonitorHead = head; lastMonitorFOV = fov
        onMonitorOrientation?(head, fov)
    }

    private func applyRotation(_ quaternion: TrackingQuaternion) {
        let displayed = displayBasis(quaternion)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        model.simdOrientation = simd_quatf(ix: Float(displayed.x), iy: Float(displayed.y),
                                         iz: Float(displayed.z), r: Float(displayed.w))
        SCNTransaction.commit()
    }

    private func displayBasis(_ quaternion: TrackingQuaternion) -> TrackingQuaternion {
        basisChoice.indexOfSelectedItem == 0 ? quaternion.inA3Display : quaternion
    }

    private func corrected(_ components: [Double]?, bias: [Double]?) -> TrackingVector? {
        guard let values = TrackingVector(components: components) else { return nil }
        guard let bias = TrackingVector(components: bias) else { return values }
        return TrackingVector(x: values.x - bias.x, y: values.y - bias.y, z: values.z - bias.z)
    }

    @discardableResult
    private func recenterMonitor() -> Bool {
        guard let current = rotation.current else { return false }
        let up = worldUp.recent(at: ProcessInfo.processInfo.systemUptime).map {
            basisChoice.indexOfSelectedItem == 0 ? TrackingQuaternion.a3DisplayBasis.rotating($0) : $0
        }
        let success = monitorAnchor.recenter(head: displayBasis(current), worldUp: up, level: levelToggle.state == .on)
        if success { poseFilter.snapToLatest() }
        return success
    }

    private func format(_ components: [Double]?) -> String {
        guard let components else { return "—" }
        return components.map { String(format: "%+.4f", $0) }.joined(separator: " ")
    }

    private func updateButtons() {
        let running = bridge.isRunning
        startButton.isEnabled = !running
        stopButton.isEnabled = running && !stopping
        choosePythonButton.isEnabled = !running
        pythonField.isEnabled = !running
        monitorToggle.isEnabled = !stopping
        sizeSlider.isEnabled = true
        fovSlider.isEnabled = monitorToggle.isEnabled && monitorToggle.state == .on
        levelToggle.isEnabled = !stopping
        smoothingSlider.isEnabled = !stopping
        predictionToggle.isEnabled = !stopping
        recenterButton.isEnabled = canRecenter
    }

    private func appendDiagnostic(_ text: String) {
        diagnostics.string += text
        if diagnostics.string.count > 12000 { diagnostics.string = String(diagnostics.string.suffix(10000)) }
        diagnostics.scrollToEndOfDocument(nil)
    }

    @objc private func startLive() { begin() }
    @objc private func stopClicked() { stop() }
    @objc private func basisChanged() {
        monitorAnchor = TrackingMonitorAnchor()
        _ = recenterMonitor()
        publishMonitor()
        renderLatest()
    }
    @objc private func monitorChanged() {
        UserDefaults.standard.set(monitorToggle.state == .on, forKey: "trackingWorldFixed")
        // Enabling anchors the plane in the direction currently being viewed.
        if monitorToggle.state == .on { rotation.recenter(); _ = recenterMonitor() }
        publishMonitor()
        renderLatest()
    }
    @objc private func sizeChanged() { onImageScaleChange?(sizeSlider.doubleValue / 100) }
    @objc private func fovChanged() {
        UserDefaults.standard.set(fovSlider.doubleValue, forKey: "trackingHorizontalFOV")
        fovLabel.stringValue = "Optical FOV: \(Int(fovSlider.doubleValue.rounded()))°"
        publishMonitor()
    }
    @objc private func levelChanged() {
        UserDefaults.standard.set(levelToggle.state == .on, forKey: "trackingLevelRecenter")
        monitorAnchor = TrackingMonitorAnchor()
        _ = recenterMonitor()
        publishMonitor()
        renderLatest()
    }
    @objc private func predictionChanged() {
        UserDefaults.standard.set(predictionToggle.state == .on, forKey: "trackingPrediction")
        publishMonitor()
    }
    @objc private func smoothingChanged() {
        UserDefaults.standard.set(smoothingSlider.doubleValue, forKey: "trackingSmoothingMs")
        smoothingLabel.stringValue = "Smoothing: \(Int(smoothingSlider.doubleValue.rounded())) ms"
        poseFilter.smoothingSeconds = smoothingSlider.doubleValue / 1000
        poseFilter.snapToLatest()
        publishMonitor()
    }
    @discardableResult
    func recenter() -> Bool {
        guard canRecenter else { return false }
        if monitorToggle.state == .on && !recenterMonitor() {
            appendDiagnostic("Level Recenter needs recent gravity data. Hold still briefly and avoid looking straight up or down.\n")
            status.stringValue = "Level Recenter is not ready yet; hold still briefly."
            return false
        }
        rotation.recenter()
        publishMonitor()
        renderLatest()
        return true
    }

    @objc private func recenterClicked() { recenter() }

    @objc private func choosePython() {
        guard !bridge.isRunning, let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Python from your tracking environment"
        panel.message = "Run python -c 'import sys; print(sys.executable)' in your activated venv. Use ⌘⇧G to enter its folder here."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false  // keep the venv interpreter's original path
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pythonField.stringValue = url.path
        }
    }

    func windowWillClose(_ notification: Notification) {
        // A room-fixed monitor must keep tracking when diagnostics are hidden.
        if bridge.isRunning && monitorToggle.state == .on && !stopping { return }
        invalidateTimer()
        stop()
    }
}
