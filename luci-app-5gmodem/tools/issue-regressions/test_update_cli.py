import os, pathlib, subprocess, tempfile
import unittest

class UpdateCliTest(unittest.TestCase):
 def test_frontend(self):
    source=(pathlib.Path(__file__).resolve().parents[2] / 'root/usr/bin/5gmodem').read_text()
    with tempfile.TemporaryDirectory() as d:
     p=pathlib.Path(d)
     def executable(name,text):
      f=p/name; f.write_text(text); f.chmod(0o755); return f
     executable('id', '#!/bin/sh\necho 0\n')
     executable('jsonfilter', '''#!/usr/bin/env python3
import json,sys
try:
 v=json.load(sys.stdin).get(sys.argv[2][2:],'')
 print(str(v).lower() if isinstance(v,bool) else v)
except Exception: pass
''')
     updater=executable('updater', '''#!/bin/sh
case "$1" in
check) cat "$MOCK_CHECK" ;;
install) echo '{"started":true}'; cp "$MOCK_RESULT" "$MOCK_STATUS" ;;
esac
''')
     script=executable('cli',source.replace('/usr/share/5gmodem/update.sh',str(updater)).replace('/tmp/5gmodem/update.json',str(p/'status')))
     env=dict(os.environ, PATH=d+':'+os.environ['PATH'],MOCK_CHECK=str(p/'check'),MOCK_RESULT=str(p/'result'),MOCK_STATUS=str(p/'status'))
     def run(args,check,result='',code=0,contains='',answer=''):
      (p/'check').write_text(check); (p/'result').write_text(result)
      r=subprocess.run([str(script),*args],env=env,input=answer,text=True,capture_output=True,timeout=10)
      assert r.returncode==code,(args,r)
      assert contains in r.stdout+r.stderr,(args,r)
     run(['update'],'{"success":true,"update_available":0}',contains='Already up to date')
     run(['update'],'{"success":false,"error":"offline"}',code=1,contains='offline')
     run(['update'],'{"success":true,"update_available":1}',contains='Cancelled.')
     run(['update'],'{"success":true,"update_available":1}',contains='Cancelled.',answer='n\n')
     run(['update'],'{"success":true,"update_available":1}','{"success":true,"current":"3.9.35"}',contains='Updated successfully',answer='y\n')
     run(['update'],'{"success":true,"update_available":1}','{"success":false,"error":"install_failed","detail":"dependency missing"}',code=1,contains='dependency missing',answer='y\n')
     run(['update','-y'],'{}',code=1,contains='Use: 5gmodem update')
     run(['check-update'],'{}',code=1,contains='Unknown command')
