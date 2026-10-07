# Development

The tracking feature adds optional 3DoF rendering to the existing single-monitor app. It uses a
separate Python process for USB and keeps projection/math in Swift. Python, PyUSB and libusb are
external dependencies; no Python runtime is packaged inside the app.

## Files and data flow

| File | Responsibility |
|---|---|
| `app/main.swift` | App/menu lifecycle, virtual display, ScreenCaptureKit capture, two eye layers and tracking callbacks. |
| `app/TrackingMath.swift` | Quaternion/vector math, coordinate conversion, gravity estimate, level anchor, filter and projection. No AppKit dependency. |
| `app/RotationWindow.swift` | Live controls, SceneKit diagnostics, current tracking state, recenter and publication to the renderer. |
| `app/DisplayRefreshDriver.swift` | Physical display cadence via NSScreen.displayLink on macOS 14+; 60 Hz timer fallback on macOS 13 or without a matching screen. |
| `app/PoseBridge.swift` | Python Process, separate stdout/stderr pipes, typed JSON decoding and graceful shutdown. |
| `app/TrackingBridge/a3_pose_stream.py` | Reads USB continuously, associates latest IMU with pose, emits at most 240 JSON lines/s. |
| `app/TrackingBridge/a3_usb_protocol.py` | Reverse-engineered protocol, session commands and packet decoding; also retains developer capture/decoding commands. |
| `tests/TrackingMath/main.swift` | Standalone Swift checks for projection, mounting, recenter, gravity, SLERP and prediction. |
| `tests/test_pose_bridge.py` | Python bridge/protocol checks with mocked USB and hardware-free replay. |

Data flows from USB to Python to newline-delimited JSON to Swift's filter/anchor, then to an
inverse-head-rotation projection of the captured desktop into the two eye layers. USB reads and
pipe reads run outside the UI thread; decoded events reach the main queue. AppKit mutations
and display callbacks run on the main thread. There is no local server or network dependency.

The tested recording contained approximately 987 pose and 987 IMU packets per second. Python
continues reading at sensor rate but sends up to 240 poses/s, skipping missed output slots rather
than producing catch-up bursts. The physical A3 display is 60 Hz; diagnostic text updates at
10 Hz. These are separate rates, not promises of 987 rendered frames/s.

## Tracking math

- Quaternions are normalized and stored as **x, y, z, w**. Invalid or implausible inputs are rejected.
- The validated A3 display mounting maps sensor **X → Y, Y → −X, Z → Z**, a proper +90° rotation
  about Z. The legacy `inA3TestView` mapping remains only as a historical comparison in math;
  the renderer uses `inA3Display`.
- The diagnostic model uses `reference.inverse * current`. The monitor uses a separate level
  anchor and inverse head rotation. Projection transforms the entire screen plane, including
  its center, then applies a projective transform. Merely rotating a layer about its own center
  would not keep the monitor fixed when looking left/right or nodding.
- Gravity is derived from bias-corrected acceleration rotated into the sensor world frame.
  Samples are accepted near normal gravity magnitude and at moderate angular speed, then
  filtered over roughly 0.5 s. This estimate is used when anchoring, not as a continuous forced
  correction to the device's fused quaternion. Linear acceleration can still contaminate it.
- Level Recenter preserves gaze while constructing horizontal right/up axes from gravity. It
  requires recent suitable gravity and a gaze direction away from the vertical singularity.
- Adaptive shortest-arc SLERP uses device timestamps. Recenter snaps the filter to its latest
  input, and large timestamp gaps reset it. The base smoothing range is 0–30 ms (default 8 ms).
- Gyro prediction subtracts the reported bias, requires IMU and pose timestamps within 20 ms,
  and extrapolates by at most 20 ms. It does not continuously integrate orientation or correct drift.

Optical FOV sets the horizontal projection scale. Monitor size scales the plane independently.
Eye separation is still the existing display offset; positional units and true stereo calibration
are not validated. There is no camera processing or 6DoF pipeline.

## Process and USB lifecycle

The app uses VID `17ef`, PID `b813`, interface **2**, alternate **0**, bulk IN **83** and OUT **03**.
The bridge checks descriptors before claiming the interface. The stream init uses GetVRMode
(`12`), GetParam (`19`, `tracker-tracking-mode`) and StartVRMode (`14`) without changing that mode.
An already flowing sensor stream is reused. StopVRMode (`15`) is sent only to clean up a start
attempt owned by this bridge; it is not sent for a stream that was already running.

Stop sends SIGTERM, which Python handles before its `finally` cleanup releases USB resources.
App shutdown waits asynchronously for that cleanup; the UI thread does not block on the child.
The bridge also detects loss of its parent. Unplugging, process crashes or forced termination can
still prevent cleanup. Neither firmware updates nor driver detachment are part of this feature.

stdout is exclusively JSON Lines with `schema: 1`, and event types `pose`, `status`, `error`, `end`.
A pose contains `quaternion`, `timestamp_ns`, optional `gyro_rad_s`, `accel_m_s2`, bias vectors,
`imu_timestamp_ns`, packet counters and an estimated received rate. Human diagnostics use stderr.
Swift accepts only schema 1, handles split/multiple lines in one read, limits incomplete buffering,
and retains the process until output draining and cleanup are complete.

Closing the tracking window retains live world-fixed tracking. A3-menu actions operate directly
on the controller, so Recenter does not depend on a visible button. ⌘R is app-scoped; no global
keyboard hook or additional input permission is introduced for recentering.

## Build and automated checks

Run Python checks from the repository root:

```bash
python -m unittest discover -s tests -v
```

They do not require connected glasses or installed PyUSB. They cover malformed pose rejection,
JSON throttling (including a synthetic approximately 987 Hz source), IMU/bias transport, replay,
interrupt handling and cleanup ownership for a mocked live USB session.

On a Mac with Xcode/Command Line Tools:

```bash
cd app
bash build.sh
# Or build, install and launch:
bash build.sh --install
```

Both builds compile and execute the pure Swift math checks before building the app. To run only
those checks from the repository root:

```bash
swiftc -swift-version 5 app/TrackingMath.swift tests/TrackingMath/main.swift -o /tmp/a3-math-checks
/tmp/a3-math-checks
```

A Linux syntax parser does not validate AppKit API types, linking or window layout. Final review
requires a real macOS build and the following hardware checks.

## Manual review on macOS

- Verify normal monitor and teleprompter operation without tracking or Python dependencies.
- Start tracking with the documented venv path; confirm received pose and IMU data.
- Turn slowly left/right and nod: the screen should move against head motion, including its center.
- Tilt sideways and recenter while still: the screen should remain level in the world reference.
- Change Monitor size and menu Image size; they should stay synchronized without changing FOV.
- Close the tracking window, use A3 → Recenter monitor, then reopen it. Test ⌘R with A3 active
  and confirm another app keeps its own ⌘R behavior.
- Stop/restart, quit during tracking and reconnect the USB cable. Check cleanup and recovery.
- Test slider/menu interactions during tracking; display callbacks use the common run-loop modes.
- Verify the macOS 13 fallback separately from macOS 14+ display-link operation if supporting both.

## Developer capture and replay

Playback is absent from the app UI and Swift bridge. The command-line replay is intentionally
retained for development/tests and requires only Python 3.9+. It takes the **raw envelope JSONL**
format produced by the protocol capture command, not pose JSON emitted by the live bridge:

```bash
# Requires connected A3, initialized display and the live USB dependencies:
python app/TrackingBridge/a3_usb_protocol.py capture --out /tmp/a3-sensors.jsonl
# No USB opened; stdout is the same schema-1 JSON protocol as live tracking:
python app/TrackingBridge/a3_pose_stream.py --replay /tmp/a3-sensors.jsonl --fps 240
```

The protocol capture CLI is experimental. Its optional tracking-mode changes are outside the
app's live path; prefer the default capture without a mode override. Do not run a capture and
app tracking simultaneously, since both claim interface 2.

## Multiple-monitor roadmap

A possible next implementation would introduce a collection of monitor instances rather than
adding more unrelated globals to AppDelegate:

1. One virtual display with a unique identity and one ScreenCaptureKit stream per macOS desktop.
2. A renderer with one textured plane per monitor per eye, each with a saved pose and size.
3. One shared head reference, gravity estimate and filtering pipeline; Recenter rotates the whole layout.
4. Visibility/culling, capture throttling and performance measurement as desktop count increases.
5. Persistence, macOS arrangement, resolution changes and plug/unplug cleanup for the collection.

First validate that multiple private CGVirtualDisplay instances and simultaneous captures behave
reliably on the supported Macs. Rendering multiple planes does not require positional SLAM, but
it remains 3DoF: walking or leaning around them would still be unsupported. True positional
tracking would be a separate camera/SLAM project with calibration, timestamps and coordinate
registration. The current PR should stay scoped to one monitor and optional rotation tracking.
