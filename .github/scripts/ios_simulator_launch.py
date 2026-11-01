import subprocess
import time


def launch_and_wait(identifier, bundle, arguments, ready, log, timeout=180):
    with log.open('w') as output:
        process = subprocess.Popen(['xcrun', 'simctl', 'launch', '--terminate-running-process', identifier, bundle, *arguments], stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                result = ready()
                if result is not None:
                    return result
                if process.poll() not in [None, 0]:
                    raise RuntimeError('Simulator launch failed: ' + log.read_text())
                time.sleep(0.5)
            raise TimeoutError('Simulator app did not become ready: ' + log.read_text())
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
