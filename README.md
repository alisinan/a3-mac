<p align="center"><img src="docs/icon.png" width="128" alt="A3 Monitor icon"></p>

# A3 Monitor for macOS

Use the **Lenovo ThinkReality A3** AR glasses on a Mac, as a normal monitor and as a teleprompter.

<p align="center"><img src="docs/demo.gif" width="480" alt="Teleprompter text seen through the A3's lens"><br>
<sub>The built-in teleprompter, filmed through the A3's lens.</sub></p>

Lenovo only ever shipped Windows (and Motorola phone) software for the A3, and the product is end-of-life.
Plugged into a Mac, the glasses show nothing. This project gets them working:

- **Turns the glasses' display on** over USB-HID (the same command Lenovo's Windows software sends).
- **Monitor mode:** adds a 1920 × 1080 virtual display called *Glasses Screen* and mirrors it into both eyes,
  so the A3 behaves like a flat second monitor. Both eyes, left eye only, or right eye only.
- **Optional head tracking:** keeps one monitor fixed in orientation as you turn your head, with
  gravity-aligned Recenter, adaptive smoothing and short gyro prediction. Requires Python/PyUSB.
- **Adjust the picture:** move it up or down, make it smaller, or change the perceived distance.
- **Prompter:** a built-in teleprompter. The control window is on your Mac, the text floats in front of you.
  Black is transparent on the glasses, so only the text is visible. Includes legibility settings
  (weight, extra thickness, letter spacing) that help if you don't wear your glasses under the A3.
- Menu-bar app, optional launch at login.

## Background

I was given a ThinkReality A3 to test when it launched. It works with my ThinkPad, but for the last two
years I've mostly used a Mac, and on a Mac the glasses show nothing, so they ended up on a shelf.
One evening I took them down and wondered whether I could solve this together with Claude (Opus 5.5).
A few hours later they worked as a monitor and a teleprompter. This repo is the result.

> Not affiliated with or endorsed by Lenovo. "Lenovo" and "ThinkReality" are trademarks of Lenovo.
> Use at your own risk. This project uses display and sensor commands reconstructed from Lenovo's software,
> and never touches the firmware-update commands.

## Requirements

- A Lenovo ThinkReality A3 (PC Edition tested)
- A Mac whose USB-C port supports DisplayPort Alt Mode (tested on Apple M2 Pro)
- macOS 13 or later
- Xcode or the Command Line Tools (`xcode-select --install`) to build

## Build and install

```bash
git clone https://github.com/alisinan/a3-mac.git
cd a3-mac/app
bash build.sh --install
```

This builds `A3 Monitor.app`, copies it to `/Applications` and opens it.
Use `bash build.sh` to build without installing. Head tracking is optional; the monitor and
teleprompter work without Python. See [Head tracking](docs/HEAD_TRACKING.md) to install its dependencies.

On first launch macOS asks for **Screen Recording** permission (needed to mirror the virtual display).
Allow it, then quit A3 Monitor from its menu and open it again. It may also ask for **Input Monitoring**
(used to send the display-on command to the glasses).

The app is signed ad hoc, so every rebuild counts as a new app for macOS and you'll be asked for
Screen Recording permission once more. `build.sh` clears the stale entry for you.

## Use

1. Plug in the glasses. A3 Monitor turns their display on within a few seconds.
2. In **System Settings › Displays**, place **Glasses Screen** next to your main display. That's the
   screen you drag windows to. Move **Think A3** (the physical glasses output, which A3 Monitor covers)
   to a corner out of the way. The mouse is kept out of it.
3. Use the **A3** menu-bar item:
   - *Both eyes / Left eye only / Right eye only*
   - *Resolution:* 1920×1080 down to 1024×576 (lower = bigger text)
   - *Image size, Move image up / down, Image nearer / farther*
   - *Head tracking…* opens tracking setup, diagnostics and the monitor-size slider
   - *Recenter monitor* works while tracking continues with its window closed
   - *Stop head tracking* stops the sensor process
   - *Prompter…* opens the teleprompter
   - *Open at login*

<p align="center"><img src="docs/menu.png" width="300" alt="A3 Monitor menu-bar menu"></p>

### Prompter

*Prompter…* opens the control window on your Mac. Paste your script, set speed, size and legibility;
the text appears on the glasses.

<p align="center"><img src="docs/prompter.png" width="760" alt="A3 Prompter control window"></p>

#### Keys (control window focused)

| Key | Action |
|---|---|
| Space / Page Down | play / pause |
| ↑ ↓ | speed |
| ← → / Page Up | jump back / forward 3 lines |
| + − | font size |
| R / Home | back to top |

Text in `[brackets]` is shown dimmed, for cues. Most presentation clickers send Page Up / Page Down.

`prompter/a3_prompter.html` also works on its own in a browser (open it, click *Open display window*,
move that window onto the glasses and press F).

## Command-line tools

`tools/` has small Python diagnostic scripts. The HID ones need `pip install hidapi`;
the USB ones need `pip install pyusb` and, on macOS, `brew install libusb`.
Run A3 Monitor first so its normal initialization has happened.

- `a3_display.py on` turns the display on without the app; `status`, `display on|off`, `wake`.
- `a3_probe.py` lists the glasses' HID interfaces. Read-only.
- `a3_imu_probe.py` `list`/`capture`/`analyze` reads the raw HID interface 0 (usage page 0x8C)
  and writes the input reports to JSONL; `capture --guided` records eight marked motion phases,
  `analyze` summarises report counts and the bytes that vary. A raw-data acquisition tool, not an
  IMU decoder; sends no firmware or vendor commands.
- `a3_usb_probe.py` `describe`/`capture` lists the USB configurations, interfaces and endpoints and
  then reads bulk-IN or, with `--endpoint`, interrupt-IN from vendor interface 2. A probe, not an
  IMU decoder; claims only that interface and sends no vendor or firmware commands.
- `a3_sensor_probe.py` `capture`/`decode` initialises a tracking session, records the vendor USB sensor
  stream to JSONL and decodes it offline; an optional `--tracking-mode` change is restored on exit.
- `a3_sensor_probe_v2.py` `capture`/`decode` does the same with hardware-confirmed IMU and pose
  decoding (gyro, accelerometer, quaternion) and optional CSV export via `--csv`.

## How it works

The A3 is a USB-C device with a DisplayPort Alt Mode video input plus a bunch of USB interfaces
(HID, cameras, audio). It won't enable DisplayPort until the host sends a `HostInfo` command on
a vendor HID channel. After that it appears as a 3840 × 1080 side-by-side display: the left half
goes to the left eye, the right half to the right eye.

A3 Monitor:

1. sends `HostInfo` over IOKit HID,
2. creates a 1920 × 1080 virtual display with `CGVirtualDisplay` (a private CoreGraphics API, also used by
   DeskPad and BetterDisplay),
3. captures it with ScreenCaptureKit, and
4. draws each frame into both halves of a borderless window covering the glasses' display.

The prompter is a WebKit page shown full-screen on the virtual display, so it goes through the same mirror.

Optional tracking reads fused orientation and IMU data from USB interface 2 through a bundled Python
bridge. Swift projects the captured monitor against head rotation at the physical display cadence.

- [Head-tracking setup and controls](docs/HEAD_TRACKING.md)
- [Architecture, testing and development](docs/DEVELOPMENT.md)
- [USB protocol notes](docs/PROTOCOL.md)

## Known limitations

- `CGVirtualDisplay` is undocumented. A future macOS update could break it.
- The glasses' own display still appears in System Settings › Displays. macOS offers no way to hide
  a connected display without cutting its signal.
- The optics have a fixed focal distance. Software can't correct for short-sightedness. Prescription
  inserts or contact lenses can.
- Tracking currently supports **one virtual monitor and rotation only (3DoF)**. Leaning or walking
  does not change its perspective; cameras, SLAM and positional tracking are not used.
- The glasses' fused orientation can drift. Recenter resets the host anchor, not the device estimator.
  A moving vehicle adds real rotation and acceleration; there is no reference to the cabin.
- Tracking does not start automatically, and ⌘R is an app shortcut, not a system-wide hotkey.

## License

MIT, see [LICENSE](LICENSE).
