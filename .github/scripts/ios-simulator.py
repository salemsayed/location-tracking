import json
import os
import subprocess

devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
phones = [device for runtime, entries in devices.items() if 'iOS' in runtime for device in entries if 'iPhone' in device['name']]
if not phones:
    raise RuntimeError('No available iPhone simulator')
preferred = next((device for device in phones if device['state'] == 'Booted'), None)
preferred = preferred or next((device for device in phones if device['name'] == 'iPhone 16'), phones[-1])
identifier = preferred['udid']
with open(os.environ['GITHUB_ENV'], 'a') as output:
    output.write(f'IOS_SIMULATOR={identifier}\n')
