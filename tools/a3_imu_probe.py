#!/usr/bin/env python3
"""Read-only ThinkReality A3 HID stream probe (Python 3.9+).

Put this file in your fork's tools/ directory. Install the Python package
`hidapi` (not the separate `hid` package), then run:

    python a3_imu_probe.py list
    python a3_imu_probe.py capture --guided --out a3-motion.jsonl
    python a3_imu_probe.py analyze a3-motion.jsonl

The capture opens only the documented raw HID interface 0, usage page 0x8C.
If macOS cannot identify its interface number, stop and inspect the enumeration;
there is intentionally no fallback to arbitrary HID or firmware channels.
No output reports, feature reports, vendor commands or firmware operations are
sent. Opening a device still requires OS access and may conflict with another
client. Start with A3 Monitor running so its normal initialization has happened.

This is a raw-data acquisition tool, not an IMU decoder. Empty capture does NOT
prove absence of an IMU: streaming may need initialization or use USB bulk.
Timestamps are host receive times, NOT hardware sample timestamps. A report may
contain several sensor samples. Byte changes alone do not prove IMU content.

Protocol reference: https://github.com/alisinan/a3-mac/blob/main/docs/PROTOCOL.md
HID bindings: https://github.com/trezor/cython-hidapi
"""

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
from pathlib import Path
import sys
import time

VID, PID = 0x17EF, 0xB813
PHASES = [
    ("still_start", "Brille ruhig und waagerecht halten."),
    ("yaw", "Langsam links/rechts drehen; zwischendurch kurz stoppen."),
    ("still_after_yaw", "Brille wieder ruhig halten."),
    ("pitch", "Langsam hoch/runter nicken; zwischendurch kurz stoppen."),
    ("still_after_pitch", "Brille wieder ruhig halten."),
    ("roll", "Langsam seitlich kippen; zwischendurch kurz stoppen."),
    ("still_tilted", "Brille seitlich gekippt ruhig halten."),
    ("still_end", "Brille wieder waagerecht ruhig halten."),
]


def hid_module():
    try:
        import hid
    except ImportError as exc:
        raise RuntimeError("Abhaengigkeit fehlt: python -m pip install hidapi") from exc
    if not hasattr(hid, "device") or not hasattr(hid, "enumerate"):
        raise RuntimeError("Falsches hid-Modul; benoetigt wird das Paket hidapi.")
    return hid


def enumerate_a3(hid):
    # Stable within one connected-device session; de-duplicate usage collections.
    by_path = {}
    for entry in hid.enumerate(VID, PID):
        path = entry["path"]
        previous = by_path.get(path)
        if previous is None or entry.get("usage_page") == 0x8C:
            by_path[path] = entry
    return sorted(by_path.values(), key=lambda entry: str(entry["path"]))


def serializable(entry):
    return {key: value.decode("utf-8", errors="backslashreplace")
            if isinstance(value, bytes) else value for key, value in entry.items()}


def show_devices(entries):
    print(f"A3 HID-Pfade: {len(entries)} (VID=0x{VID:04X}, PID=0x{PID:04X})")
    for index, entry in enumerate(entries):
        print(json.dumps({"index": index, **serializable(entry)}, ensure_ascii=False))


def select_raw(entries, index):
    if index is None:
        candidates = [entry for entry in entries
                      if entry.get("interface_number") == 0
                      and entry.get("usage_page") == 0x8C]
        if len(candidates) != 1:
            raise RuntimeError("Raw-HID nicht eindeutig identifiziert. Ausgabe von 'list' "
                               "pruefen; bei mehreren Raw-Pfaden --index N verwenden. "
                               "Bei Interface -1/fehlend zunaechst die IOKit-Enumeration klaeren.")
        return candidates[0]
    if not 0 <= index < len(entries):
        raise RuntimeError("Index liegt ausserhalb der Liste.")
    entry = entries[index]
    if entry.get("interface_number") != 0 or entry.get("usage_page") != 0x8C:
        raise RuntimeError("Nur Interface 0 / Usage Page 0x8C ist fuer diesen Probe zugelassen.")
    return entry


def capture(args, hid, entry):
    phases = PHASES if args.guided else [("free", "Frei bewegen oder ruhig halten.")]
    duration = args.phase_seconds if args.guided else args.seconds
    device = hid.device()
    count, phase_counts, interrupted = 0, Counter(), False
    try:
        # Exclusive create prevents accidental loss of an earlier measurement.
        with Path(args.out).open("x", encoding="utf-8") as output:
            def write(record):
                output.write(json.dumps(record, ensure_ascii=False) + "\n")

            write({"type": "metadata", "schema": 1,
                   "utc_start": datetime.now(timezone.utc).isoformat(),
                   "device": serializable(entry), "guided": args.guided,
                   "phase_seconds": duration, "timestamp_kind": "host_receive_monotonic_ns",
                   "read_only": True})
            device.open_path(entry["path"])
            print("Raw-HID geoeffnet. Es werden ausschliesslich Input-Reports gelesen.")
            try:
                for phase, instruction in phases:
                    phase_start = time.monotonic_ns()
                    deadline = phase_start + int(duration * 1e9)
                    write({"type": "phase", "phase": phase, "t_host_ns": phase_start})
                    output.flush()
                    print(f"\n{phase} ({duration:g} s): {instruction}", flush=True)
                    tick = time.monotonic() + 1
                    while time.monotonic_ns() < deadline:
                        # Oversized buffer retains an entire report incl. any report ID.
                        data = device.read(4096, 10)
                        received = time.monotonic_ns()
                        if data:
                            payload = bytes(data)
                            write({"type": "report", "phase": phase, "t_host_ns": received,
                                   "length": len(payload), "hex": payload.hex()})
                            count += 1
                            phase_counts[phase] += 1
                        if time.monotonic() >= tick:
                            print(f"  {phase_counts[phase]} Reports in dieser Phase", flush=True)
                            tick = time.monotonic() + 1
                write({"type": "end", "reports": count, "t_host_ns": time.monotonic_ns()})
            except KeyboardInterrupt:
                interrupted = True
                write({"type": "end", "interrupted": True, "reports": count,
                       "t_host_ns": time.monotonic_ns()})
    finally:
        device.close()
    print(f"\n{'Abgebrochen' if interrupted else 'Fertig'}: {count} Reports -> {args.out}")
    if count == 0:
        print("Keine Reports: Zugriff, Aktivierungssequenz oder Bulk-Kanal untersuchen; "
              "das ist kein Nachweis einer fehlenden IMU.")


def analyze(path):
    groups = defaultdict(lambda: {"count": 0, "first": None, "last": None,
                                  "min": [], "max": []})
    phases = []
    with Path(path).open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            try:
                record = json.loads(line)
                if record.get("type") == "phase":
                    phases.append(record["phase"])
                if record.get("type") != "report":
                    continue
                data = bytes.fromhex(record["hex"])
                if record["length"] != len(data):
                    raise ValueError("Laengenangabe passt nicht zu hex")
                key = (record["phase"], len(data))
                group = groups[key]
                if group["count"] == 0:
                    group["min"], group["max"] = list(data), list(data)
                    group["first"] = record["t_host_ns"]
                for offset, value in enumerate(data):
                    group["min"][offset] = min(group["min"][offset], value)
                    group["max"][offset] = max(group["max"][offset], value)
                group["count"] += 1
                group["last"] = record["t_host_ns"]
            except (ValueError, KeyError, TypeError) as exc:
                raise RuntimeError(f"Ungueltige Aufzeichnung, Zeile {line_number}: {exc}") from exc
    for phase in dict.fromkeys(phases):
        if not any(key[0] == phase for key in groups):
            print(f"{phase}: 0 Reports")
    for (phase, length), group in groups.items():
        changed = [offset for offset in range(length)
                   if group["min"][offset] != group["max"][offset]]
        span = (group["last"] - group["first"]) / 1e9
        rate = (group["count"] - 1) / span if span > 0 else 0
        print(f"{phase}: {group['count']} Reports, {length} Bytes, "
              f"ca. {rate:.1f} Reports/s am Host")
        print(f"  Variable Byte-Offsets (nullbasiert, erste 64/{len(changed)}): {changed[:64]}")
    if not groups:
        print("Keine Input-Reports in dieser Datei.")
    print("Hinweis: Zaehler/Zeitstempel aendern sich auch im Stillstand. "
          "Variabilitaet allein identifiziert keine IMU; unterschiedliche Pakettypen "
          "koennen dieselbe Laenge haben.")


def positive(value):
    number = float(value)
    if not 0 < number <= 600:
        raise argparse.ArgumentTypeError("Dauer muss zwischen 0 und 600 Sekunden liegen.")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="Nur A3 HID-Pfade und Metadaten auflisten")
    cap = commands.add_parser("capture", help="Input-Reports von Raw-HID Interface 0 lesen")
    cap.add_argument("--index", type=int, help="Optionaler Raw-HID-Index aus 'list'")
    cap.add_argument("--out", default="a3-motion.jsonl")
    cap.add_argument("--seconds", type=positive, default=30)
    cap.add_argument("--guided", action="store_true", help="8 markierte Bewegungsphasen")
    cap.add_argument("--phase-seconds", type=positive, default=5)
    scan = commands.add_parser("analyze", help="Reportmengen und variable Bytes zusammenfassen")
    scan.add_argument("file")
    args = parser.parse_args()
    try:
        if args.command == "analyze":
            analyze(args.file)
        else:
            hid = hid_module()
            entries = enumerate_a3(hid)
            show_devices(entries)
            if args.command == "capture":
                capture(args, hid, select_raw(entries, args.index))
        return 0
    except (RuntimeError, OSError) as exc:
        print(f"Fehler: {exc}", file=sys.stderr)
        print("Bei open/read-Fehler: macOS-Eingabeueberwachung fuer Terminal/Python "
              "pruefen; moeglichen konkurrierenden Zugriff der A3-App pruefen.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
