# ThinkReality A3 USB protocol notes

What we know about how a host talks to the Lenovo ThinkReality A3 (USB VID `0x17EF`, PID `0xB813`).
Worked out by reading the public Lenovo Virtual Display Manager installer (v3.5.62, `HIDOceanblue.dll`
and `LXRCompositor.exe`) and testing on a real A3 connected to a Mac. Nothing here is official.

"OceanBlue" / "OB" is the internal code name for the A3 in Lenovo's software.

## USB interfaces

| Interface | Class | What it is |
|---|---|---|
| 0 | HID, usage page `0x8C` | Raw data pipe, 512-byte reports |
| 1 | HID | Physical buttons (Consumer Control: volume/brightness; System Control) |
| 2 | Vendor specific (255) | Bulk sensor channel: IN `0x83`, OUT `0x03`; optional head tracking |
| 3–5 | Audio | Speakers and microphones |
| 6–9 | Video (UVC) | Cameras |
| 10 | HID, usage page `0x8C` | **Command channel**, 128-byte reports (called `CMD` in Lenovo's DLL) |
| 11 | HID, usage page `0x8C` | 1024-byte reports (called `OTA`, firmware update) |

Lenovo's DLL picks the channels by sorting the usage-page-`0x8C` interfaces by number:
the highest is OTA, the second highest is CMD.

## Command packets (interface 10)

128-byte output reports, report ID 0 (so on Windows / hidapi you write 129 bytes starting with `0x00`).

```
request:  4F 42 <cmd> <type> <params...>   zero-padded to 128 bytes   ('O' 'B')
response: 42 4F <cmd> <type> <status> <value> ...                     ('B' 'O')
          status 0xA0 = OK
type:     C1 = set, C3 = get
```

### Commands confirmed on hardware

| Command | Bytes | Notes |
|---|---|---|
| HostInfo(host, mode) | `03 C1 <host> <mode>` | **Required before the glasses output any image.** Lenovo's DLL only accepts `host = 0` and `mode` 0–2. Lenovo's compositor sends `(0, 1)` = `HOST_TYPE_WINDOWS_PC, DP_MS_DR_MODE`. On macOS modes 1 and 2 bring up DisplayPort; mode 0 does not. |
| GetDPState | `03 C3` | `value`: `0xA0` = DP ready, `0xA1` = DP error, anything else (e.g. `0xA2`) = not ready yet. Takes ~4 s after HostInfo. |
| DisplayControl(on) | `11 C1 <0/1>` | |
| SuspendControl(on) | `07 C1 <0/1>` | |
| GetSuspendState | `07 C3` | |

### Other functions exported by Lenovo's DLL (not mapped / not tested)

`AutoBrightness`, `GetBrightness`, `SetBrightness`, `GetBuildVersion`, `GetSerialNumber`, `GetLenovoID`,
`SetLenovoID`, `LEDControl`, `GetPSensorState`, `GetGlassesTemperatures`, `GetCalibrationData`,
`SetPollingPeriodsAndThresholds`, and the firmware-update family (`StartOTA`, `SendOTAData`, `SetOTAImage`,
`OTAStartUpdate`, `OTAReboot`, `GetOTAState`, `SetOTAState`, `GetOSCFile`).

**Do not experiment with the OTA commands.** They drive the firmware updater and could brick the glasses.

## Display

Once DisplayPort is up, the glasses report a single mode in their EDID:

- **3840 × 1080 @ 60 Hz**, 297 MHz pixel clock, monitor name `Think A3`
- The left 1920 px go to the left eye, the right 1920 px to the right eye (side-by-side stereo).
- There is no 1920 × 1080 "2D" mode, so a normal desktop looks doubled. A3 Monitor works around
  this by creating a 1920 × 1080 virtual display and copying it into both halves.
- Keep the display at its native 3840 × 1080 (not a scaled "looks like" mode), or the halves won't line up.
- Black pixels are transparent on the optics.


## Sensor channel (interface 2)

The optional tracking bridge uses the vendor-specific bulk interface, independently of the HID
command channel above. Protocol 1.2 was reconstructed from `SensorDataOceanblue.dll` in Lenovo
VDM 3.5.62 and checked against a macOS hardware recording. This remains unofficial.

| Item | Observed layout |
|---|---|
| Command packet | 272 bytes; little-endian envelope `0x4601`, length 258, command byte and payload length, reserved byte, payload area and trailing padding. |
| Replies | Envelope type `0x46`, reply command is `~command & 0xff`. |
| IMU (`0x53`) | 208-byte payload: two 104-byte Android-style records. Gyro type 16 and acceleration type 35, with values, biases and nanosecond timestamps. |
| Pose (`0x54`) | float32 quaternion **x,y,z,w** at offset 0, float32 position at 16, uint64 timestamp at 32. |
| Session commands | `0x12` GetVRMode, `0x14` StartVRMode, `0x15` StopVRMode, `0x19` GetParam. |

Gyro is interpreted in rad/s and acceleration in m/s² including gravity, following the Android
uncalibrated sensor layouts. The observed field normally named reserved0 acts as an event counter.
Quaternion order was checked by matching local angular velocity against the gyro. Position was
zero in the tested rotational mode; its units and usable positional tracking remain unvalidated.

The live app does not switch tracking modes. It reuses a stream if one is already active and stops
only a session it started. See [Development](DEVELOPMENT.md) for ownership, coordinate mapping,
bridge schema and tests. Full byte layouts and decoder notes live in the module docstring of
`app/TrackingBridge/a3_usb_protocol.py`.
