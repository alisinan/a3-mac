#!/usr/bin/env python3
"""ThinkReality A3: initialized USB sensor capture, Python 3.9+.

macOS: brew install libusb; python -m pip install pyusb
Start A3 Monitor first, then:
  python tools/a3_sensor_probe.py capture --out a3-sensors.jsonl
Optional, if the current tracking mode produces no stream:
  python tools/a3_sensor_probe.py capture --tracking-mode rotational --out a3-rotational.jsonl
Offline decoding (no USB dependency needed):
  python tools/a3_sensor_probe.py decode a3-sensors.jsonl

Protocol reconstructed from SensorDataOceanblue.dll in Lenovo VDM 3.5.62.
Useful PE virtual addresses (image base 0x180000000): initial 0x180003380,
SendCommand 0x180001f00, empty/int command 0x180002290,
SetParam 0x180002370, GetParam 0x1800025a0, reader 0x1800028b0,
register_imu_callback 0x180003c10, register_pose_callback 0x180003c30.
Only USB protocol 1.2 is implemented. The earlier captured 272-byte status
transfer starts 01 1e 00 00 08 00 00 00 and matches this version.
Interface 2 (vendor class), bulk OUT 03, bulk IN 83, alternate 0.
Command transfer: <uint32 LE 0x4601, uint32 LE 258>, command structure
<uint8 command, uint8 payload length, uint8 reserved=0, uint8 payload[255]>,
followed by 6 zero bytes: total 272 bytes. Replies use (~command & 255).
Commands: 12 GetVRMode; 14 StartVRMode; 15 StopVRMode; 19 GetParam;
1b SetParam. Empty-command replies contain a signed LE int32 result.
SetParam payload: name length, ASCII name, value length, ASCII value.
GetParam request: ASCII name; reply: value length, ASCII value.
Incoming envelope byte 1: 46 command response, 53 IMU, 54 pose,
1e/55 status/other (ignored by the Windows sensor callback dispatcher).

Provisional payload offsets copied from Windows callback dispatch:
IMU: float32[3] at 24 and 128; int64 device timestamp at 120.
Pose: float32[4] at 0; float32[3] at 16; uint64 device timestamp at 32.
Axes, quaternion order, IMU vector identities and units are NOT validated.
No float is labelled as acceleration/angular velocity before motion testing.
Raw transfers, full headers, command replies and phase times are retained.
Decoding requires a complete envelope within one USB read, as used by the
Windows reader. Partial/unrecognised transfers are retained without guessing
framing or searching arbitrarily inside their payloads.

Capture starts/stops a tracking session. An optional mode change is restored
on exit; existing streaming sessions are reused without starting/stopping.
No device reset, configuration/alternate change, driver detach, firmware
operation or HID command. Unplugging or forcibly killing the process may
prevent cleanup. A3 Monitor's HID/display initialization is still required.
"""

import argparse
from collections import Counter
import ctypes.util
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import struct
import sys
import time

VID, PID, INTERFACE, BULK_IN, BULK_OUT = 0x17EF, 0xB813, 2, 0x83, 0x03
KINDS = {0x46: "command_response", 0x53: "imu", 0x54: "pose",
         0x1E: "status", 0x55: "other"}
MODES = ("rotational", "positional", "rotational_mag")
PHASES = [("still_start", "Ruhig und waagerecht halten."),
          ("yaw", "Langsam links/rechts drehen."),
          ("still_after_yaw", "Ruhig halten."),
          ("pitch", "Langsam hoch/runter nicken."),
          ("still_after_pitch", "Ruhig halten."),
          ("roll", "Langsam seitlich kippen."),
          ("still_tilted", "Gekippt ruhig halten."),
          ("still_end", "Wieder waagerecht ruhig halten.")]


def command_packet(command, payload=b""):
    if command not in (0x12, 0x14, 0x15, 0x19, 0x1B):
        raise ValueError("Befehl ist nicht fuer diesen Probe freigegeben.")
    if len(payload) > 255:
        raise ValueError("Command payload exceeds 255 bytes")
    body = bytes((command, len(payload), 0)) + payload.ljust(255, b"\0")
    return struct.pack("<II", 0x4601, len(body)) + body + bytes(6)


def floats(payload, offset, count):
    values = struct.unpack_from("<" + "f" * count, payload, offset)
    return [value if math.isfinite(value) else None for value in values]


def decode_transfer(data):
    if len(data) < 8:
        return {"kind": "unparsed", "reason": "short_header"}
    header, length = struct.unpack_from("<II", data)
    code = data[1]
    base = {"header_hex": data[:8].hex(), "header_word": header,
            "payload_length": length, "packet_code": code}
    if code not in KINDS or data[0] not in (1, 3):
        return dict(base, kind="unparsed", reason="unknown_header")
    if data[3] == 1:
        return dict(base, kind="ignored", reason="windows_discard_flag")
    if length > 1000 or length > len(data) - 8:
        return dict(base, kind="unparsed", reason="incomplete_or_invalid_length")
    payload = data[8:8 + length]
    result = dict(base, kind=KINDS[code], trailing_bytes=len(data) - 8 - length)
    if code == 0x46:
        if len(payload) < 3 or payload[1] > len(payload) - 3:
            return dict(result, kind="unparsed", reason="invalid_command_response")
        body = payload[3:3 + payload[1]]
        result.update(response_command=payload[0], response_length=payload[1],
                      response_reserved=payload[2], response_payload_hex=body.hex())
        if len(body) == 4:
            result["int32_candidate"] = struct.unpack("<i", body)[0]
    elif code == 0x53:
        if len(payload) < 140:
            return dict(result, kind="unparsed", reason="short_imu_payload")
        result.update(vector_at_24=floats(payload, 24, 3),
                      vector_at_128=floats(payload, 128, 3),
                      device_timestamp_raw=struct.unpack_from("<q", payload, 120)[0])
    elif code == 0x54:
        if len(payload) < 40:
            return dict(result, kind="unparsed", reason="short_pose_payload")
        q = floats(payload, 0, 4)
        result.update(quaternion_candidate=q, position_candidate=floats(payload, 16, 3),
                      device_timestamp_raw=struct.unpack_from("<Q", payload, 32)[0],
                      quaternion_norm=math.sqrt(sum(x*x for x in q))
                      if all(x is not None for x in q) else None)
    elif length % 4 == 0:
        result["uint32_values"] = list(struct.unpack("<" + "I" * (length // 4), payload))
    return result


def param_value(reply):
    body = bytes.fromhex(reply["response_payload_hex"])
    if not body or not 0 < body[0] <= len(body) - 1:
        raise RuntimeError("GetParam-Antwort hat keine gueltige Laengenangabe.")
    return body[1:1 + body[0]].decode("ascii").rstrip("\0")


def load_usb():
    try:
        import usb.backend.libusb1
        import usb.control
        import usb.core
        import usb.util
    except ImportError as exc:
        raise RuntimeError("python -m pip install pyusb erforderlich") from exc

    def find_library(name):
        found = ctypes.util.find_library(name)
        if found:
            return found
        for path in ("/opt/homebrew/lib/libusb-1.0.dylib", "/usr/local/lib/libusb-1.0.dylib"):
            if Path(path).is_file():
                return path
        return None

    backend = usb.backend.libusb1.get_backend(find_library=find_library)
    if backend is None:
        raise RuntimeError("libusb fehlt: brew install libusb")
    devices = list(usb.core.find(find_all=True, idVendor=VID, idProduct=PID, backend=backend))
    if len(devices) != 1:
        raise RuntimeError(f"Erwartet genau eine A3, gefunden: {len(devices)}")
    return usb, devices[0]


class Session:
    def __init__(self, usb, device, output):
        self.usb, self.device, self.output = usb, device, output
        self.counts = Counter()
        self.timeouts = 0
        self.phase = "preflight"

    def log(self, kind, **fields):
        record = dict(type=kind, t_host_ns=time.monotonic_ns(), **fields)
        self.output.write(json.dumps(record, ensure_ascii=False, allow_nan=False) + "\n")

    def poll(self):
        try:
            data = bytes(self.device.read(BULK_IN, 1024, timeout=100))
        except self.usb.core.USBTimeoutError:
            self.timeouts += 1
            return None
        if not data:
            return None
        decoded = decode_transfer(data)
        self.counts[decoded["kind"]] += 1
        self.log("chunk", phase=self.phase, endpoint=BULK_IN,
                 length=len(data), hex=data.hex(), decoded=decoded)
        return decoded

    def command(self, code, payload=b"", name=""):
        packet = command_packet(code, payload)
        self.log("command_tx", command=code, name=name, endpoint=BULK_OUT, hex=packet.hex())
        self.output.flush()
        written = self.device.write(BULK_OUT, packet, timeout=1000)
        if written != len(packet):
            raise RuntimeError(f"Unvollstaendiger USB-Write: {written}/{len(packet)}")
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            reply = self.poll()
            if (reply and reply["kind"] == "command_response"
                    and reply["response_command"] == (~code & 255)):
                self.log("command_reply", command=code, name=name, decoded=reply)
                self.output.flush()
                return reply
        raise RuntimeError(f"Keine passende Antwort auf {name or hex(code)} innerhalb 12 s")

    def integer(self, code, name):
        reply = self.command(code, name=name)
        if reply["response_length"] != 4:
            raise RuntimeError(f"{name}: erwartet 4 Antwortbytes, erhielt {reply['response_length']}")
        value = struct.unpack("<i", bytes.fromhex(reply["response_payload_hex"]))[0]
        print(f"{name}: {value}", flush=True)
        return value

    def get_param(self, name):
        value = param_value(self.command(0x19, name.encode("ascii"), "GetParam " + name))
        self.log("parameter", name=name, value=value)
        print(f"{name}: {value}", flush=True)
        return value

    def set_mode(self, mode):
        if mode not in MODES:
            raise RuntimeError("Tracking-Modus ist nicht bekannt; wird nicht gesetzt.")
        name, value = b"tracker-tracking-mode", mode.encode("ascii")
        payload = bytes((len(name),)) + name + bytes((len(value),)) + value
        reply = self.command(0x1B, payload, "SetTrackingMode " + mode)
        if reply["response_length"] != 4:
            raise RuntimeError("SetTrackingMode: ungueltiges Antwortformat")
        result = struct.unpack("<i", bytes.fromhex(reply["response_payload_hex"]))[0]
        if result != 0:
            raise RuntimeError(f"SetTrackingMode {mode}: Fehler {result}")


def capture(args):
    # Exclusive creation protects earlier hardware evidence.
    with Path(args.out).open("x", encoding="utf-8") as output:
        usb, device, claimed, session = None, None, False, None
        start_attempted, mode_attempted, original_mode = False, False, None
        exit_code, stage = 0, "open_device"
        def diagnostic(kind, **fields):
            output.write(json.dumps(dict(type=kind, **fields), ensure_ascii=False) + "\n")
            output.flush()
        diagnostic("metadata", schema=1, probe="a3_sensor_probe", protocol="1.2",
                   source="Lenovo VDM 3.5.62 SensorDataOceanblue.dll",
                   utc_start=datetime.now(timezone.utc).isoformat(),
                   phase_seconds=args.phase_seconds, requested_mode=args.tracking_mode,
                   field_semantics="provisional; axes/order/units unverified")
        try:
            usb, device = load_usb()
            stage = "validate_interface"
            cfg = device.get_active_configuration()
            interface = cfg[(INTERFACE, 0)]
            if interface.bInterfaceClass != 255:
                raise RuntimeError("Interface 2 ist nicht vendor-specific")
            for address in (BULK_IN, BULK_OUT):
                endpoints = [ep for ep in interface if ep.bEndpointAddress == address
                             and ep.bmAttributes & 3 == 2]
                if len(endpoints) != 1:
                    raise RuntimeError(f"Bulk-Endpunkt 0x{address:02x} fehlt")
            stage = "claim_interface_2"
            usb.util.claim_interface(device, INTERFACE)
            claimed = True
            if usb.control.get_interface(device, INTERFACE) != 0:
                raise RuntimeError("Aktives Alternate Setting ist nicht 0; keine Umschaltung")
            session = Session(usb, device, output)
            session.log("capture_target", vendor_id=VID, product_id=PID,
                        configuration=cfg.bConfigurationValue, interface=INTERFACE,
                        alternate=0, endpoint_in=BULK_IN, endpoint_out=BULK_OUT, read_size=1024)
            stage = "preflight"
            deadline = time.monotonic() + 0.5
            while time.monotonic() < deadline:
                session.poll()
            stage = "get_vr_mode"
            session.integer(0x12, "GetVRMode")
            # Responses themselves may arrive interleaved with an existing stream.
            existing_stream = bool(session.counts["imu"] + session.counts["pose"])
            if existing_stream:
                if args.tracking_mode != "keep":
                    raise RuntimeError("Sensorstream bereits aktiv. Mit --tracking-mode keep aufnehmen.")
                print("Sensorstream bereits aktiv; vorhandene Sitzung wird verwendet.", flush=True)
                session.log("session_ownership", owned=False)
            else:
                stage = "get_tracking_mode"
                original_mode = session.get_param("tracker-tracking-mode")
                stage = "get_supported_modes"
                session.get_param("tracker-supported-tracking-modes")
                if args.tracking_mode != "keep" and args.tracking_mode != original_mode:
                    if original_mode not in MODES:
                        raise RuntimeError("Aktueller Modus unbekannt; sichere Wiederherstellung nicht moeglich")
                    stage = "set_tracking_mode"
                    mode_attempted = True
                    session.set_mode(args.tracking_mode)
                stage = "start_vr_mode"
                start_attempted = True
                result = session.integer(0x14, "StartVRMode")
                if result != 0:
                    # An explicit rejection does not give us ownership of a
                    # potentially active session. Stop only after success or
                    # an ambiguous write/response failure.
                    start_attempted = False
                    raise RuntimeError(f"StartVRMode fehlgeschlagen: {result}")
                session.log("session_ownership", owned=True)
            stage = "capture"
            for phase, instruction in PHASES:
                session.phase = phase
                session.log("phase", phase=phase)
                output.flush()
                print(f"\n{phase} ({args.phase_seconds:g} s): {instruction}", flush=True)
                deadline = time.monotonic() + args.phase_seconds
                while time.monotonic() < deadline:
                    session.poll()
        except KeyboardInterrupt:
            exit_code = 130
            diagnostic("interrupted", stage=stage)
            print("Abgebrochen; Tracking wird beendet.", flush=True)
        except Exception as exc:
            exit_code = 1
            diagnostic("error", stage=stage, error_class=type(exc).__name__, message=str(exc))
            print(f"Fehler bei {stage}: {exc}", file=sys.stderr, flush=True)
        finally:
            if session:
                session.phase = "cleanup"
                if start_attempted:
                    try:
                        result = session.integer(0x15, "StopVRMode")
                        if result != 0:
                            raise RuntimeError(f"StopVRMode: Fehler {result}")
                    except Exception as exc:
                        diagnostic("cleanup_error", action="stop_tracking", message=str(exc))
                        exit_code = exit_code or 1
                if mode_attempted:
                    try:
                        session.set_mode(original_mode)
                        print(f"Tracking-Modus wiederhergestellt: {original_mode}", flush=True)
                    except Exception as exc:
                        diagnostic("cleanup_error", action="restore_mode", message=str(exc))
                        exit_code = exit_code or 1
            if claimed:
                try:
                    usb.util.release_interface(device, INTERFACE)
                except Exception as exc:
                    diagnostic("cleanup_error", action="release_interface", message=str(exc))
                    exit_code = exit_code or 1
            if device is not None:
                try:
                    usb.util.dispose_resources(device)
                except Exception as exc:
                    diagnostic("cleanup_error", action="dispose_resources", message=str(exc))
                    exit_code = exit_code or 1
            counts = dict(session.counts) if session else {}
            diagnostic("end", counts=counts, timeouts=session.timeouts if session else 0,
                       exit_code=exit_code)
            print(f"\nPakete: {counts}\nAufnahme gespeichert: {args.out}", flush=True)
        return exit_code


def decode_file(path):
    counts = Counter()
    first = {}
    with Path(path).open(encoding="utf-8") as source:
        for line in source:
            record = json.loads(line)
            if record.get("type") != "chunk":
                continue
            decoded = decode_transfer(bytes.fromhex(record["hex"]))
            kind = decoded["kind"]
            counts[kind] += 1
            first.setdefault(kind, decoded)
    print(json.dumps(dict(counts=dict(counts), first_packet=first), ensure_ascii=False, indent=2))
    return 0


def seconds(text):
    value = float(text)
    if not math.isfinite(value) or not 0 < value <= 60:
        raise argparse.ArgumentTypeError("Phasendauer muss zwischen 0 und 60 Sekunden liegen")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    cap = commands.add_parser("capture", help="Tracking initialisieren und Sensorstream aufnehmen")
    cap.add_argument("--out", default="a3-sensors.jsonl")
    cap.add_argument("--phase-seconds", type=seconds, default=5)
    cap.add_argument("--tracking-mode", choices=("keep",) + MODES, default="keep",
                     help="Optionaler Moduswechsel; urspruenglicher Modus wird wiederhergestellt")
    decode = commands.add_parser("decode", help="JSONL-Aufnahme offline zusammenfassen")
    decode.add_argument("path")
    args = parser.parse_args()
    try:
        return capture(args) if args.command == "capture" else decode_file(args.path)
    except Exception as exc:
        print(f"Fehler: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
