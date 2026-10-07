#!/usr/bin/env python3
"""A3 pose bridge: USB at full rate, JSON Lines to Swift at up to 240 Hz.

Standard output is exclusively the versioned JSON protocol. Human-readable
probe diagnostics go to standard error. Replay needs only Python 3.9+, live
USB also needs PyUSB/libusb. No HTTP server, sockets or network access.
"""
import argparse
from collections import Counter
import contextlib
import io
import json
import math
import os
from pathlib import Path
import signal
import sys
import time

import a3_usb_protocol as protocol


class StopRequested(Exception):
    pass


class Output:
    def __init__(self, stream, fps):
        self.stream = stream
        self.interval = 1 / fps
        self.stopped = False
        self.disconnected = False
        self.last_sent = None
        self.next_due = None

    def emit(self, kind, **fields):
        if self.disconnected:
            return
        try:
            self.stream.write(json.dumps(dict(schema=1, type=kind, **fields), allow_nan=False) + '\n')
            self.stream.flush()
        except (BrokenPipeError, OSError):
            self.disconnected = self.stopped = True

    def pose(self, decoded, counts, latest_imu=None, now=None, rate=None):
        now = time.monotonic() if now is None else now
        if self.next_due is not None and now < self.next_due:
            return
        quaternion = decoded.get('quaternion_xyzw')
        if not quaternion or any(value is None or not math.isfinite(value) for value in quaternion):
            return
        norm = math.sqrt(sum(value*value for value in quaternion))
        if not 0.5 < norm < 1.5:
            return
        self.last_sent = now
        if self.next_due is None:
            self.next_due = now + self.interval
        else:
            # Keep a stable schedule instead of rounding every interval up to
            # the next USB packet. Skip missed slots rather than sending bursts.
            self.next_due += (math.floor((now - self.next_due) / self.interval) + 1) * self.interval
        imu = latest_imu or {}
        def valid_vector(values):
            return values if values and len(values) == 3 and all(
                value is not None and math.isfinite(value) for value in values) else None
        self.emit('pose', quaternion=[value/norm for value in quaternion],
                  timestamp_ns=decoded['device_timestamp_ns'],
                  gyro_rad_s=valid_vector(imu.get('gyro_rad_s')), accel_m_s2=valid_vector(imu.get('accel_m_s2')),
                  gyro_bias_rad_s=valid_vector(imu.get('gyro_bias_rad_s')),
                  accel_bias_m_s2=valid_vector(imu.get('accel_bias_m_s2')),
                  imu_timestamp_ns=imu.get('gyro_timestamp_ns'),
                  imu_packets=counts.get('imu', 0), pose_packets=counts.get('pose', 0),
                  received_rate_hz=rate)


class PoseSession(protocol.Session):
    def __init__(self, usb, device, output):
        super().__init__(usb, device, io.StringIO())
        self.sender = output
        self.latest_imu = None
        self.cleaning_up = False
        self.first_pose_time = None
        self.first_pose_count = None

    def log(self, kind, **fields):
        # Session.poll already parses and counts each transfer. Never send the
        # approximately 1000-Hz raw USB stream through the UI's pipe.
        if kind != 'chunk' or self.cleaning_up:
            return
        decoded = fields['decoded']
        if decoded['kind'] == 'imu':
            self.latest_imu = decoded
        elif decoded['kind'] == 'pose':
            timestamp = decoded['device_timestamp_ns']
            if self.first_pose_time is None:
                self.first_pose_time, self.first_pose_count = timestamp, self.counts['pose']
            duration = (timestamp - self.first_pose_time) / 1e9
            rate = (self.counts['pose'] - self.first_pose_count) / duration if duration > 0 else None
            self.sender.pose(decoded, self.counts, self.latest_imu, rate=rate)

    def poll(self):
        if self.sender.stopped and not self.cleaning_up:
            raise StopRequested()
        return super().poll()

    def command(self, code, payload=b'', name=''):
        if self.sender.stopped and not self.cleaning_up:
            raise StopRequested()
        return super().command(code, payload, name)


def validate_interface(usb, device):
    cfg = device.get_active_configuration()
    interface = cfg[(protocol.INTERFACE, 0)]
    if interface.bInterfaceClass != 255:
        raise RuntimeError('Interface 2 is not vendor-specific')
    for address in (protocol.BULK_IN, protocol.BULK_OUT):
        if sum(ep.bEndpointAddress == address and ep.bmAttributes & 3 == 2 for ep in interface) != 1:
            raise RuntimeError(f'Bulk endpoint 0x{address:02x} is missing')


def live(args, output):
    usb = device = session = None
    claimed = False
    start_attempted = False
    code = 0
    try:
        output.emit('status', message='Looking for A3 and opening the sensor interface…')
        usb, device = protocol.load_usb()
        validate_interface(usb, device)
        usb.util.claim_interface(device, protocol.INTERFACE)
        claimed = True
        if usb.control.get_interface(device, protocol.INTERFACE) != 0:
            raise RuntimeError('Active alternate setting is not 0; refusing to switch')
        session = PoseSession(usb, device, output)
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            session.poll()
        # The proven probe's helper prints command results. Keep stdout JSON-only.
        with contextlib.redirect_stdout(sys.stderr):
            session.integer(0x12, 'GetVRMode')
            existing = bool(session.counts['imu'] + session.counts['pose'])
            if existing:
                output.emit('status', message='Using an existing sensor stream…')
            else:
                mode = session.get_param('tracker-tracking-mode')
                output.emit('status', message=f'Starting tracking (mode: {mode})…')
                # No mode switch. A3's current setting is preserved.
                if output.stopped:
                    raise StopRequested()
                start_attempted = True
                result = session.integer(0x14, 'StartVRMode')
                if result != 0:
                    start_attempted = False
                    raise RuntimeError(f'StartVRMode failed: {result}')
        output.emit('status', message='Tracking active; waiting for orientation…')
        last_parent_check = time.monotonic()
        while not output.stopped:
            session.poll()
            now = time.monotonic()
            if now - last_parent_check >= 1:
                last_parent_check = now
                if args.parent_pid and os.getppid() != args.parent_pid:
                    output.stopped = True
    except StopRequested:
        pass
    except Exception as exc:
        code = 1
        output.emit('error', message=str(exc))
    finally:
        if session:
            session.cleaning_up = True
            if start_attempted:
                try:
                    with contextlib.redirect_stdout(sys.stderr):
                        result = session.integer(0x15, 'StopVRMode')
                    if result != 0:
                        raise RuntimeError(f'StopVRMode failed: {result}')
                except Exception as exc:
                    code = 1
                    output.emit('error', message='Tracking cleanup: ' + str(exc))
        if claimed:
            try:
                usb.util.release_interface(device, protocol.INTERFACE)
            except Exception as exc:
                code = 1
                output.emit('error', message='USB release: ' + str(exc))
        if device is not None:
            try:
                usb.util.dispose_resources(device)
            except Exception as exc:
                code = 1
                output.emit('error', message='USB cleanup: ' + str(exc))
        output.emit('end', message='Sensor stream stopped', exit_code=code)
    return code


def replay(args, output):
    counts = Counter()
    latest_imu = None
    first_host_time = None
    wall_start = time.monotonic()
    first_pose_time = None
    first_pose_count = None
    output.emit('status', message='Replaying a recording (no USB access)…')
    try:
        with Path(args.replay).open(encoding='utf-8') as source:
            for line in source:
                if output.stopped:
                    break
                record = json.loads(line)
                if record.get('type') != 'chunk':
                    continue
                decoded = protocol.decode_transfer(bytes.fromhex(record['hex']))
                kind = decoded['kind']
                counts[kind] += 1
                if kind == 'imu':
                    latest_imu = decoded
                if kind != 'pose':
                    continue
                host_time = record.get('t_host_ns')
                if host_time is None:
                    raise RuntimeError('Recording has no host timestamp')
                if first_host_time is None:
                    first_host_time = host_time
                    wall_start = time.monotonic()
                target = wall_start + (host_time - first_host_time) / 1e9 / args.speed
                while not output.stopped and time.monotonic() < target:
                    time.sleep(min(0.02, max(0, target - time.monotonic())))
                if output.stopped:
                    break
                timestamp = decoded['device_timestamp_ns']
                if first_pose_time is None:
                    first_pose_time, first_pose_count = timestamp, counts['pose']
                duration = (timestamp - first_pose_time) / 1e9
                rate = (counts['pose'] - first_pose_count) / duration if duration > 0 else None
                output.pose(decoded, counts, latest_imu, rate=rate)
        output.emit('end', message='Replay finished', exit_code=0)
        return 0
    except Exception as exc:
        output.emit('error', message=str(exc))
        output.emit('end', message='Replay failed', exit_code=1)
        return 1


def bounded_number(text, minimum, maximum):
    value = float(text)
    if not math.isfinite(value) or not minimum <= value <= maximum:
        raise argparse.ArgumentTypeError(f'Expected {minimum} to {maximum}')
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fps', type=lambda text: bounded_number(text, 1, 240), default=240)
    parser.add_argument('--replay', help='Developer-only JSONL replay without opening USB')
    parser.add_argument('--speed', type=lambda text: bounded_number(text, 0.1, 100), default=1)
    parser.add_argument('--parent-pid', type=int)
    args = parser.parse_args()
    output = Output(sys.stdout, args.fps)
    def request_stop(signum, frame):
        output.stopped = True
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    return replay(args, output) if args.replay else live(args, output)


if __name__ == '__main__':
    sys.exit(main())
