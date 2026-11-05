"""Validate automatic HDC session exchange over USB or Wi-Fi.

No code entry, screenshots, clipboard access or screen capture authorization required.
The phone must be unlocked and Harmony Bridge must have been opened once.
"""
import json
import argparse
import pathlib
import random
import re
import subprocess
import tempfile
import urllib.error
import urllib.request

HDC = '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc'


def run(*args):
    result = subprocess.run([HDC, *args], capture_output=True, text=True, timeout=15)
    output = result.stdout + result.stderr
    if result.returncode or '[Fail]' in output or 'Permission denied' in output:
        raise RuntimeError(output.strip())
    return output


parser = argparse.ArgumentParser()
parser.add_argument('--target', help='HDC target; omit to select the one USB device')
args = parser.parse_args()
devices = [line.strip() for line in run('list', 'targets').splitlines()
           if line.strip() and not line.startswith('[')]
if args.target:
    if args.target not in devices:
        raise RuntimeError('Requested HDC target is not connected.')
    device = args.target
else:
    usb_devices = [item for item in devices if ':' not in item]
    if len(usb_devices) != 1:
        raise RuntimeError('Connect exactly one USB phone or pass --target.')
    device = usb_devices[0]
port = None
with tempfile.TemporaryDirectory(prefix='HarmonyBridge-USB-smoke-') as temporary:
    credential = pathlib.Path(temporary) / 'session'
    run('-t', device, 'file', 'recv', '-b', 'com.harmonybridge.phone',
        '/data/storage/el2/base/haps/entry/files/bridge/usb-session', str(credential))
    credential.chmod(0o600)
    token = credential.read_text().strip()
    assert re.fullmatch('[a-fA-F0-9]{32}', token), 'Invalid session credential'
    try:
        for _ in range(5):
            candidate = random.randint(20000, 60000)
            try:
                run('-t', device, 'fport', f'tcp:{candidate}', 'tcp:28765')
                port = candidate
                break
            except RuntimeError:
                continue
        assert port is not None, 'Cannot forward USB service'

        def request(route, auth=token):
            req = urllib.request.Request(f'http://127.0.0.1:{port}/{route}', data=b'{}',
                                         headers={'Authorization': 'Bearer ' + auth})
            with urllib.request.urlopen(req, timeout=5) as response:
                data = json.load(response)
            assert data['ok'], data['error']
            return data

        status = request('video-status')['video']
        listing = request('list')
        try:
            request('list', 'wrong-credential')
            raise AssertionError('Unauthorized request accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 401
        print(json.dumps({'target': device, 'automaticHdcCredential': 'PASS', 'manualCodeEntry': False,
                          'fileService': 'PASS', 'sharedFileCount': len(listing['files']),
                          'unauthorizedHttpRequest': 'REJECTED', 'video': status}, indent=2))
    finally:
        if port is not None:
            run('-t', device, 'fport', 'rm', f'tcp:{port}', 'tcp:28765')
