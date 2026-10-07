#!/usr/bin/env python3
"""ThinkReality A3 USB descriptor and bulk-IN probe (Python 3.9+).

Prerequisites on macOS: brew install libusb; python -m pip install pyusb
Put under tools/ in your fork, then start A3 Monitor and run:
    python tools/a3_usb_probe.py describe --out a3-usb-info.json
    python tools/a3_usb_probe.py capture --out a3-bulk.jsonl
    python tools/a3_usb_probe.py capture --endpoint 0x84 --out a3-interrupt.jsonl

Describe enumerates USB configurations, interfaces and endpoints. Capture claims
ONLY vendor-specific interface 2 in the existing active configuration, queries
its current alternate setting (standard GET_INTERFACE) and reads bulk-IN or,
with an explicit --endpoint, interrupt-IN in
alternate setting 0. Other active settings are reported for further inspection.
No vendor commands, OUT transfers, configuration/alternate-setting changes,
driver detachment, device reset or firmware operations are performed.

Opening/claiming an interface may conflict with another client. Busy/access
errors are recorded instead of forcing access. USB timeouts alone do not prove
the absence of an IMU: initialization may be required. Captured chunks are USB
transfer fragments, NOT necessarily complete sensor packets. All time stamps
are host receive times. The script is a probe, not an IMU decoder.

Reference: https://github.com/alisinan/a3-mac/blob/main/docs/PROTOCOL.md
PyUSB documentation: https://github.com/pyusb/pyusb/blob/master/docs/tutorial.rst
"""

import argparse
import ctypes.util
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time

VID, PID, SENSOR_INTERFACE = 0x17EF, 0xB813, 2
PHASES = [
    ("still_start", "Ruhig und waagerecht halten."),
    ("yaw", "Langsam links/rechts drehen."),
    ("still_after_yaw", "Ruhig halten."),
    ("pitch", "Langsam hoch/runter nicken."),
    ("still_after_pitch", "Ruhig halten."),
    ("roll", "Langsam seitlich kippen."),
    ("still_tilted", "Gekippt ruhig halten."),
    ("still_end", "Wieder waagerecht ruhig halten."),
]


def load_usb():
    try:
        import usb.backend.libusb1
        import usb.control
        import usb.core
        import usb.util
    except ImportError as exc:
        raise RuntimeError("Abhaengigkeit fehlt: python -m pip install pyusb") from exc

    def find_library(name):
        found = ctypes.util.find_library(name)
        if found:
            return found
        for path in ("/opt/homebrew/lib/libusb-1.0.dylib",
                     "/usr/local/lib/libusb-1.0.dylib"):
            if Path(path).is_file():
                return path
        return None

    backend = usb.backend.libusb1.get_backend(find_library=find_library)
    if backend is None:
        raise RuntimeError("libusb-Backend fehlt. Auf macOS: brew install libusb")
    devices = list(usb.core.find(find_all=True, idVendor=VID, idProduct=PID, backend=backend))
    if len(devices) != 1:
        raise RuntimeError(f"Erwartet genau eine A3, gefunden: {len(devices)}.")
    return usb, devices[0]


def describe(device):
    result = {"vendor_id": VID, "product_id": PID,
              "bus": device.bus, "address": device.address,
              "device_class": device.bDeviceClass,
              "usb_version": device.bcdUSB, "device_version": device.bcdDevice,
              "configurations": []}
    names = {0: "control", 1: "isochronous", 2: "bulk", 3: "interrupt"}
    for configuration in device:
        cfg = {"configuration": configuration.bConfigurationValue, "interfaces": []}
        for interface in configuration:
            info = {"interface": interface.bInterfaceNumber,
                    "alternate": interface.bAlternateSetting,
                    "class": interface.bInterfaceClass,
                    "subclass": interface.bInterfaceSubClass,
                    "protocol": interface.bInterfaceProtocol, "endpoints": []}
            for endpoint in interface:
                info["endpoints"].append({
                    "address": endpoint.bEndpointAddress,
                    "address_hex": f"0x{endpoint.bEndpointAddress:02X}",
                    "direction": "IN" if endpoint.bEndpointAddress & 0x80 else "OUT",
                    "transfer_type": names[endpoint.bmAttributes & 3],
                    "max_packet_size": endpoint.wMaxPacketSize,
                    "interval": endpoint.bInterval})
            cfg["interfaces"].append(info)
        result["configurations"].append(cfg)
    return result


def choose_endpoint(interface, address):
    if interface.bInterfaceNumber != SENSOR_INTERFACE or interface.bInterfaceClass != 255:
        raise RuntimeError("Capture ist nur fuer Vendor-Interface 2 zugelassen.")
    inputs = [endpoint for endpoint in interface
              if endpoint.bEndpointAddress & 0x80
              and (endpoint.bmAttributes & 3) in (2, 3)]
    if address is None:
        inputs = [endpoint for endpoint in inputs if (endpoint.bmAttributes & 3) == 2]
    else:
        inputs = [endpoint for endpoint in inputs if endpoint.bEndpointAddress == address]
    if len(inputs) != 1:
        raise RuntimeError("IN-Endpunkt nicht eindeutig/passend. Deskriptoren pruefen und ggf. "
                           "--endpoint 0xNN mit einer dort gelisteten Bulk-/Interrupt-IN-Adresse verwenden.")
    return inputs[0]


def capture(args, usb, device, metadata):
    stage, claimed, count, total_bytes, timeouts = "open_log", False, 0, 0, 0
    with Path(args.out).open("x", encoding="utf-8") as output:
        def write(record):
            output.write(json.dumps(record, ensure_ascii=False) + "\n")

        write({"type": "metadata", "schema": 1,
               "utc_start": datetime.now(timezone.utc).isoformat(),
               "device": metadata, "timestamp_kind": "host_receive_monotonic_ns",
               "phase_seconds": args.phase_seconds})
        try:
            stage = "get_active_configuration"
            configuration = device.get_active_configuration()
            candidates = [interface for interface in configuration
                          if interface.bInterfaceNumber == SENSOR_INTERFACE]
            if not candidates or any(interface.bInterfaceClass != 255 for interface in candidates):
                raise RuntimeError("Aktive Konfiguration hat kein passendes Vendor-Interface 2.")
            stage = "claim_interface_2"
            usb.util.claim_interface(device, SENSOR_INTERFACE)
            claimed = True
            stage = "get_current_alternate_setting"
            alternate = usb.control.get_interface(device, SENSOR_INTERFACE)
            if alternate != 0:
                # PyUSB assumes alternate 0 until set_interface_altsetting() is
                # called. Stop rather than change device state or claim a wrong
                # interface through its automatic endpoint lookup.
                raise RuntimeError(f"Aktives Alternate Setting ist {alternate}, erwartet 0. "
                                   "Deskriptoren zuerst pruefen; es wird nichts umgeschaltet.")
            interface = configuration[(SENSOR_INTERFACE, alternate)]
            stage = "select_in_endpoint"
            endpoint = choose_endpoint(interface, args.endpoint)
            # One complete USB packet per read; preserve stream fragments in order.
            read_size = endpoint.wMaxPacketSize & 0x7FF
            if read_size <= 0:
                raise RuntimeError("Ungueltige maximale Paketgroesse.")
            write({"type": "capture_target", "configuration": configuration.bConfigurationValue,
                   "interface": SENSOR_INTERFACE, "alternate": alternate,
                   "endpoint": endpoint.bEndpointAddress, "read_size": read_size,
                   "transfer_type": "bulk" if (endpoint.bmAttributes & 3) == 2 else "interrupt"})
            print(f"Lese Interface 2, Alt {alternate}, Endpoint "
                  f"0x{endpoint.bEndpointAddress:02X}, {read_size} Bytes pro USB-Read.", flush=True)
            stage = "input_read"
            for phase, instruction in PHASES:
                start = time.monotonic_ns()
                deadline = start + int(args.phase_seconds * 1e9)
                write({"type": "phase", "phase": phase, "t_host_ns": start})
                output.flush()
                print(f"\n{phase} ({args.phase_seconds:g} s): {instruction}", flush=True)
                while time.monotonic_ns() < deadline:
                    try:
                        data = bytes(device.read(endpoint.bEndpointAddress, read_size, timeout=100))
                    except usb.core.USBTimeoutError:
                        timeouts += 1
                        continue
                    if data:
                        write({"type": "chunk", "phase": phase,
                               "endpoint": endpoint.bEndpointAddress,
                               "t_host_ns": time.monotonic_ns(),
                               "length": len(data), "hex": data.hex()})
                        count += 1
                        total_bytes += len(data)
            write({"type": "end", "chunks": count, "bytes": total_bytes,
                   "timeouts": timeouts, "t_host_ns": time.monotonic_ns()})
            print(f"\nFertig: {count} Chunks, {total_bytes} Bytes, {timeouts} Timeouts -> {args.out}")
            return 0
        except KeyboardInterrupt:
            write({"type": "end", "interrupted": True, "chunks": count,
                   "bytes": total_bytes, "timeouts": timeouts})
            print("Abgebrochen; bisherige Daten gespeichert.")
            return 130
        except Exception as exc:
            write({"type": "error", "stage": stage, "message": str(exc),
                   "error_class": type(exc).__name__, "chunks": count,
                   "bytes": total_bytes, "timeouts": timeouts})
            print(f"Fehler bei {stage}: {exc}\nDiagnose gespeichert: {args.out}", file=sys.stderr)
            return 1
        finally:
            if claimed:
                try:
                    usb.util.release_interface(device, SENSOR_INTERFACE)
                except Exception as exc:
                    write({"type": "cleanup_error", "message": str(exc)})


def seconds(value):
    number = float(value)
    if not 0 < number <= 60:
        raise argparse.ArgumentTypeError("Phasendauer muss zwischen 0 und 60 Sekunden liegen.")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    info = commands.add_parser("describe", help="USB-Konfigurationen und Endpunkte lesen")
    info.add_argument("--out", default="a3-usb-info.json")
    cap = commands.add_parser("capture", help="Vendor-Interface 2 / Bulk- oder Interrupt-IN lesen")
    cap.add_argument("--out", default="a3-bulk.jsonl")
    cap.add_argument("--phase-seconds", type=seconds, default=5)
    cap.add_argument("--endpoint", type=lambda value: int(value, 0),
                     help="Optional: gelistete Bulk-/Interrupt-IN-Adresse von Interface 2, z.B. 0x84")
    args = parser.parse_args()
    device, usb = None, None
    try:
        usb, device = load_usb()
        metadata = describe(device)
        if args.command == "describe":
            with Path(args.out).open("x", encoding="utf-8") as output:
                json.dump(metadata, output, ensure_ascii=False, indent=2)
                output.write("\n")
            print(json.dumps(metadata, ensure_ascii=False, indent=2))
            print(f"\nGespeichert: {args.out}")
            return 0
        return capture(args, usb, device, metadata)
    except Exception as exc:
        print(f"Fehler: {exc}", file=sys.stderr)
        print("Bei Zugriff/Busy: konkurrierenden Zugriff pruefen. "
              "Dieses Skript erzwingt keinen Treiberzugriff.", file=sys.stderr)
        return 1
    finally:
        if device is not None:
            try:
                usb.util.dispose_resources(device)
            except Exception as exc:
                print(f"Fehler beim Schliessen: {exc}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
