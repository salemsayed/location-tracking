import json
import math
import re
import os
import pathlib
import signal
import subprocess
import time
import uuid
from ios_simulator_launch import launch_and_wait, simctl_output

identifier = os.environ['IOS_SIMULATOR']
app = pathlib.Path(os.environ['IOS_SCENARIO_APP'])
root = pathlib.Path(os.environ['RUNNER_TEMP'])
report = root / 'ios-stage3'
report.mkdir(exist_ok=True)
bundle = 'com.brickssoft.locationtracking.example'
checks = []
route = None
latitude = 24.7136
metres_per_degree = 111320.0


def east(longitude, metres):
    return longitude + metres / (metres_per_degree * math.cos(math.radians(latitude)))


def sim(*args, timeout=600):
    return simctl_output(*args, timeout=timeout)


def check(value, description):
    if not value:
        raise AssertionError(description)
    checks.append(description)
    print(description, flush=True)


def wait_for(condition, description, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = condition()
        if result:
            return result
        time.sleep(0.5)
    raise TimeoutError(description)


sim('bootstatus', identifier, '-b')
sim('install', identifier, str(app))
container = pathlib.Path(sim('get_app_container', identifier, bundle, 'data'))
directory = container / 'Library/Application Support/Stage2'
directory.mkdir(parents=True, exist_ok=True)
runtimes = json.loads(sim('list', 'devices', '-j'))['devices']
runtime = next(name for name, devices in runtimes.items() if any(device['udid'] == identifier for device in devices))
version = '.'.join(re.findall(r'\d+', runtime.split('iOS-')[-1]))
major = int(version.split('.')[0])


def launch():
    for name in ['ready.json', 'command.json', 'response.json']:
        (directory / name).unlink(missing_ok=True)
    def ready():
        path = directory / 'ready.json'
        return json.loads(path.read_text()) if path.exists() else None
    return launch_and_wait(identifier, bundle, ['--ios-stage2-scenario'], ready, report / 'launch.log', timeout=300)['pid']


def call(method, options=None, allow_failure=False):
    command = {'id': str(uuid.uuid4()), 'method': method, 'options': options or {}}
    temporary = directory / 'command.tmp'
    temporary.write_text(json.dumps(command))
    temporary.replace(directory / 'command.json')
    def response():
        try:
            value = json.loads((directory / 'response.json').read_text())
            return value if value.get('id') == command['id'] else None
        except (FileNotFoundError, json.JSONDecodeError):
            return None
    result = wait_for(response, 'native response to ' + method, timeout=60)
    if not result['success'] and not allow_failure:
        raise RuntimeError(method + ': ' + json.dumps(result))
    return result if allow_failure else result.get('value', result)


def geofence_records():
    return [record for record in call('getLocations')['locations'] if record['event'] == 'geofence']


def hits(since=None):
    return [record['geofence']['identifier'] + ':' + record['geofence']['action'] for record in geofence_records() if since is None or record['recorded_at'] >= since]


def wait_hits(expected, description, timeout=240, since=None):
    def done():
        current = hits(since)
        return current if all(item in current for item in expected) else None
    try:
        return wait_for(done, description, timeout=timeout)
    finally:
        (report / (description.replace(' ', '-') + '.json')).write_text(json.dumps(geofence_records(), indent=2))


def stop_route():
    global route
    if route and route.poll() is None:
        route.terminate()
        try:
            route.wait(timeout=5)
        except subprocess.TimeoutExpired:
            route.kill()
            route.wait(timeout=5)
    route = None


try:
    pid = launch()
    if major < 17:
        for method, options in [('startGeofences', {}), ('addGeofence', {'geofence': {'identifier': 'a', 'latitude': latitude, 'longitude': 46.6753, 'radius': 100}}), ('getGeofences', {}), ('geofenceExists', {'identifier': 'a'})]:
            result = call(method, options, allow_failure=True)
            check(not result['success'] and result['code'] == 'UNAVAILABLE', method + ' rejects UNAVAILABLE on iOS ' + version)
    else:
        sim('privacy', identifier, 'reset', 'location', bundle)
        sim('privacy', identifier, 'grant', 'location-always', bundle)
        start = east(46.6753, -1500)
        sim('location', identifier, 'set', '%f,%f' % (latitude, start))
        call('stop')
        call('ready', {'config': {'http': {'autoSync': False}, 'heartbeat': {'enabled': False}, 'notification': {'resume': {'enabled': False}}, 'geofence': {'initialTriggerEntry': True}, 'app': {'stopOnTerminate': False}}})
        call('removeGeofences')
        call('destroyLocations')
        many = [{'identifier': 'cap%02d' % index, 'latitude': latitude + 0.5, 'longitude': 46.0 + index * 0.01, 'radius': 100} for index in range(21)]
        result = call('addGeofences', {'geofences': many}, allow_failure=True)
        check(not result['success'] and result['code'] == 'TOO_MANY_GEOFENCES', 'twenty-one geofences reject TOO_MANY_GEOFENCES')
        call('addGeofences', {'geofences': many[:20]})
        check(len(call('getGeofences')['geofences']) == 20, 'twenty geofences are accepted')
        call('removeGeofences')
        circle = east(46.6753, -600)
        square = east(46.6753, 300)
        half = 120 / (metres_per_degree * math.cos(math.radians(latitude)))
        rise = 120 / metres_per_degree
        finish = east(46.6753, 1500)
        call('addGeofences', {'geofences': [
            {'identifier': 'circle', 'latitude': latitude, 'longitude': circle, 'radius': 150},
            {'identifier': 'polygon', 'vertices': [[latitude - rise, square - half], [latitude - rise, square + half], [latitude + rise, square + half], [latitude + rise, square - half]]},
            {'identifier': 'dwell', 'latitude': latitude, 'longitude': finish, 'radius': 150, 'notifyOnEntry': True, 'notifyOnExit': True, 'notifyOnDwell': True, 'loiteringDelay': 10000},
        ]})
        state = call('startGeofences')
        check(state['enabled'] and state['trackingMode'] == 'geofences', 'geofence mode starts with three stored geofences')
        time.sleep(10)
        gps = (report / 'route.log').open('w')
        route = subprocess.Popen(['xcrun', 'simctl', 'location', identifier, 'start', '--speed=25', '--interval=1', '%f,%f' % (latitude, start), '%f,%f' % (latitude, finish)], stdout=gps, stderr=subprocess.STDOUT)
        seen = wait_hits(['circle:ENTER', 'circle:EXIT'], 'circle entered and left on the simulated route')
        check(seen.index('circle:ENTER') < seen.index('circle:EXIT'), 'circle ENTER then EXIT come from the CLMonitor condition')
        seen = wait_hits(['polygon:ENTER', 'polygon:EXIT'], 'polygon entered and left by hit-testing fixes')
        check(seen.index('polygon:ENTER') < seen.index('polygon:EXIT'), 'polygon ENTER then EXIT come from fixes inside its enclosing circle')
        seen = wait_hits(['dwell:ENTER'], 'dwell geofence entered at the end of the route')
        check('dwell:DWELL' not in seen, 'DWELL waits for the loitering delay')
        stop_route(); gps.close()
        sim('location', identifier, 'set', '%f,%f' % (latitude, finish))
        seen = wait_hits(['dwell:DWELL'], 'dwell synthesized after the loitering delay', timeout=90)
        check(seen.count('dwell:DWELL') == 1 and seen.index('dwell:ENTER') < seen.index('dwell:DWELL'), 'DWELL is synthesized once after the loitering delay while inside')
        before = [record['recorded_at'] for record in geofence_records()]
        os.kill(pid, signal.SIGKILL)
        time.sleep(2)
        pid = launch()
        relaunch = max(before)
        stored = sorted(item['identifier'] for item in call('getGeofences')['geofences'])
        check(stored == ['circle', 'dwell', 'polygon'], 'stored geofences survive a SIGKILL relaunch')
        restored = call('getState')
        check(restored['enabled'] and restored['trackingMode'] == 'geofences', 'geofence mode restores after the relaunch')
        time.sleep(10)
        sim('location', identifier, 'set', '%f,%f' % (latitude, east(46.6753, 4000)))
        seen = wait_hits(['dwell:EXIT'], 'relaunched monitor reports leaving the dwell geofence', timeout=180, since=relaunch)
        check('dwell:EXIT' in seen, 'the monitor re-created under the same name reports EXIT after the relaunch')
        call('stop')
        call('removeGeofences')
    (report / 'report.json').write_text(json.dumps({'success': True, 'checks': checks}, indent=2))
finally:
    stop_route()
    try:
        sim('io', identifier, 'screenshot', str(report / 'final.png'), timeout=15)
    except subprocess.SubprocessError:
        pass
    (report / 'checks.json').write_text(json.dumps(checks, indent=2))
