import json
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BACKEND = ROOT / 'root/usr/libexec/rpcd/5gmodem_maps'

# A small jshn stand-in for host tests; native jshn is checked on the router too.
JSHN = r'''
json_init() { export J_OUTPUT='{}'; }
json_load() { export J_INPUT="$1"; python3 -c 'import json,os; json.loads(os.environ["J_INPUT"])' >/dev/null 2>&1; }
json_get_var() {
 local v
 v=$(python3 -c 'import json,os,sys; v=json.loads(os.environ["J_INPUT"]).get(sys.argv[1], ""); print(int(v) if isinstance(v,bool) else v)' "$2")
 export "$1=$v"
}
json_get_type() {
 local v
 v=$(python3 -c 'import json,os,sys; v=json.loads(os.environ["J_INPUT"]).get(sys.argv[1]); print("string" if isinstance(v,str) else "other")' "$2")
 export "$1=$v"
}
json_select() {
 local v
 v=$(python3 -c 'import json,os,sys; print(json.dumps(json.loads(os.environ["J_INPUT"])[sys.argv[1]]))' "$1") || return 1
 export J_INPUT="$v"
}
_add() {
 export J_OUTPUT=$(python3 -c 'import json,os,sys; j=json.loads(os.environ["J_OUTPUT"]); k,v,t=sys.argv[1:]; j[k]=bool(int(v)) if t=="bool" else int(v) if t=="int" else v; print(json.dumps(j))' "$1" "$2" "$3")
}
json_add_string() { _add "$1" "$2" str; }
json_add_boolean() { _add "$1" "$2" bool; }
json_add_int() { _add "$1" "$2" int; }
json_dump() { printf '%s\n' "$J_OUTPUT"; }
'''
CURL = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, sys, urllib.parse
a=sys.argv[1:]
if a==['--help','all']:
    print('--parallel-max <num>\n--parallel-max-host <num>'); sys.exit(0)
if a==['--version']:
    print('Features: HTTP2'); sys.exit(0)
with open(os.environ['REQUEST_LOG'], 'a') as f: f.write(json.dumps(a)+'\n')
assert not any('fixture-secret' in x for x in a), 'password in curl argv'
service='fourcells' if '4cells.ru:' in a[-1] else 'speedmetrics'
mode=os.environ.get('SCENARIO','ok')
if mode=='network': sys.exit(28)
if '--config' in a:
    import base64
    jobs=[];current={}
    for line in pathlib.Path(a[a.index('--config')+1]).read_text().splitlines():
        if line=='next': jobs.append(current);current={}
        elif ' = ' in line:
            key,value=line.split(' = ',1);current[key]=json.loads(value)
    jobs.append(current)
    with open(os.environ['REQUEST_LOG'],'a') as f: f.write(json.dumps(['BATCH',[j['url'] for j in jobs]])+'\n')
    for job in reversed(jobs):
        assert job['url'].startswith('https://4cells.ru/api/Map/v2/measurements/'), 'arbitrary batch URL'
        assert job['header'].startswith('@'), 'credential must stay in a private file'
        code=429 if mode=='rate' else 403 if mode=='denied' else 401 if mode=='expired' else 200
        image=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==')
        pathlib.Path(job['output']).write_bytes(b'<html>blocked</html>' if mode=='tile_html' else image)
        print(job['write-out'].replace('%{http_code}',str(code)).replace('%{num_connects}','0'),end='')
        if code!=200: sys.exit(22)
    sys.exit(0)
code=429 if mode=='rate' else 401 if mode==service else 200
if a[-1].endswith('/security/sign'):
    code=429 if mode=='sign_rate' else 200
    seed='invalid' if mode=='sign_invalid' else '0'*64
    pathlib.Path(a[a.index('--dump-header')+1]).write_text('HTTP/1.1 200 OK\r\nX-Request-Id: '+seed+'\r\nX-Request-Ttl: 3600\r\n')
    suffix='sign';reply={'success':True}
elif '--data-binary' in a:
    body=json.loads(pathlib.Path(a[a.index('--data-binary')+1][1:]).read_text())
    if a[-1].endswith('/auth/refresh'):
        import time,base64
        assert body['userName']=='synthetic-user' and body['refreshToken'].startswith('synthetic-refresh')
        assert not any(body['refreshToken'] in arg for arg in a), 'refresh token in argv'
        payload=base64.urlsafe_b64encode(json.dumps({'unique_name':'synthetic-user','exp':int(time.time())+7200}).encode()).decode().rstrip('=')
        reply={'success':True,'data':{'accessToken':'e30.'+payload+'.synthetic','refreshToken':'synthetic-refresh-renewed'}}
        code=401 if mode in ('refresh_rejected','all_auth_rejected') else 429 if mode=='refresh_rate' else 200
        if mode=='refresh_network':sys.exit(28)
    else:
        assert body['password'].startswith('fixture-secret')
        if mode=='all_auth_rejected':code=401
        suffix=hashlib.sha256(json.dumps(body).encode()).hexdigest()[:8]
        reply={'data':{'accessToken':'synthetic-access-'+suffix,'refreshToken':'synthetic-refresh-'+suffix}} if service=='fourcells' else {'ok':True}
else:
    suffix='public'; reply={'items':[]}
if mode in ('restricted','refresh_rejected') and '/api/map/enb/' in a[-1]: reply={'success':True,'license':'Development-API access required for external clients','data':[{'lat':1.01,'lon':2.01,'num':123,'locType':2}]}
if '/api/map/enb/' in a[-1]:
    uri=urllib.parse.urlsplit(a[-1]); canonical=uri.path+'?'+uri.query
    ua=a[a.index('--user-agent')+1]
    expected=hashlib.sha256((canonical+'-'+'0'*64+'-'+ua).encode()).hexdigest()
    headers=pathlib.Path(a[a.index('--header')+1][1:]).read_text()
    assert 'x-request-id: '+expected in headers, 'invalid request signature'
pathlib.Path(a[a.index('--output')+1]).write_text(json.dumps(reply))
if '/api/Map/v2/measurements/' in a[-1]:
    import base64
    image=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==')
    pathlib.Path(a[a.index('--output')+1]).write_bytes(b'<html>blocked</html>' if mode=='tile_html' else image)

if '--cookie-jar' in a: pathlib.Path(a[a.index('--cookie-jar')+1]).write_text('# Netscape\n.example.invalid\tTRUE\t/\tTRUE\t0\tsession\tsynthetic-'+suffix+'\n')
print(code,end='')
'''


class MapAccountTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.account = self.directory / 'account/maps.json'
        self.runtime = self.directory / 'runtime'
        (self.directory / 'jshn.sh').write_text(JSHN)
        (self.directory / 'bin').mkdir()
        curl = self.directory / 'bin/curl'
        curl.write_text(CURL)
        curl.chmod(0o755)
        jsonfilter = self.directory / 'bin/jsonfilter'
        jsonfilter.write_text("""#!/usr/bin/env python3
import json,sys
args=sys.argv[1:]; data=json.load(open(args[args.index('-i')+1])); expr=args[args.index('-e')+1]
if expr=='@': print(json.dumps(data)); sys.exit(0)
value=data
for key in expr.removeprefix('@.').split('.'):
    value=value.get(key) if isinstance(value,dict) else None
if value is None: sys.exit(1)
print(str(value).lower() if isinstance(value,bool) else value)
""")
        jsonfilter.chmod(0o755)
        self.script = self.directory / 'rpc'
        source = BACKEND.read_text().replace('/usr/share/libubox/jshn.sh', str(self.directory / 'jshn.sh'))
        source = source.replace('ACCOUNT_DIR=/etc/5gmodem-private', 'ACCOUNT_DIR=' + str(self.account.parent))
        source = source.replace('RUNTIME=/tmp/5gmodem-private/maps', 'RUNTIME=' + str(self.runtime))
        source = source.replace('chmod 700 /tmp/5gmodem-private', 'chmod 700 ' + str(self.directory))
        self.script.write_text(source)
        self.env = dict(os.environ, PATH=str(self.directory / 'bin') + ':' + os.environ['PATH'], REQUEST_LOG=str(self.directory / 'requests'))

    def call(self, method, data=None, scenario='ok'):
        result = subprocess.run(['sh', str(self.script), 'call', method], input=json.dumps(data or {})+'\n',
                                text=True, capture_output=True, env=dict(self.env, SCENARIO=scenario), timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def login(self, login='fixture@example.invalid', password='fixture-secret', scenario='ok'):
        return self.call('login', dict(login=login, password=password), scenario=scenario)

    def expire_session(self):
        import base64,time
        payload=base64.urlsafe_b64encode(json.dumps({'unique_name':'synthetic-user','exp':int(time.time())-1}).encode()).decode().rstrip('=')
        (self.runtime/'fourcells.json').write_text(json.dumps({'accessToken':'e30.'+payload+'.synthetic','refreshToken':'synthetic-refresh-original'}))

    def test_credentials_private_and_password_retention(self):
        secret = 'fixture-secret " \\ $(touch unexpected-file)'
        self.assertTrue(self.login(password=secret)['configured'])
        self.assertEqual(self.account.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.account.parent.stat().st_mode & 0o777, 0o700)
        self.assertTrue(self.login(password='')['ok'])
        self.assertEqual(json.loads(self.account.read_text())['password'], secret)
        self.assertEqual(self.login(login='other@example.invalid', password='')['error'], 'password_required')
        self.assertNotIn(secret, json.dumps(self.call('status')))

    def test_failed_candidate_preserves_saved_account_and_sessions(self):
        reply = self.login()
        self.assertEqual((reply['fourcells'], reply['speedmetrics']), ('ok', 'ok'))
        snapshots = {name: (self.runtime / name).read_bytes() for name in ['fourcells.json', 'speedmetrics.cookie', 'status.json']}
        account = self.account.read_bytes()
        for name in snapshots:
            self.assertEqual((self.runtime / name).stat().st_mode & 0o777, 0o600)
        self.assertNotIn('synthetic-access', json.dumps(reply))
        self.assertNotIn('fixture-secret', json.dumps(reply))
        for failure in ['fourcells', 'speedmetrics']:
            reply = self.login(login='other@example.invalid', password='fixture-secret-new', scenario=failure)
            self.assertFalse(reply['ok'])
            self.assertEqual(reply['service'], failure)
            self.assertEqual(reply['error'], 'rejected')
            self.assertEqual(self.account.read_bytes(), account)
            for name, contents in snapshots.items():
                self.assertEqual((self.runtime / name).read_bytes(), contents)
        self.assertFalse(list(self.runtime.glob('login.*')))
        self.assertFalse((self.runtime / 'lock').exists())
        self.assertTrue(self.login(password='fixture-secret-new')['ok'])
        self.assertEqual(json.loads(self.account.read_text())['password'], 'fixture-secret-new')

    def test_failed_first_login_does_not_save_credentials(self):
        for scenario, expected in [('network', 'network'), ('rate', 'rate_limited'), ('fourcells', 'rejected')]:
            reply = self.login(scenario=scenario)
            self.assertFalse(reply['ok'])
            self.assertEqual(reply['error'], expected)
            self.assertFalse(self.account.exists())
            self.assertFalse((self.runtime / 'fourcells.json').exists())
            self.assertFalse((self.runtime / 'speedmetrics.cookie').exists())

    def test_layer_input_cannot_trigger_arbitrary_or_worldwide_requests(self):
        valid = dict(kind='speed', south='1', west='2', north='1.1', east='2.1', zoom=14)
        for change in [dict(kind='https://example.invalid'), dict(south='$(id)'), dict(zoom=2),
                       dict(north='50'), dict(east='1'), dict(kind='fourcells', operator='../', technology='lte')]:
            reply = self.call('layers', dict(valid, **change))
            self.assertFalse(reply['ok'])
        self.assertFalse((self.directory / 'requests').exists())
        self.assertEqual(self.call('layers', valid)['error'], 'sign_in_required')

    def test_native_signing_and_cached_seed(self):
        self.assertTrue(self.login()['ok'])
        data=dict(kind='fourcells', south='1', west='2', north='1.1', east='2.1', zoom=14, operator='001001', technology='lte')
        reply=self.call('layers',data,scenario='restricted')
        self.assertTrue(reply['ok'])
        self.assertEqual(reply['data']['data'][0]['num'],123)
        self.assertIn('license',reply['data'], 'license text alone does not imply invalid coordinates')
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        self.assertEqual(sum(r[-1].endswith('/security/sign') for r in requests),1)
        self.assertEqual(sum('/api/map/enb/' in r[-1] for r in requests),1)
        self.assertEqual((self.runtime/'fourcells-sign.json').stat().st_mode & 0o777,0o600)
        (self.runtime/'last_fourcells').unlink(missing_ok=True)
        self.assertTrue(self.call('layers',dict(data,east='2.2'),scenario='restricted')['ok'])
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        self.assertEqual(sum(r[-1].endswith('/security/sign') for r in requests),1,'reuse unexpired seed')
        self.assertEqual(sum('/api/map/enb/' in r[-1] for r in requests),2)
        cached=json.loads((self.runtime/'fourcells-sign.json').read_text())
        cached['until']=0
        (self.runtime/'fourcells-sign.json').write_text(json.dumps(cached))
        (self.runtime/'last_fourcells').unlink(missing_ok=True)
        self.assertTrue(self.call('layers',dict(data,east='2.3'),scenario='restricted')['ok'])
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        self.assertEqual(sum(r[-1].endswith('/security/sign') for r in requests),2,'expired identifiers are renewed')

    def test_invalid_or_rate_limited_signing_never_falls_back_to_unsigned(self):
        self.assertTrue(self.login()['ok'])
        data=dict(kind='fourcells', south='1', west='2', north='1.1', east='2.1', zoom=14, operator='001001', technology='lte')
        reply=self.call('layers',data,scenario='sign_invalid')
        self.assertEqual(reply['error'],'unexpected_response')
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        self.assertFalse(any('/api/map/enb/' in r[-1] for r in requests))
        (self.runtime/'last_fourcells').unlink(missing_ok=True)
        reply=self.call('layers',data,scenario='sign_rate')
        self.assertEqual(reply['error'],'rate_limited')
        before=(self.directory/'requests').read_text()
        self.assertEqual(self.call('layers',data)['error'],'provider_paused')
        self.assertEqual((self.directory/'requests').read_text(),before)

    def test_only_admin_acl_and_preserved_configuration(self):
        acl = json.loads((ROOT / 'root/usr/share/rpcd/acl.d/luci-app-5gmodem.json').read_text())['luci-app-5gmodem']
        self.assertEqual(acl['read']['ubus']['5gmodem_maps'], ['status'])
        self.assertEqual(acl['write']['ubus']['5gmodem_maps'], ['login', 'layers', 'tile', 'tiles'])
        public = (ROOT / 'root/usr/share/rpcd/acl.d/luci-app-5gmodem-api.json').read_text()
        self.assertNotIn('5gmodem_maps', public)
        self.assertIn('/etc/5gmodem-private/maps.json', (ROOT / 'Makefile').read_text())

    def test_provider_cooldown_blocks_other_endpoints_without_network(self):
        first = self.call('layers', {'kind': 'operators'}, scenario='rate')
        self.assertEqual(first['error'], 'rate_limited')
        requests = (self.directory / 'requests').read_text()
        (self.runtime / 'fourcells.json').write_text('{"accessToken":"synthetic"}')
        second = self.call('layers', dict(kind='fourcells', south='1', west='2',
            north='1.1', east='2.1', zoom=14, operator='001001', technology='lte'))
        self.assertEqual(second['error'], 'provider_paused')
        self.assertEqual((self.directory / 'requests').read_text(), requests)
        self.assertEqual(self.call('layers', {'kind': 'operators'})['error'], 'provider_paused')
        self.assertEqual((self.directory / 'requests').read_text(), requests)

    def test_repeated_identical_queries_are_cached_without_delay(self):
        self.assertTrue(self.call('layers', {'kind': 'operators'})['ok'])
        requests = (self.directory / 'requests').read_text()
        self.assertTrue(self.call('layers', {'kind': 'operators'})['ok'])
        self.assertEqual((self.directory / 'requests').read_text(), requests)

    def test_changed_viewport_is_not_subject_to_a_fixed_delay(self):
        self.assertTrue(self.login()['ok'])
        data=dict(kind='speed',south='1',west='2',north='1.1',east='2.1',zoom=14)
        self.assertTrue(self.call('layers',data)['ok'])
        self.assertTrue(self.call('layers',dict(data,east='2.2'))['ok'])
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        self.assertEqual(sum('/all?' in r[-1] for r in requests),2)

    def test_measurement_tile_validation_and_cache(self):
        self.assertTrue(self.login()['ok'])
        data=dict(x='1',y='2',zoom='16',operator='001001',technology='lte')
        for bad in [dict(x='$(id)'),dict(zoom='3'),dict(x='999999'),dict(operator='../')]:
            self.assertEqual(self.call('tile',dict(data,**bad))['ok'],False)
        reply=self.call('tile',data)
        self.assertTrue(reply['ok'])
        self.assertTrue(reply['image'].startswith('data:image/png;base64,iVBORw0KGgo'))
        before=(self.directory/'requests').read_text()
        self.assertTrue(self.call('tile',data)['ok'])
        self.assertEqual((self.directory/'requests').read_text(),before)

    def test_fourcells_overview_does_not_limit_data_to_local_view(self):
        self.assertTrue(self.login()['ok'])
        data=dict(kind='fourcells',south='10',west='20',north='12',east='22',zoom=9,operator='001001',technology='lte')
        self.assertTrue(self.call('layers',data)['ok'])
        self.assertEqual(self.call('layers',dict(data,kind='speed'))['error'],'zoom_in')
        self.assertTrue(self.call('tile',dict(x='12',y='13',zoom='6',operator='001001',technology='lte'))['ok'])
        self.assertEqual(self.call('tile',dict(x='12',y='13',zoom='5',operator='001001',technology='lte'))['error'],'zoom_in')

    def test_measurement_tile_never_exposes_html_as_an_image(self):
        self.assertTrue(self.login()['ok'])
        reply=self.call('tile',dict(x='1',y='2',zoom='16',operator='001001',technology='lte'),scenario='tile_html')
        self.assertEqual(reply['error'],'unexpected_response')
        self.assertNotIn('image',reply)

    def test_shared_map_reads_keep_login_exclusive(self):
        self.assertTrue(self.login()['ok'])
        tile=dict(x='1',y='2',zoom='16',operator='001001',technology='lte')
        with (self.runtime/'account.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_SH|fcntl.LOCK_NB)
            self.assertTrue(self.call('tile',tile)['ok'],'another reader must not block image loading')
            self.assertEqual(self.call('login',{})['error'],'busy','account writes exclude map readers')
            fcntl.flock(lock,fcntl.LOCK_UN)
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertEqual(self.call('tile',tile)['error'],'busy','login blocks new readers')
        with (self.runtime/'sign.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertTrue(self.call('tile',tile)['ok'],'JSON cache writer does not hold up image tiles')
            self.assertTrue(self.call('layers',dict(kind='operators'))['ok'],'public handbook does not wait for signing')

    def test_tile_batch_shares_one_curl_and_skips_cached_images(self):
        self.assertTrue(self.login()['ok'])
        data=dict(tiles='1:2,2:2,3:2',zoom='16',operator='001001',technology='lte')
        reply=self.call('tiles',data)
        self.assertTrue(reply['ok']);self.assertEqual(set(reply['tiles']),{'1:2','2:2','3:2'})
        self.assertTrue(all(v['ok'] and v['image'].startswith('data:image/png;base64,iVBORw0KGgo') for v in reply['tiles'].values()))
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        batches=[r for r in requests if r[0]=='BATCH']
        self.assertEqual(len(batches),1);self.assertEqual(len(batches[0][1]),3)
        argv=next(r for r in requests if '--config' in r)
        self.assertIn('--parallel',argv);self.assertEqual(argv[argv.index('--parallel-max')+1],'3')
        self.assertEqual(argv[argv.index('--parallel-max-host')+1],'1','one connection prevents parallel TLS handshakes on small CPUs')
        before=(self.directory/'requests').read_text()
        self.assertTrue(self.call('tiles',data)['ok'])
        self.assertEqual((self.directory/'requests').read_text(),before,'cached viewport requires no curl')
        self.assertTrue(self.call('tiles',dict(data,tiles='1:2,4:2,4:2'))['ok'])
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        self.assertEqual(len([r for r in requests if r[0]=='BATCH'][-1][1]),1,'cached and duplicate pairs do not download again')

    def test_tile_batch_validates_every_coordinate_before_network(self):
        data=dict(tiles='1:2,2:2',zoom='16',operator='001001',technology='lte')
        for change in [dict(tiles='1:2,3:$(id)'),dict(tiles='1:2,3:4:5'),dict(tiles='1:2,'),dict(tiles='1:2,,3:4'),dict(tiles='-1:2'),dict(tiles='999999:2'),dict(tiles=','.join('1:2' for _ in range(13))),dict(zoom='5'),dict(zoom='08'),dict(operator='../')]:
            self.assertFalse(self.call('tiles',dict(data,**change))['ok'])
        self.assertFalse((self.directory/'requests').exists())

    def test_tile_batch_cooldown_auth_and_html_errors(self):
        self.assertTrue(self.login()['ok'])
        data=dict(tiles='1:2,2:2',zoom='16',operator='001001',technology='lte')
        self.assertEqual(self.call('tiles',data,scenario='expired')['error'],'sign_in_required')
        html=self.call('tiles',data,scenario='tile_html')
        self.assertTrue(html['ok']);self.assertTrue(all(v['error']=='unexpected_response' and 'image' not in v for v in html['tiles'].values()))
        self.assertEqual(self.call('tiles',data,scenario='rate')['error'],'rate_limited')
        before=(self.directory/'requests').read_text()
        self.assertEqual(self.call('tiles',data)['error'],'provider_paused')
        self.assertEqual((self.directory/'requests').read_text(),before)

    def test_tile_batch_old_curl_reuses_connection_sequentially(self):
        self.assertTrue(self.login()['ok'])
        (self.runtime/'curl-parallel').write_text('0')
        self.assertTrue(self.call('tiles',dict(tiles='1:2,2:2',zoom='16',operator='001001',technology='lte'))['ok'])
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        argv=next(r for r in requests if '--config' in r)
        self.assertNotIn('--parallel',argv,'older curl still uses one process with its connection cache')

    def test_tile_batch_without_per_host_limit_or_shared_flock(self):
        self.assertTrue(self.login()['ok'])
        (self.runtime/'curl-parallel').write_text('1')
        (self.runtime/'curl-single-host').write_text('0')
        data=dict(tiles='1:2,2:2',zoom='16',operator='001001',technology='lte')
        self.assertTrue(self.call('tiles',data)['ok'])
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        self.assertNotIn('--parallel',next(r for r in requests if '--config' in r))
        self.script.write_text(self.script.read_text().replace('if command -v flock >/dev/null 2>&1; then','if false; then'))
        self.assertTrue(self.call('tiles',dict(data,tiles='3:2,4:2'))['ok'])
        self.assertFalse((self.runtime/'lock').exists(),'exclusive fallback lock is released')

    def test_expired_session_renews_before_loading_tower_details(self):
        self.assertTrue(self.login()['ok']);self.expire_session()
        data=dict(kind='fourcells',south='1',west='2',north='1.1',east='2.1',zoom=15,operator='001001',technology='lte')
        reply=self.call('layers',data,scenario='restricted')
        self.assertTrue(reply['ok']);self.assertEqual(reply['data']['data'][0]['num'],123)
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        routes=[r[-1] for r in requests]
        self.assertEqual(sum(r.endswith('/auth/refresh') for r in routes),1)
        self.assertLess(next(i for i,r in enumerate(routes) if r.endswith('/auth/refresh')),next(i for i,r in enumerate(routes) if '/api/map/enb/' in r))
        session=json.loads((self.runtime/'fourcells.json').read_text())
        self.assertEqual(session['userName'],'synthetic-user');self.assertEqual(session['refreshToken'],'synthetic-refresh-renewed')
        self.assertEqual((self.runtime/'fourcells.json').stat().st_mode & 0o777,0o600)
        self.assertTrue(self.call('layers',dict(data,east='2.2'),scenario='restricted')['ok'])
        after=[json.loads(line)[-1] for line in (self.directory/'requests').read_text().splitlines()]
        self.assertEqual(sum(r.endswith('/auth/refresh') for r in after),1,'fresh session does not renew on each viewport')

    def test_expired_session_is_renewed_for_both_tile_methods(self):
        self.assertTrue(self.login()['ok']);self.expire_session()
        self.assertTrue(self.call('tiles',dict(tiles='1:2,2:2',zoom='16',operator='001001',technology='lte'))['ok'])
        self.expire_session()
        self.assertTrue(self.call('tile',dict(x='3',y='2',zoom='16',operator='001001',technology='lte'))['ok'])
        requests=[json.loads(line) for line in (self.directory/'requests').read_text().splitlines()]
        self.assertEqual(sum(isinstance(r[-1],str) and r[-1].endswith('/auth/refresh') for r in requests),2)

    def test_failed_refresh_never_loads_anonymous_tower_data_or_loops(self):
        self.assertTrue(self.login()['ok']);self.expire_session()
        data=dict(kind='fourcells',south='1',west='2',north='1.1',east='2.1',zoom=15,operator='001001',technology='lte')
        old=(self.runtime/'fourcells.json').read_text()
        self.assertEqual(self.call('layers',data,scenario='all_auth_rejected')['error'],'sign_in_required')
        self.assertEqual((self.runtime/'fourcells.json').read_text(),old,'rejected renewal preserves saved session')
        before=(self.directory/'requests').read_text()
        self.assertEqual(self.call('layers',data)['error'],'sign_in_required')
        self.assertEqual((self.directory/'requests').read_text(),before,'renewal failure has a retry cooldown')
        self.assertFalse(any('/api/map/enb/' in line for line in before.splitlines()))

    def test_rejected_refresh_automatically_uses_saved_credentials(self):
        self.assertTrue(self.login()['ok']);self.expire_session()
        cookie=(self.runtime/'speedmetrics.cookie').read_text()
        data=dict(kind='fourcells',south='1',west='2',north='1.1',east='2.1',zoom=15,operator='001001',technology='lte')
        reply=self.call('layers',data,scenario='refresh_rejected')
        self.assertTrue(reply['ok']);self.assertEqual(reply['data']['data'][0]['num'],123)
        routes=[json.loads(line)[-1] for line in (self.directory/'requests').read_text().splitlines()]
        self.assertEqual(sum(r.endswith('/auth/signIn') for r in routes),2,'one original login and one automatic re-login')
        self.assertEqual((self.runtime/'speedmetrics.cookie').read_text(),cookie,'4Cells renewal does not replace Speedmetrics login')

    def test_lost_runtime_session_is_restored_from_saved_account(self):
        self.assertTrue(self.login()['ok']);(self.runtime/'fourcells.json').unlink()
        self.assertTrue(self.call('tile',dict(x='1',y='2',zoom='16',operator='001001',technology='lte'))['ok'])
        self.assertTrue((self.runtime/'fourcells.json').exists())

    def test_concurrent_map_requests_only_refresh_once(self):
        from concurrent.futures import ThreadPoolExecutor
        self.assertTrue(self.login()['ok']);self.expire_session()
        with ThreadPoolExecutor(max_workers=2) as executor:
            results=list(executor.map(lambda x:self.call('tile',dict(x=str(x),y='2',zoom='16',operator='001001',technology='lte')),[1,2]))
        self.assertTrue(all(r['ok'] for r in results))
        requests=[json.loads(line)[-1] for line in (self.directory/'requests').read_text().splitlines()]
        self.assertEqual(sum(r.endswith('/auth/refresh') for r in requests),1,'refresh lock rechecks the new token after waiting')


if __name__ == '__main__':
    unittest.main()
