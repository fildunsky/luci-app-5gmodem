#!/usr/bin/env python3
# Tabs hidden by settings ("Internet priorities only", alignment, statistics, eSIM, USSD) are hidden
# by style rules from modemtabs.js. The Buttons page did not load it, so opening Buttons showed every
# tab again. Every menu page must load modemtabs and apply the rules.
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEWS = ROOT / 'htdocs/luci-static/resources/view'
MENU = ROOT / 'root/usr/share/luci/menu.d/luci-app-5gmodem.json'


class MenuTabsGate(unittest.TestCase):
    def test_every_menu_page_loads_modemtabs(self):
        menu = json.loads(MENU.read_text())
        paths = {v['action']['path'] for v in menu.values()
                 if v.get('action', {}).get('type') == 'view'}
        self.assertIn('modem5g/buttons', paths)
        for p in sorted(paths):
            src = (VIEWS / (p + '.js')).read_text()
            self.assertIn("'require view.modem5g.modemtabs as modemtabs'", src, p)

    def test_buttons_applies_menu_rules(self):
        src = (VIEWS / 'modem5g/buttons.js').read_text()
        self.assertRegex(src, r'load: function\(\) \{[^\n]*modemtabs\.refreshMenuTabs\(\)')
        tabs = (VIEWS / 'modem5g/modemtabs.js').read_text()
        m = re.search(r'refreshMenuTabs: function\(\) \{.*?\n\t\},', tabs, re.S)
        self.assertIsNotNone(m)
        for call in ('applyGateTabs()', 'esimHideRule(', 'ussdHideRule('):
            self.assertIn(call, m[0])
        self.assertNotIn('fs.exec', m[0])


if __name__ == '__main__':
    unittest.main()
