import os
import pathlib
import plistlib
import subprocess
import sys
from ios_simulator_launch import show_simulator, simctl_output

identifier = os.environ['IOS_SIMULATOR']
products = pathlib.Path(sys.argv[1])
app = products / 'App.app'
entitlements = pathlib.Path(os.environ['RUNNER_TEMP']) / 'ios-precise-entitlements.plist'
signed = subprocess.run(['codesign', '--display', '--entitlements', ':-', str(app)], capture_output=True, check=True, timeout=30)
entitlements.write_bytes(plistlib.dumps(plistlib.loads(signed.stdout)))
info = app / 'Info.plist'
values = plistlib.loads(info.read_bytes())
values['NSLocationDefaultAccuracyReduced'] = False
info.write_bytes(plistlib.dumps(values))
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), '--generate-entitlement-der', str(app)], check=True, timeout=60)
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)], check=True, timeout=60)
subprocess.run(['xcrun', 'simctl', 'shutdown', identifier], check=False, timeout=120)
simctl_output('erase', identifier, timeout=300)
simctl_output('boot', identifier, timeout=300)
simctl_output('bootstatus', identifier, '-b', timeout=600)
show_simulator(identifier)
simctl_output('location', identifier, 'set', '24.7136,46.6753')
subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('ios-ui-prepare.py')), str(products)], check=True, timeout=600)
