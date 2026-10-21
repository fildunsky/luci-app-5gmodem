#!/usr/bin/env python3
import base64, json, os, sys, urllib.parse

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, '..', 'htdocs', 'luci-static', 'resources', 'icons', '5gmodem')
out = os.path.join(here, '..', 'htdocs', 'luci-static', 'resources', 'view', 'modem5g', 'icons.js')

def uri(path):
    data = open(path, 'rb').read()
    if path.endswith('.svg'):
        return 'data:image/svg+xml,' + urllib.parse.quote(data.decode('utf-8'), safe=" =:/;,()-._~!*$@+")
    if path.endswith('.png'):
        return 'data:image/png;base64,' + base64.b64encode(data).decode()
    return None

icons = {}
for name in sorted(os.listdir(src)):
    u = uri(os.path.join(src, name))
    if u:
        icons[name] = u

body = "'use strict';\n'require baseclass';\n\nvar D = {\n"
body += ",\n".join("\t%s: %s" % (json.dumps(k), json.dumps(v)) for k, v in icons.items())
body += "\n};\n\nreturn baseclass.extend({\n\turl: function(p) {\n\t\tvar n = String(p || '').replace(/^.*\\//, '');\n\t\treturn D[n] || L.resource(p);\n\t}\n});\n"

if '--check' in sys.argv:
    cur = open(out).read() if os.path.exists(out) else ''
    if cur != body:
        print('icons.js is out of date: run tools/gen-icons.py')
        sys.exit(1)
    print('icons.js up to date: %d icons' % len(icons))
    sys.exit(0)

open(out, 'w').write(body)
print('icons.js: %d icons, %d bytes' % (len(icons), len(body)))
