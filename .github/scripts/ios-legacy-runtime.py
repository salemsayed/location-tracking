import json
import os
import pathlib
import re
import subprocess

root = pathlib.Path(os.environ['RUNNER_TEMP'])
report = root / 'ios-legacy-runtime.txt'

def run(command, timeout=600):
    with report.open('a') as output:
        output.write('\n' + ' '.join(command) + '\n')
        output.flush()
        try:
            return subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            output.write('Command timed out\n')
            return 124

def available():
    data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '-j']))
    return [r for r in data['runtimes'] if r.get('isAvailable') and re.match(r'^(15|16)\.', r['version'])]

run(['xcodebuild', '-version'])
run(['xcrun', 'simctl', 'list', 'runtimes'])
for version in ['16.4', '15.5']:
    if available():
        break
    destination = root / ('runtime-' + version)
    destination.mkdir()
    if run(['xcodebuild', '-downloadPlatform', 'iOS', '-buildVersion', version, '-exportPath', str(destination)]) == 0:
        for image in destination.rglob('*.dmg'):
            run(['xcodebuild', '-importPlatform', str(image)])
for runtime in available():
    identifier = subprocess.check_output(['xcrun', 'simctl', 'create', 'LT Legacy', 'com.apple.CoreSimulator.SimDeviceType.iPhone-14', runtime['identifier']], text=True).strip()
    if run(['xcrun', 'simctl', 'boot', identifier], timeout=120) == 0 and run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], timeout=300) == 0:
        with open(os.environ['GITHUB_ENV'], 'a') as output:
            output.write('IOS_SIMULATOR=' + identifier + '\nLEGACY_AVAILABLE=true\n')
        break
else:
    with report.open('a') as output:
        output.write('\nNo bootable iOS 15/16 runtime was obtainable on this runner. See command errors above.\n')
print(report.read_text())
with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
    output.write('```\n' + report.read_text() + '\n```\n')
