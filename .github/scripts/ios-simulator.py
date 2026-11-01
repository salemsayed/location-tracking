import json
import os
import subprocess

devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
phones = [device for runtime, entries in devices.items() if 'iOS' in runtime for device in entries if 'iPhone' in device['name']]
if not phones:
    raise RuntimeError('No available iPhone simulator')
identifier = phones[-1]['udid']
with open(os.environ['GITHUB_ENV'], 'a') as output:
    output.write(f'IOS_SIMULATOR={identifier}\n')
subprocess.run(['xcrun', 'simctl', 'boot', identifier], check=False)
subprocess.run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], check=True)
