#!/bin/zsh
# A real loopback-only server with fresh temporary storage and no external credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --package-path Server/follow-server -j 2 >/dev/null
python3 - <<'PY'
import json, os, socket, subprocess, tempfile, time, urllib.request, urllib.error
binary = os.path.abspath('Server/follow-server/.build/debug/follow-server')
with tempfile.TemporaryDirectory(prefix='chesstv-smoke-') as folder:
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    env = dict(os.environ)
    for key in ('APNS_TEAM_ID', 'APNS_KEY_ID', 'APNS_KEY_PATH', 'LICHESS_TOKEN'):
        env.pop(key, None)
    env.update(FOLLOW_HOST='127.0.0.1', FOLLOW_PORT=str(port), FOLLOW_DB=folder+'/smoke.sqlite', FOLLOW_REQUIRE_HTTPS='1', LICHESS_BASE_URL='http://127.0.0.1:1')
    with open(folder+'/server.log', 'w') as log:
        process = subprocess.Popen([binary], env=env, stdout=log, stderr=log)
        def request(path, method='GET', body=None, token=None):
            headers = {'X-Forwarded-Proto':'https', 'Content-Type':'application/json'}
            if token: headers['Authorization'] = 'Bearer '+token
            req = urllib.request.Request(f'http://127.0.0.1:{port}/v1/{path}', method=method, data=json.dumps(body).encode() if body is not None else None, headers=headers)
            with urllib.request.urlopen(req, timeout=2) as response:
                data = response.read()
                return response.status, json.loads(data) if data else None
        try:
            for attempt in range(50):
                try:
                    assert request('health')[1]['ok']
                    break
                except (OSError, urllib.error.URLError):
                    if process.poll() is not None: raise RuntimeError('server exited during startup')
                    time.sleep(.1)
            else: raise RuntimeError('health never became ready')
            registration = {'platform':'ios','environment':'sandbox','apnsToken':'a'*64,'appVersion':'smoke'}
            status, first = request('devices','POST',registration)
            assert status == 201
            assert request('follows',token=first['installToken'])[1] == []
            try: request('follows')
            except urllib.error.HTTPError as error: assert error.code == 401
            else: raise AssertionError('unauthenticated follows accepted')
            _, second = request('devices','POST',registration)
            assert second['deviceId'] != first['deviceId']
            assert request('follows',token=first['installToken'])[0] == 200
            assert request('follows',token=second['installToken'])[1] == []
            print('Loopback smoke passed: health, registration, bearer isolation, fresh re-registration.')
        finally:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
PY
