import pathlib
import plistlib
import subprocess
import sys
import tempfile

products = pathlib.Path(sys.argv[1]) / 'Build/Products/Debug-iphonesimulator'
apps = list(products.glob('*.app'))
if not apps:
    raise RuntimeError('No simulator application to sign')
for app in apps:
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    identifier = 'LTTesting.' + info['CFBundleIdentifier']
    entitlements = {'application-identifier': identifier, 'keychain-access-groups': [identifier], 'get-task-allow': True}
    with tempfile.NamedTemporaryFile(suffix='.plist') as output:
        output.write(plistlib.dumps(entitlements))
        output.flush()
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', output.name, '--timestamp=none', str(app)], check=True)
