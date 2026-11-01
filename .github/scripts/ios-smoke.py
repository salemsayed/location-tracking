import json
import os
import pathlib
import subprocess
import threading
import time

identifier = os.environ['IOS_SIMULATOR']
app = pathlib.Path(os.environ['RUNNER_TEMP']) / 'ios-simulator/Build/Products/Debug-iphonesimulator/App.app'
bundle = 'com.brickssoft.locationtracking.example'

def sim(*args):
    return subprocess.check_output(['xcrun', 'simctl', *args], text=True).strip()

subprocess.run(['xcrun', 'simctl', 'boot', identifier], check=False)
subprocess.run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], check=True, timeout=240)
sim('install', identifier, str(app))
sim('privacy', identifier, 'grant', 'location-always', bundle)
sim('location', identifier, 'set', '24.7136,46.6753')
sim('launch', '--terminate-running-process', identifier, bundle, '--ios-stage1-smoke')
container = pathlib.Path(sim('get_app_container', identifier, bundle, 'data'))
result = container / 'Library/Application Support/ios-stage1-smoke.json'
finished = threading.Event()

def move():
    for index in range(60):
        if finished.wait(1):
            return
        sim('location', identifier, 'set', f'{24.7136 + index * 0.001},46.6753')

thread = threading.Thread(target=move, daemon=True)
thread.start()
try:
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        if result.exists():
            data = json.loads(result.read_text())
            pathlib.Path(os.environ['RUNNER_TEMP'], 'ios-smoke.json').write_text(json.dumps(data, indent=2))
            print(json.dumps(data, indent=2))
            if not data['success']:
                raise RuntimeError('WebView bridge smoke failed')
            break
        time.sleep(1)
    else:
        raise RuntimeError('Timed out waiting for WebView smoke report')
finally:
    finished.set()
    sim('location', identifier, 'clear')
