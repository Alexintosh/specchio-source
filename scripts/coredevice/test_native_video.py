"""Verify the real macOS HEVC decoder with generated (non-phone) video."""
import base64
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from session import encode_packet


def main():
    viewer = sys.argv[1] if len(sys.argv) > 1 else '/tmp/specchio-coredevice-viewer'
    with tempfile.TemporaryDirectory(prefix='specchio-coredevice-video-') as directory:
        root = Path(directory)
        source = root / 'fixture.hevc'
        wire = root / 'fixture.wire'
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
            '-i', 'testsrc2=size=320x240:rate=10', '-frames:v', '10', '-c:v', 'libx265',
            '-x265-params', 'aud=1:bframes=0:log-level=error', '-f', 'hevc', str(source)], check=True)
        nals = [n for n in re.split(b'\x00\x00\x00?\x01', source.read_bytes()) if n]
        sets = [next(n for n in nals if (n[0] >> 1) & 63 == kind) for kind in (32, 33, 34)]
        output = bytearray(encode_packet(1, json.dumps(dict(parameter_sets=[base64.b64encode(n).decode() for n in sets])).encode()))
        group = []
        for nal in nals:
            if (nal[0] >> 1) & 63 == 35 and group:
                output.extend(encode_packet(2, b''.join(b'\x00\x00\x00\x01' + n for n in group)))
                group = []
            group.append(nal)
        if group:
            output.extend(encode_packet(2, b''.join(b'\x00\x00\x00\x01' + n for n in group)))
        wire.write_bytes(output)
        subprocess.run([viewer, '--verify-wire', str(wire)], check=True)
        # A truncated packet must fail, not silently report successful playback.
        wire.write_bytes(output[:-1])
        result = subprocess.run([viewer, '--verify-wire', str(wire)], capture_output=True)
        if result.returncode == 0:
            raise AssertionError('Truncated packet was accepted')
        print('Native HEVC decoding and truncated-packet rejection passed; no phone involved.')


if __name__ == '__main__':
    main()
