import io
import json
import math
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace as NS
import unittest
from unittest.mock import patch

BRIDGE = Path(__file__).resolve().parents[1] / 'app' / 'TrackingBridge'
sys.path.insert(0, str(BRIDGE))
import a3_pose_stream as stream
import a3_usb_protocol as protocol


def packet(kind, payload):
    header = struct.pack('<II', (kind << 8) | (2 if kind == 0x54 else 1), len(payload))
    return (header + payload).ljust(648 if kind == 0x54 else 272, b'\0')


def imu(timestamp=1000000000):
    body = bytearray(208)
    struct.pack_into('<4iq6f', body, 0, 104, 14, 16, 7, timestamp, .1, .2, .3, .01, .02, .03)
    struct.pack_into('<4iq6f', body, 104, 104, 6, 35, 7, timestamp, 9.81, 0, 0, 0, 0, 0)
    return packet(0x53, body)


def pose(timestamp=1000000000):
    body = bytearray(192)
    angle = (timestamp / 1e9) * .1
    struct.pack_into('<4f', body, 0, math.sin(angle/2), 0, 0, math.cos(angle/2))
    struct.pack_into('<Q', body, 32, timestamp)
    return packet(0x54, body)


def reply(command, body):
    payload = bytes((~command & 255, len(body), 0)) + body + bytes(255-len(body))
    return packet(0x46, payload)


class USBTimeout(Exception):
    pass


class FakeUSB:
    def __init__(self, output, existing=False, reject_start=False, missing_ack=False):
        self.output = output
        self.active = existing
        self.clock = 0
        self.queue = []
        self.commands = []
        self.samples = 0
        self.released = False
        self.disposed = False
        self.reject_start = reject_start
        self.missing_ack = missing_ack
        self.usb = NS(core=NS(USBTimeoutError=USBTimeout),
                      util=NS(claim_interface=lambda dev, intf: None,
                              release_interface=self.release, dispose_resources=self.dispose),
                      control=NS(get_interface=lambda dev, intf: 0))

    def release(self, dev, intf): self.released = True
    def dispose(self, dev): self.disposed = True

    def get_active_configuration(self):
        iface = type('Iface', (list,), {})()
        iface.bInterfaceClass = 255
        iface.extend([NS(bEndpointAddress=0x83, bmAttributes=2), NS(bEndpointAddress=3, bmAttributes=2)])
        return type('Cfg', (), {'__getitem__': lambda self, key: iface})()

    def write(self, endpoint, data, timeout):
        assert endpoint == 3 and len(data) == 272
        command = data[8]
        self.commands.append(command)
        if command == 0x19:
            body = b'\x0brotational\0'
        else:
            result = 4 if command == 0x12 else -3 if command == 0x14 and self.reject_start else 0
            body = struct.pack('<i', result)
            if command == 0x14 and result == 0: self.active = True
            if command == 0x15: self.active = False
        if not (command == 0x14 and self.missing_ack): self.queue.append(reply(command, body))
        return len(data)

    def read(self, endpoint, size, timeout):
        self.clock += .01
        if self.queue: return self.queue.pop(0)
        if self.active:
            self.samples += 1
            if self.samples > 90: self.output.stopped = True
            timestamp = int(self.clock * 1e9)
            return imu(timestamp) if self.samples % 2 else pose(timestamp)
        raise USBTimeout()


class Tests(unittest.TestCase):
    def run_live(self, **options):
        sink = io.StringIO()
        output = stream.Output(sink, 60)
        fake = FakeUSB(output, **options)
        with patch.object(protocol, 'load_usb', return_value=(fake.usb, fake)), \
             patch.object(stream.time, 'monotonic', side_effect=lambda: fake.clock), \
             patch.object(stream.time, 'monotonic_ns', side_effect=lambda: int(fake.clock*1e9)), \
             patch('sys.stderr', io.StringIO()):
            code = stream.live(NS(parent_pid=None), output)
        self.assertTrue(fake.released and fake.disposed)
        return code, fake, [json.loads(line) for line in sink.getvalue().splitlines()]

    def test_live_start_stop_and_json_only(self):
        code, fake, messages = self.run_live()
        self.assertEqual(code, 0)
        self.assertEqual(fake.commands, [0x12, 0x19, 0x14, 0x15])
        self.assertFalse(fake.active)
        poses = [m for m in messages if m['type']=='pose']
        self.assertGreater(len(poses), 5)
        self.assertEqual(poses[0]['accel_m_s2'], protocol.decode_transfer(imu())['accel_m_s2'])
        self.assertEqual(messages[-1]['type'], 'end')

    def test_existing_session_not_stopped(self):
        code, fake, messages = self.run_live(existing=True)
        self.assertEqual(code, 0)
        self.assertEqual(fake.commands, [0x12])
        self.assertTrue(fake.active)

    def test_start_rejection_does_not_stop_other_session(self):
        code, fake, messages = self.run_live(reject_start=True)
        self.assertEqual(code, 1)
        self.assertNotIn(0x15, fake.commands)
        self.assertTrue(any(m['type']=='error' for m in messages))

    def test_cancel_during_missing_start_ack_cleans_up(self):
        code, fake, messages = self.run_live(missing_ack=True)
        self.assertIn(0x15, fake.commands)
        self.assertFalse(fake.active)

    def test_throttle_and_bad_imu_do_not_drop_valid_pose(self):
        sink = io.StringIO()
        output = stream.Output(sink, 60)
        decoded = protocol.decode_transfer(pose())
        for index in range(1000):
            output.pose(decoded, {'pose': index}, {'gyro_rad_s': [None, 0, 0]}, now=index/1000)
        messages = [json.loads(line) for line in sink.getvalue().splitlines()]
        self.assertLessEqual(len(messages), 60)
        self.assertGreater(len(messages), 50)
        self.assertIsNone(messages[0]['gyro_rad_s'])

    def test_replay_never_opens_usb(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/'fixture.jsonl'
            records = [dict(type='chunk', t_host_ns=1000000000+i*10000000,
                            hex=(imu() if i%2==0 else pose(1000000000+i*10000000)).hex()) for i in range(20)]
            path.write_text('\n'.join(json.dumps(r) for r in records)+'\n')
            sink = io.StringIO()
            output = stream.Output(sink, 60)
            with patch.object(protocol, 'load_usb', side_effect=AssertionError('USB opened')):
                self.assertEqual(stream.replay(NS(replay=str(path), speed=100), output), 0)
            messages = [json.loads(line) for line in sink.getvalue().splitlines()]
            self.assertTrue(any(m['type']=='pose' for m in messages))
            self.assertEqual(messages[-1]['type'], 'end')

    def test_240_hz_schedule_does_not_round_down_to_usb_cadence(self):
        sink = io.StringIO()
        output = stream.Output(sink, 240)
        decoded = protocol.decode_transfer(pose())
        for index in range(987):
            output.pose(decoded, {'pose': index}, now=index/987)
        self.assertEqual(len(sink.getvalue().splitlines()), 240)

    def test_bias_and_imu_timestamp_reach_swift(self):
        sink = io.StringIO()
        output = stream.Output(sink, 240)
        decoded_imu = protocol.decode_transfer(imu())
        output.pose(protocol.decode_transfer(pose()), {}, decoded_imu, now=0)
        message = json.loads(sink.getvalue())
        self.assertEqual(message['gyro_bias_rad_s'], decoded_imu['gyro_bias_rad_s'])
        self.assertEqual(message['accel_bias_m_s2'], decoded_imu['accel_bias_m_s2'])
        self.assertEqual(message['imu_timestamp_ns'], 1000000000)

    def test_invalid_pose_does_not_consume_output_slot(self):
        sink = io.StringIO()
        output = stream.Output(sink, 240)
        output.pose(dict(quaternion_xyzw=[0, 0, 0, 0]), {}, now=0)
        output.pose(protocol.decode_transfer(pose()), {}, now=0.001)
        self.assertEqual(len(sink.getvalue().splitlines()), 1)

    def test_delayed_sender_does_not_emit_catchup_burst(self):
        sink = io.StringIO()
        output = stream.Output(sink, 240)
        decoded = protocol.decode_transfer(pose())
        for now in (0, 0.1, 0.100001, 0.100002):
            output.pose(decoded, {}, now=now)
        self.assertEqual(len(sink.getvalue().splitlines()), 2)

    def test_sigterm_replay_exits_cleanly(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)/'fixture.jsonl'
            path.write_text('\n'.join(json.dumps(dict(type='chunk', t_host_ns=1000000000+i*1000000000,
                                                     hex=pose(1000000000+i*1000000000).hex())) for i in range(5))+'\n')
            child = subprocess.Popen([sys.executable, str(BRIDGE/'a3_pose_stream.py'), '--replay', str(path)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            # Wait for first pose rather than racing signal handler installation.
            self.assertEqual(json.loads(child.stdout.readline())['type'], 'status')
            self.assertEqual(json.loads(child.stdout.readline())['type'], 'pose')
            child.send_signal(signal.SIGTERM)
            stdout, stderr = child.communicate(timeout=5)
            self.assertEqual(child.returncode, 0, stderr)
            self.assertEqual(json.loads(stdout.strip().splitlines()[-1])['type'], 'end')


if __name__ == '__main__':
    unittest.main()
