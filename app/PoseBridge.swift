import Foundation

/// Codable is Swift's built-in equivalent of a typed JSON serialization model.
/// Optional fields cover status/error events and the first pose before any IMU.
struct PoseBridgeMessage: Decodable {
    let schema: Int
    let type: String
    let message: String?
    let quaternion: [Double]?
    let timestamp_ns: Int64?
    let gyro_rad_s: [Double]?
    let accel_m_s2: [Double]?
    let gyro_bias_rad_s: [Double]?
    let accel_bias_m_s2: [Double]?
    let imu_timestamp_ns: Int64?
    let imu_packets: Int?
    let pose_packets: Int?
    let received_rate_hz: Double?
}

enum PoseBridgeError: LocalizedError {
    case alreadyRunning, pythonUnavailable, scriptUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "The sensor process is already running or still stopping."
        case .pythonUnavailable: return "Python path is not executable. Choose the Python executable from your venv with PyUSB installed."
        case .scriptUnavailable: return "Sensor bridge is missing from the app bundle. Rebuild with app/build.sh."
        }
    }
}

/// Owns one child process. USB stays on the Python side; Swift receives <=240 Hz.
/// Public methods and callbacks run on the main thread, pipe reads in background.
final class PoseBridge {
    var onMessage: ((PoseBridgeMessage) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var stopCompletions: [() -> Void] = []
    private let stdoutQueue = DispatchQueue(label: "a3.pose.stdout", qos: .userInitiated)
    private let stderrQueue = DispatchQueue(label: "a3.pose.stderr", qos: .utility)
    // Keep isRunning true until output has been drained and cleanup has finished.
    var isRunning: Bool { process != nil }

    func start(pythonPath: String) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        guard process == nil else { throw PoseBridgeError.alreadyRunning }
        let path = NSString(string: pythonPath).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else { throw PoseBridgeError.pythonUnavailable }
        guard let script = Bundle.main.url(forResource: "a3_pose_stream", withExtension: "py",
                                            subdirectory: "Tracking") else { throw PoseBridgeError.scriptUnavailable }

        let child = Process()
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        child.executableURL = URL(fileURLWithPath: path)
        let arguments = ["-u", script.path, "--fps", "240", "--parent-pid",
                         String(ProcessInfo.processInfo.processIdentifier)]
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        child.environment = environment
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe
        child.standardInput = FileHandle.nullDevice
        // Process executes the interpreter directly: no shell quoting or activation.
        try child.run()
        process = child

        stderrQueue.async { [weak self] in
            let handle = stderrPipe.fileHandleForReading
            defer { try? handle.close() }
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async { [weak self] in self?.onDiagnostic?(text) }
            }
        }
        stdoutQueue.async { [weak self] in
            let handle = stdoutPipe.fileHandleForReading
            defer { try? handle.close() }
            let decoder = JSONDecoder()
            var pending = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                pending.append(data)
                // A pipe read can contain part of a line or several lines.
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard !line.isEmpty else { continue }
                    do {
                        let message = try decoder.decode(PoseBridgeMessage.self, from: line)
                        guard message.schema == 1 else { continue }
                        DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
                    } catch {
                        DispatchQueue.main.async { [weak self] in
                            self?.onDiagnostic?("Invalid bridge line: \(error.localizedDescription)\n")
                        }
                    }
                }
                if pending.count > 65536 {
                    pending.removeAll()
                    DispatchQueue.main.async { [weak self] in
                        self?.onDiagnostic?("Bridge line exceeds the size limit; incomplete data discarded.\n")
                    }
                }
            }
            // Only this background queue waits; the UI remains responsive.
            child.waitUntilExit()
            let status = child.terminationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.process = nil
                self.onExit?(status)
                let completions = self.stopCompletions
                self.stopCompletions.removeAll()
                completions.forEach { $0() }
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let process else { completion?(); return }
        if let completion { stopCompletions.append(completion) }
        // SIGTERM is handled by Python. Its finally block sends StopVRMode only
        // for a session it started, then releases interface 2. Never SIGKILL.
        if process.isRunning { process.terminate() }
    }
}
