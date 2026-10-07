import Foundation

/// A small, testable quaternion value. Components have the A3's [x,y,z,w] order.
/// Like Unity's Quaternion, this stores a rotation rather than three Euler angles.
struct TrackingQuaternion: Equatable {
    let x: Double
    let y: Double
    let z: Double
    let w: Double

    static let identity = TrackingQuaternion(x: 0, y: 0, z: 0, w: 1)

    init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    /// Reject corrupt input instead of allowing NaNs to enter the renderer.
    init?(components: [Double]) {
        guard components.count == 4, components.allSatisfy({ $0.isFinite }) else { return nil }
        let norm = sqrt(components.reduce(0) { $0 + $1 * $1 })
        guard norm > 0.5, norm < 1.5 else { return nil }
        self.init(x: components[0] / norm, y: components[1] / norm,
                  z: components[2] / norm, w: components[3] / norm)
    }

    /// For a unit quaternion, inverse equals conjugate.
    var inverse: TrackingQuaternion { TrackingQuaternion(x: -x, y: -y, z: -z, w: w) }

    /// Order matters: a * b first applies b, then a.
    static func * (a: TrackingQuaternion, b: TrackingQuaternion) -> TrackingQuaternion {
        TrackingQuaternion(
            x: a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
            y: a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
            z: a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
            w: a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z)
    }

    var components: [Double] { [x, y, z, w] }
    var angleDegrees: Double { 2 * acos(min(1, abs(w))) * 180 / .pi }

    /// Provisional model-view basis: sensor X -> scene Y, Y -> X, Z -> -Z.
    /// Legacy comparison basis. The renderer now uses inA3Display to correct
    /// the pitch direction observed in the physical monitor test.
    var inA3TestView: TrackingQuaternion {
        let halfSqrt2 = sqrt(0.5)
        let basis = TrackingQuaternion(x: halfSqrt2, y: halfSqrt2, z: 0, w: 0)
        return basis * self * basis.inverse
    }

    /// Corrected display basis: X -> Y, Y -> -X, Z -> Z.
    /// A 90-degree Z rotation preserves handedness while correcting pitch.
    static let a3DisplayBasis = TrackingQuaternion(x: 0, y: 0, z: sqrt(0.5), w: sqrt(0.5))
    var inA3Display: TrackingQuaternion {
        Self.a3DisplayBasis * self * Self.a3DisplayBasis.inverse
    }

    func rotating(_ vector: TrackingVector) -> TrackingVector {
        let result = self * TrackingQuaternion(x: vector.x, y: vector.y, z: vector.z, w: 0) * inverse
        return TrackingVector(x: result.x, y: result.y, z: result.z)
    }

    static func slerp(_ a: TrackingQuaternion, _ b: TrackingQuaternion, fraction: Double) -> TrackingQuaternion {
        let t = min(1, max(0, fraction))
        var end = b
        var dot = zip(a.components, b.components).reduce(0.0) { $0 + $1.0 * $1.1 }
        // q and -q are the same orientation: follow the shortest arc.
        if dot < 0 {
            end = TrackingQuaternion(x: -b.x, y: -b.y, z: -b.z, w: -b.w)
            dot = -dot
        }
        let left: Double, right: Double
        if dot > 0.9995 {
            left = 1 - t; right = t
        } else {
            let angle = acos(min(1, max(-1, dot)))
            left = sin((1 - t) * angle) / sin(angle)
            right = sin(t * angle) / sin(angle)
        }
        let values = zip(a.components, end.components).map { left * $0.0 + right * $0.1 }
        return TrackingQuaternion(components: values) ?? a
    }
}

struct TrackingVector {
    let x, y, z: Double
    var length: Double { sqrt(x*x + y*y + z*z) }
    var unit: TrackingVector? {
        let norm = length
        guard norm.isFinite, norm > 1e-8 else { return nil }
        return TrackingVector(x: x/norm, y: y/norm, z: z/norm)
    }
    init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    init?(components: [Double]?) {
        guard let values = components, values.count == 3, values.allSatisfy({ $0.isFinite }) else { return nil }
        self.init(x: values[0], y: values[1], z: values[2])
    }
}

/// Estimate the fixed world-up direction from acceleration transformed out of
/// the moving sensor frame. Only near-gravity samples with modest gyro speed
/// contribute. This estimate is used when anchoring, not to turn the plane each frame.
struct TrackingWorldUp {
    private(set) var direction: TrackingVector?
    private var lastUpdate: Double?

    mutating func receive(head: TrackingQuaternion, acceleration: TrackingVector?,
                          gyro: TrackingVector?, time: Double) {
        guard let acceleration, (8.5...11.0).contains(acceleration.length),
              (gyro?.length ?? 0) < 1.5,
              let measured = head.rotating(acceleration).unit else { return }
        if let previous = direction, let lastUpdate {
            let alpha = 1 - exp(-min(0.1, max(0, time - lastUpdate)) / 0.5)
            direction = TrackingVector(x: previous.x + alpha * (measured.x - previous.x),
                                       y: previous.y + alpha * (measured.y - previous.y),
                                       z: previous.z + alpha * (measured.z - previous.z)).unit
        } else { direction = measured }
        lastUpdate = time
    }

    func recent(at time: Double) -> TrackingVector? {
        guard let lastUpdate, time - lastUpdate < 1 else { return nil }
        return direction
    }
}

/// Separate monitor anchor: Recenter can remove roll without discarding the
/// current viewing direction. The diagnostic model keeps its original full reset.
struct TrackingMonitorAnchor {
    private(set) var reference: TrackingQuaternion?

    @discardableResult
    mutating func recenter(head: TrackingQuaternion, worldUp: TrackingVector?, level: Bool) -> Bool {
        if !level { reference = head; return true }
        guard let worldUp else { return false }
        let upInHead = head.inverse.rotating(worldUp)
        // Looking almost vertically makes a gravity-defined roll ambiguous.
        guard hypot(upInHead.x, upInHead.y) > 0.05 else { return false }
        let angle = atan2(-upInHead.x, upInHead.y)
        let correction = TrackingQuaternion(x: 0, y: 0, z: sin(angle/2), w: cos(angle/2))
        reference = head * correction
        return true
    }

    func relative(head: TrackingQuaternion) -> TrackingQuaternion? {
        guard let reference else { return nil }
        return reference.inverse * head
    }
}

/// Time-based quaternion filter plus short, bounded body-space gyro prediction.
struct TrackingPoseFilter {
    var smoothingSeconds = 0.008
    private(set) var latest: TrackingQuaternion?
    private(set) var filtered: TrackingQuaternion?
    private var lastDeviceTime: Double?
    private var arrival: Double = 0
    private var gyro: TrackingVector?

    mutating func receive(head: TrackingQuaternion, deviceTime: Double,
                          arrival: Double, gyro: TrackingVector?) {
        let dt = lastDeviceTime.map { deviceTime - $0 } ?? 0
        // Ignore duplicate/out-of-order timestamps, reset after gaps/restarts.
        if let lastDeviceTime, deviceTime <= lastDeviceTime && dt > -0.5 { return }
        latest = head
        if let previous = filtered, dt > 0, dt < 0.1, smoothingSeconds > 0 {
            let speed = gyro?.length ?? 0
            let tau = smoothingSeconds / (1 + 4 * speed)
            filtered = .slerp(previous, head, fraction: 1 - exp(-dt / tau))
        } else { filtered = head }
        lastDeviceTime = deviceTime
        self.arrival = arrival
        self.gyro = gyro
    }

    mutating func snapToLatest() { filtered = latest }

    func orientation(at time: Double, predict: Bool) -> TrackingQuaternion? {
        guard let filtered, time - arrival < 0.5 else { return nil }
        guard predict, let gyro, gyro.length < 12 else { return filtered }
        let speed = gyro.length
        guard speed > 1e-5 else { return filtered }
        let horizon = min(0.020, max(0, time - arrival))
        let halfAngle = speed * horizon / 2
        let factor = sin(halfAngle) / speed
        let delta = TrackingQuaternion(x: gyro.x*factor, y: gyro.y*factor, z: gyro.z*factor, w: cos(halfAngle))
        return filtered * delta
    }
}

/// Project a world-fixed monitor plane into the head's current view.
/// All lengths use the same units as the output layer (AppKit points).
/// Foundation-only so the build can test this without AppKit or a USB device.
struct MonitorProjection {
    // CATransform3D's row-vector convention: X, Y and homogeneous denominator.
    let m11, m12, m14: Double
    let m21, m22, m24: Double
    let m41, m42, m44: Double
    let isVisible: Bool

    init(head: TrackingQuaternion, width: Double, height: Double,
         scale: Double, shift: Double, lift: Double, horizontalFOV: Double) {
        let fov = min(70, max(25, horizontalFOV)) * .pi / 180
        let focal = max(1, width) / (2 * tan(fov / 2))
        // World -> current camera is the INVERSE head rotation.
        let q = head.inverse
        let r00 = 1 - 2 * (q.y*q.y + q.z*q.z)
        let r01 = 2 * (q.x*q.y - q.z*q.w)
        let r02 = 2 * (q.x*q.z + q.y*q.w)
        let r10 = 2 * (q.x*q.y + q.z*q.w)
        let r11 = 1 - 2 * (q.x*q.x + q.z*q.z)
        let r12 = 2 * (q.y*q.z - q.x*q.w)
        let r20 = 2 * (q.x*q.z - q.y*q.w)
        let r21 = 2 * (q.y*q.z + q.x*q.w)
        let r22 = 1 - 2 * (q.x*q.x + q.y*q.y)
        // At Recenter, the plane is at (shift, lift, -focal) in front of us.
        let centreX = r00*shift + r01*lift - r02*focal
        let centreY = r10*shift + r11*lift - r12*focal
        let centreZ = r20*shift + r21*lift - r22*focal
        m11 = r00; m12 = r10; m14 = -r20 / focal
        m21 = r01; m22 = r11; m24 = -r21 / focal
        m41 = centreX; m42 = centreY; m44 = -centreZ / focal
        // Hide a plane facing away, or touching/crossing the camera plane.
        // This prevents mirrored output and unbounded projective coordinates.
        let minimumDepth = m44 - abs(m14)*width*scale/2 - abs(m24)*height*scale/2
        isVisible = r22 > 0 && minimumDepth > 0.01
    }

    func project(x: Double, y: Double) -> (x: Double, y: Double) {
        let divisor = m14*x + m24*y + m44
        return ((m11*x + m21*y + m41) / divisor,
                (m12*x + m22*y + m42) / divisor)
    }
}

/// App state used by the window. All access happens on the main thread.
struct TrackingRotation {
    private(set) var current: TrackingQuaternion?
    private(set) var reference: TrackingQuaternion?

    mutating func receive(_ quaternion: TrackingQuaternion) {
        current = quaternion
        // First valid sample establishes a useful initial centre automatically.
        if reference == nil { reference = quaternion }
    }

    mutating func recenter() {
        reference = current
    }

    mutating func reset() {
        current = nil
        reference = nil
    }

    var relative: TrackingQuaternion {
        guard let current, let reference else { return .identity }
        return reference.inverse * current
    }
}
