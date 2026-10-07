import Foundation

func equivalent(_ a: TrackingQuaternion, _ b: TrackingQuaternion, tolerance: Double = 1e-9) -> Bool {
    // q and -q represent the same rotation.
    let dot = zip(a.components, b.components).reduce(0.0) { $0 + $1.0 * $1.1 }
    return abs(abs(dot) - 1) < tolerance
}

let yaw = TrackingQuaternion(x: sin(.pi / 8), y: 0, z: 0, w: cos(.pi / 8))
let pitch = TrackingQuaternion(x: 0, y: sin(.pi / 10), z: 0, w: cos(.pi / 10))
let base = yaw * pitch
var state = TrackingRotation()
state.receive(base)
assert(equivalent(state.relative, .identity), "First sample must establish the centre")
state.receive(base * yaw)
assert(equivalent(state.relative, yaw), "Relative rotation must remove the reference on the left")
state.recenter()
assert(equivalent(state.relative, .identity), "Recenter must reset all three rotation axes")
state.receive(base * yaw * pitch)
assert(equivalent(state.relative, pitch), "Movement after recenter must use the new reference")
assert(!equivalent(yaw * pitch, pitch * yaw), "Quaternion multiplication is not commutative")
state.reset()
assert(state.current == nil && state.reference == nil, "New session must not reuse an old centre")
assert(TrackingQuaternion(components: [0, 0, 0, 0]) == nil)
assert(TrackingQuaternion(components: [Double.nan, 0, 0, 1]) == nil)
assert(TrackingQuaternion(components: [0, 0, 1]) == nil)
let normalised = TrackingQuaternion(components: [0, 0, 0, 1.1])!
assert(equivalent(normalised, .identity))
let mapped = yaw.inA3TestView
assert(abs(mapped.x) < 1e-9 && abs(mapped.y - yaw.x) < 1e-9 && abs(mapped.z) < 1e-9,
       "Sensor X rotation must map to scene Y in the test view")
func close(_ actual: Double, _ expected: Double, tolerance: Double = 1e-7) {
    assert(abs(actual - expected) < tolerance, "Expected \(expected), got \(actual)")
}

func projection(_ head: TrackingQuaternion, shift: Double = 0, lift: Double = 0,
                scale: Double = 1, fov: Double = 42) -> MonitorProjection {
    MonitorProjection(head: head, width: 1920, height: 1080, scale: scale,
                      shift: shift, lift: lift, horizontalFOV: fov)
}

// Neutral projection must preserve the existing image rectangle and stereo offset.
for stereoShift in [-30.0, 0, 30] {
    let neutral = projection(.identity, shift: stereoShift, lift: 15)
    assert(neutral.isVisible)
    for (x, y) in [(-960.0, -540.0), (960, 540), (0, 0)] {
        let point = neutral.project(x: x, y: y)
        close(point.x, x + stereoShift); close(point.y, y + 15)
    }
}

let ten = 10.0 * Double.pi / 180
let headYaw = TrackingQuaternion(x: 0, y: sin(ten / 2), z: 0, w: cos(ten / 2))
let headPitch = TrackingQuaternion(x: sin(ten / 2), y: 0, z: 0, w: cos(ten / 2))
let headRoll = TrackingQuaternion(x: 0, y: 0, z: sin(ten / 2), w: cos(ten / 2))
let focal = 1920.0 / (2 * tan(42.0 * .pi / 360))
let yawCentre = projection(headYaw).project(x: 0, y: 0)
close(yawCentre.x, focal * tan(ten)); close(yawCentre.y, 0)
let pitchCentre = projection(headPitch).project(x: 0, y: 0)
close(pitchCentre.x, 0); close(pitchCentre.y, -focal * tan(ten))
let rollPoint = projection(headRoll).project(x: 100, y: 0)
close(rollPoint.x, 100 * cos(ten)); close(rollPoint.y, -100 * sin(ten))
assert(projection(headYaw, fov: 25).project(x: 0, y: 0).x > yawCentre.x,
       "A narrower optical FOV needs greater pixel compensation")

// Check world anchoring under combined rotations, for centre AND plane corners.
// Unproject a screen point to a camera ray, then rotate it back into the world.
func rotate(_ q: TrackingQuaternion, _ v: (Double, Double, Double)) -> TrackingQuaternion {
    q * TrackingQuaternion(x: v.0, y: v.1, z: v.2, w: 0) * q.inverse
}
let combined = headYaw * headPitch * headRoll
let combinedProjection = projection(combined, shift: 30, lift: 15)
assert(combinedProjection.isVisible)
for (x, y) in [(-960.0, -540.0), (960, 540), (0, 0)] {
    let screen = combinedProjection.project(x: x, y: y)
    let ray = rotate(combined, (screen.x, screen.y, -focal))
    close(ray.x / -ray.z, (x + 30) / focal)
    close(ray.y / -ray.z, (y + 15) / focal)
}
let turnedAway = TrackingQuaternion(x: 0, y: 1, z: 0, w: 0)
assert(!projection(turnedAway).isVisible, "A monitor behind the head must disappear")
let nearSideways = TrackingQuaternion(x: 0, y: sin(.pi * 85 / 360), z: 0, w: cos(.pi * 85 / 360))
assert(!projection(nearSideways).isVisible, "A plane crossing the camera must not produce a singular transform")
state.receive(combined)
state.recenter()
let centred = projection(state.relative).project(x: 100, y: 50)
close(centred.x, 100); close(centred.y, 50)
// Corrected mounting basis must preserve yaw and reverse the former pitch/roll.
let correctedPitch = pitch.inA3Display
close(correctedPitch.x, -pitch.y); close(correctedPitch.y, 0)
let correctedYaw = yaw.inA3Display
close(correctedYaw.x, 0); close(correctedYaw.y, yaw.x)
let sensorRoll = TrackingQuaternion(x: 0, y: 0, z: sin(ten/2), w: cos(ten/2))
close(sensorRoll.inA3Display.z, sensorRoll.z)
let expectedPitchDirection = projection(correctedPitch).project(x: 0, y: 0).y
assert(expectedPitchDirection > 0, "Pitch compensation must reverse the old mounting direction")

let up = TrackingVector(x: 0, y: 1, z: 0)
var anchor = TrackingMonitorAnchor()
assert(anchor.recenter(head: combined, worldUp: up, level: true))
assert(equivalent(anchor.reference!, headYaw * headPitch), "Level Recenter must retain yaw/pitch and remove roll")
let rightInWorld = anchor.reference!.rotating(TrackingVector(x: 1, y: 0, z: 0))
close(rightInWorld.y, 0)
let counterRoll = anchor.relative(head: combined)!.inverse.rotating(up)
close(counterRoll.x, sin(ten)); close(counterRoll.y, cos(ten))
assert(anchor.recenter(head: combined, worldUp: nil, level: false))
assert(equivalent(anchor.relative(head: combined)!, .identity))
let retained = anchor.reference!
assert(!anchor.recenter(head: combined, worldUp: nil, level: true))
assert(equivalent(anchor.reference!, retained), "Unavailable gravity must not erase the anchor")
assert(!anchor.recenter(head: .identity, worldUp: TrackingVector(x: 0, y: 0, z: 1), level: true))

// Gravity stays fixed in world space even when the sensor rotates.
var gravity = TrackingWorldUp()
let sensorAcceleration = combined.inverse.rotating(TrackingVector(x: 0, y: 9.81, z: 0))
gravity.receive(head: combined, acceleration: sensorAcceleration, gyro: nil, time: 1)
close(gravity.recent(at: 1)!.y, 1)
gravity.receive(head: .identity, acceleration: TrackingVector(x: 20, y: 0, z: 0), gyro: nil, time: 1.1)
close(gravity.recent(at: 1.1)!.y, 1)
assert(gravity.recent(at: 2.1) == nil)

let antipode = TrackingQuaternion(x: -headYaw.x, y: -headYaw.y, z: -headYaw.z, w: -headYaw.w)
assert(equivalent(.slerp(headYaw, antipode, fraction: 0.5), headYaw))
assert(equivalent(.slerp(.identity, headYaw, fraction: 0), .identity))
assert(equivalent(.slerp(.identity, headYaw, fraction: 1), headYaw))

var filter = TrackingPoseFilter()
filter.receive(head: .identity, deviceTime: 0, arrival: 0, gyro: nil)
filter.receive(head: headYaw, deviceTime: 0.004, arrival: 0.004, gyro: nil)
assert(filter.filtered!.angleDegrees > 0 && filter.filtered!.angleDegrees < headYaw.angleDegrees)
filter.snapToLatest()
assert(equivalent(filter.filtered!, headYaw), "Recenter must not ease toward an old sample")
filter.smoothingSeconds = 0
let bodyRate = TrackingVector(x: 0, y: 1, z: 0)
filter.receive(head: .identity, deviceTime: 1, arrival: 1, gyro: bodyRate)
let predicted = filter.orientation(at: 1.010, predict: true)!
close(predicted.angleDegrees, 0.010 * 180 / .pi)
close(filter.orientation(at: 1.2, predict: true)!.angleDegrees, 0.020 * 180 / .pi)
assert(filter.orientation(at: 1.6, predict: true) == nil)
assert(equivalent(filter.orientation(at: 1.010, predict: false)!, .identity))
filter.receive(head: headYaw, deviceTime: 0.999, arrival: 1.011, gyro: bodyRate)
assert(equivalent(filter.latest!, .identity), "Out-of-order samples must not replace a newer pose")

// The time-based low-pass should have the same response at different input rates.
func stepResponse(hz: Double) -> TrackingQuaternion {
    var filter = TrackingPoseFilter()
    filter.smoothingSeconds = 0.020
    filter.receive(head: .identity, deviceTime: 0, arrival: 0, gyro: nil)
    for index in 1...Int(hz / 10) {
        let t = Double(index) / hz
        filter.receive(head: headYaw, deviceTime: t, arrival: t, gyro: nil)
    }
    return filter.filtered!
}
assert(equivalent(stepResponse(hz: 100), stepResponse(hz: 200), tolerance: 1e-7))
print("TrackingMath: projection, corrected mounting, level Recenter, gravity, SLERP and prediction checks passed")
