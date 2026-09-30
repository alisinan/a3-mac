#!/usr/bin/env python3
"""
ThinkReality A3 HID explorer. Read-only: it never sends anything to the glasses.

Lists every HID collection the glasses expose, dumps each report descriptor
and listens passively for 2 s to see which interface streams data.

    ~/a3env/bin/python a3_probe.py
"""
import time

import hid

VID, PID = 0x17EF, 0xB813
LISTEN_SECONDS = 2.0


def main():
    devs = hid.enumerate(VID, PID)
    if not devs:
        print("ThinkReality A3 HID device not found. Are the glasses plugged in?")
        return

    print(f"{len(devs)} HID collections found.\n")
    for i, d in enumerate(devs):
        print(
            f"[{i}] iface={d.get('interface_number')}  "
            f"usage_page=0x{d['usage_page']:04X}  usage=0x{d['usage']:04X}  "
            f"product={d.get('product_string')!r}"
        )
        h = hid.device()
        try:
            h.open_path(d["path"])
        except Exception as e:
            print(f"     could not open: {e}\n")
            continue

        try:
            rd = h.get_report_descriptor()
            print(f"     report descriptor ({len(rd)} bytes): {bytes(rd).hex()}")
        except Exception as e:
            print(f"     could not read report descriptor: {e}")

        h.set_nonblocking(True)
        count, first, sizes = 0, None, set()
        t0 = time.time()
        while time.time() - t0 < LISTEN_SECONDS:
            r = h.read(1024)
            if r:
                count += 1
                sizes.add(len(r))
                if first is None:
                    first = bytes(r)
            else:
                time.sleep(0.001)

        line = f"     {count} reports in {LISTEN_SECONDS:.0f} s"
        if first:
            line += f" (sizes: {sorted(sizes)}), first: {first[:48].hex()}"
        print(line + "\n")
        h.close()


if __name__ == "__main__":
    main()
