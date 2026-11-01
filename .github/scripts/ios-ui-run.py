import os
import pathlib
import subprocess
import sys
import time

directory = pathlib.Path(os.environ['RUNNER_TEMP'], 'ui-samples')
directory.mkdir(exist_ok=True)
process = subprocess.Popen(sys.argv[1:])
seen = {}
sampled = set()
deadline = time.monotonic() + 1200
try:
    while process.poll() is None:
        if time.monotonic() > deadline:
            raise TimeoutError('UI test command exceeded 20 minutes')
        try:
            listing = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True, timeout=10)
        except subprocess.SubprocessError:
            print('UI process inspection did not finish; continuing the test command', flush=True)
            listing = ''
        for line in listing.splitlines():
            fields = line.strip().split(maxsplit=1)
            if len(fields) != 2 or not fields[1].endswith(('/App.app/App', '/PermissionUITests-Runner.app/PermissionUITests-Runner')):
                continue
            pid = fields[0]
            first = seen.setdefault(pid, time.monotonic())
            if pid not in sampled and time.monotonic() - first > 20:
                sampled.add(pid)
                try:
                    subprocess.run(['sample', pid, '1', '10', '-file', str(directory / (pid + '.txt'))], check=False, timeout=60)
                except subprocess.SubprocessError:
                    print('UI stack sampling did not finish for ' + pid, flush=True)
        time.sleep(2)
    raise SystemExit(process.returncode)
finally:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
