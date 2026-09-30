#!/usr/bin/env python3
"""
Turn on the Lenovo ThinkReality A3's display from macOS / Linux (via hidapi).

The A3 does not output an image until the host tells it which DisplayPort mode to use.
This script sends the same HostInfo command Lenovo's Windows software sends.
See docs/PROTOCOL.md for the packet format.

Setup:
    python3 -m venv ~/a3env
    ~/a3env/bin/pip install hidapi

Usage:
    ~/a3env/bin/python a3_display.py status
    ~/a3env/bin/python a3_display.py on            # HostInfo(0, 1), then wait until DP is ready
    ~/a3env/bin/python a3_display.py on --mode 2
    ~/a3env/bin/python a3_display.py display on|off
    ~/a3env/bin/python a3_display.py wake
"""
import argparse
import sys
import time

import hid

VID, PID = 0x17EF, 0xB813
ALT_VID, ALT_PID = 0x05C6, 0x901F  # Qualcomm VID/PID, also probed by Lenovo's DLL
CMD_IFACE = 10
PKT = 128

SET, GET = 0xC1, 0xC3


def open_cmd():
    devs = [d for d in hid.enumerate(VID, PID) + hid.enumerate(ALT_VID, ALT_PID)
            if d["usage_page"] == 0x008C]
    if not devs:
        sys.exit("Glasses not found (HID usage page 0x8C). Are they plugged in?")
    cand = [d for d in devs if d.get("interface_number") == CMD_IFACE]
    if not cand:
        # Fallback, same rule as Lenovo's DLL: the second-highest interface number is CMD
        devs.sort(key=lambda d: d.get("interface_number", -1))
        cand = [devs[-2]] if len(devs) >= 2 else devs
    d = cand[0]
    h = hid.device()
    h.open_path(d["path"])
    print(f"Command interface opened: iface={d.get('interface_number')}")
    return h


def drain(h):
    h.set_nonblocking(True)
    while h.read(PKT):
        pass
    h.set_nonblocking(False)


def xfer(h, cmd, typ, params=b"", timeout=2.0):
    pkt = bytearray(PKT)
    pkt[0:4] = bytes([0x4F, 0x42, cmd, typ])
    pkt[4:4 + len(params)] = params
    drain(h)
    n = h.write(b"\x00" + bytes(pkt))  # report ID 0 + 128 bytes
    if n < 0:
        raise IOError("write failed")
    end = time.time() + timeout
    while time.time() < end:
        r = h.read(PKT, timeout_ms=int((end - time.time()) * 1000) or 1)
        if not r:
            continue
        r = bytes(r)
        if r[0:4] == bytes([0x42, 0x4F, cmd, typ]):
            return r
        print(f"  (other message: {r[:8].hex(' ')})")
    return None


def dp_state(h):
    r = xfer(h, 0x03, GET)
    if r is None:
        return None, "no response"
    if r[4] != 0xA0:
        return None, f"command error (status={r[4]:#04x})"
    v = r[5]
    return v, {0xA0: "READY", 0xA1: "ERROR"}.get(v, f"not ready ({v:#04x})")


def cmd_status(h):
    _, txt = dp_state(h)
    print(f"DP state: {txt}")
    r = xfer(h, 0x07, GET)
    if r is not None and r[4] == 0xA0:
        print(f"Suspend state (raw): {r[5]:#04x}")


def cmd_on(h, mode):
    print(f"Sending HostInfo(host=0, mode={mode})...")
    r = xfer(h, 0x03, SET, bytes([0, mode]))
    if r is None:
        sys.exit("No response to HostInfo.")
    print(f"  response: {r[:8].hex(' ')}  -> {'OK' if r[4] == 0xA0 else 'ERROR'}")
    if r[4] != 0xA0:
        sys.exit(1)
    print("Waiting for DP to become ready (up to 30 s)...")
    for i in range(30):
        v, txt = dp_state(h)
        print(f"  [{i + 1:2d}] {txt}")
        if v == 0xA0:
            print("\nDP is ready. Check System Settings > Displays, or run:\n"
                  "  system_profiler SPDisplaysDataType")
            return
        if v == 0xA1:
            sys.exit("Glasses reported a DP error.")
        time.sleep(1)
    print("Not ready after 30 s.")


def cmd_display(h, on):
    r = xfer(h, 0x11, SET, bytes([1 if on else 0]))
    print("DisplayControl:", "no response" if r is None else ("OK" if r[4] == 0xA0 else f"ERROR {r[4]:#04x}"))


def cmd_wake(h):
    r = xfer(h, 0x07, SET, bytes([0]))
    print("SuspendControl(0):", "no response" if r is None else ("OK" if r[4] == 0xA0 else f"ERROR {r[4]:#04x}"))


def main():
    ap = argparse.ArgumentParser(description="ThinkReality A3 display control")
    sub = ap.add_subparsers(dest="c", required=True)
    sub.add_parser("status")
    p = sub.add_parser("on")
    p.add_argument("--mode", type=int, default=1, choices=[0, 1, 2])
    p = sub.add_parser("display")
    p.add_argument("state", choices=["on", "off"])
    sub.add_parser("wake")
    a = ap.parse_args()

    h = open_cmd()
    try:
        if a.c == "status":
            cmd_status(h)
        elif a.c == "on":
            cmd_on(h, a.mode)
        elif a.c == "display":
            cmd_display(h, a.state == "on")
        elif a.c == "wake":
            cmd_wake(h)
    finally:
        h.close()


if __name__ == "__main__":
    main()
