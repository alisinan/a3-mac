# Head tracking

Head tracking is optional. It keeps the captured virtual monitor fixed in orientation while the
A3 turns (3DoF). This is not positional tracking: leaning and walking are not measured. The app
uses the glasses' fused quaternion; it does not run its own SLAM or continuously integrate the gyro.

## Set up Python once

Use Python 3.9 or later. From the repository root:

```bash
brew install libusb
python3 -m venv ~/.venvs/a3-tools
source ~/.venvs/a3-tools/bin/activate
python -m pip install -r app/TrackingBridge/requirements.txt
python -c 'import sys; print(sys.executable)'
```

If you already have a working `a3-tools` environment with PyUSB, activate that instead of creating
another. The last command prints the **Python executable** to enter in the app, for example:

```text
/Users/chris/.venvs/a3-tools/bin/python
```

Enter that path in **A3 → Head tracking… → Python**, without quotation marks. Do not enter the
venv folder, `activate`, the bridge script, or a command such as `python -u …`. Swift starts the
interpreter directly; you do not need an activated terminal when using the installed app.
Keep the venv at that location. In particular, keep its `bin/python` path rather than resolving
its symlink to the underlying system interpreter, so PyUSB remains available in that environment.

**Choose Python…** accepts the same file. Press ⌘⇧G in the file chooser to go to its directory.
The app remembers the path after starting the process. Building from an activated venv also
records that interpreter as the initial suggestion. Alternatively:

```bash
cd app
A3_TRACKING_PYTHON="$HOME/.venvs/a3-tools/bin/python" bash build.sh --install
```

Dependency references: [PyUSB installation](https://github.com/pyusb/pyusb#installing).

## Start and recenter

1. Start A3 Monitor and connect the glasses; let the existing display initialization finish.
2. Open **A3 → Head tracking…**, confirm Python, and click **Start tracking**.
3. Leave **World-fixed monitor** enabled. Look roughly ahead and hold still briefly so gravity can
   be estimated. The first valid level anchor is established automatically.
4. Use **Recenter**, **A3 → Recenter monitor**, or **⌘R** to place the monitor in front of your current gaze.
5. Drag ordinary app windows onto **Glasses Screen** in macOS, just as in monitor mode.

With **Level Recenter** enabled, the monitor's upper edge stays level in the estimated world frame.
Your gaze sets the center; sideways head tilt does not become the monitor's permanent roll.
A tilted head therefore sees the level monitor counter-tilted within the glasses' viewport.
Avoid looking straight up/down while recentering; there is no stable horizontal heading there.

## Window, menu and keyboard behavior

| Action | Behavior |
|---|---|
| Close the tracking window with World-fixed monitor enabled | Tracking continues, including smoothing and display updates. |
| Close it with World-fixed monitor disabled | Tracking stops. |
| A3 → Recenter monitor | Works with the tracking window closed, while fresh tracking data is available. |
| ⌘R | Recenter while **A3 Monitor is the active app**; the tracking window need not be open. |
| ⌘R in another active app | Keeps that app's usual shortcut. It is not a global hotkey. |
| A3 → Stop head tracking or the Stop button | Ends the Python process and releases the sensor interface. |
| Quit A3 Monitor | Waits for the sensor process to finish its USB cleanup. |

Start tracking manually after launching the app. Recenter is unavailable without a live, recent
pose. Level Recenter can also wait for suitable gravity data; hold still briefly if it refuses.

## Size, optical calibration and quality

| Control | Purpose | Default |
|---|---|---|
| Monitor size | Scales the captured screen from 50–100% of the eye viewport. Same setting as A3 → Image size. | 100% |
| Optical FOV | Calibrates the projection from head angles to display movement. Larger values reduce motion per degree. | 42° |
| Smoothing | Adaptive quaternion SLERP. More smoothing reduces jitter but adds delay; faster turns reduce the smoothing. 0 disables it. | 8 ms |
| Short prediction | Uses recent, bias-corrected gyro data to predict up to 20 ms toward the next frame. | On |
| Level Recenter | Uses a recent gravity estimate to level the monitor when anchoring. | On |
| Axes | Changes diagnostic and tracking basis. A3 display is the validated mounting; raw sensor is for debugging. | A3 display |

**Use Monitor size to resize the screen.** Optical FOV is a calibration value, not a zoom control.
Start near 42° and adjust only if the monitor systematically moves too much or too little during
head turns. This value is an approximate horizontal projection setting, not a claim about the
manufacturer's diagonal field of view. Changing monitor size leaves that calibration unchanged.

The menu's **Resolution** changes the macOS desktop resolution (and therefore text size).
**Image nearer/farther** adjusts the offset between the two eye images; it does not add measured
head position or change the optics' focal distance. Move image up/down adjusts the layout.

Python path, monitor size, World-fixed monitor, optical FOV, smoothing, Level Recenter and
Short prediction are remembered. The diagnostic axis choice and runtime anchor are not persisted.

## Drift and troubleshooting

- On a train, turning tracks rotate the train and your head in the external world. An inertial
  world reference has no way to know that you want the screen fixed to your seat instead.
  Acceleration can also perturb gravity estimation. Try a stationary test to distinguish these
  effects from tracking problems. Recenter sets a new anchor; smoothing does not remove them.
- Long-term fused orientation drift can still occur. Recenter does not reset the glasses' estimator.
- If Python cannot import `usb`, install the requirements using the exact interpreter in the field:
  `/path/to/venv/bin/python -m pip install -r app/TrackingBridge/requirements.txt`.
- If the USB backend is missing, verify `libusb` is installed and compatible with the Python
  architecture (avoid mixing Intel/Rosetta Python with an ARM-only libusb installation).
- Stop other sensor probes before starting: they may already own interface 2. An existing stream
  can be reused, but a second process cannot independently claim the same interface.
- Stale poses or sensor errors suspend the world-fixed transform and fall back to the normal
  centered mirror. Details appear in the log at the bottom of the window.

File playback has been removed from the app. A developer-only command-line replay remains for
hardware-free protocol tests; see [Development](DEVELOPMENT.md).

## Multiple monitors

The current app creates **one** macOS virtual display. Multiple independent desktops are a possible
extension, not an existing setting. They need multiple virtual-display instances, one capture
stream per desktop, separate projected screen planes and a shared head reference. See the
[development roadmap](DEVELOPMENT.md#multiple-monitor-roadmap).
