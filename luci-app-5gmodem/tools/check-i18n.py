#!/usr/bin/env python3
"""Сверка русского каталога с исходниками.

Печатает строки, которые интерфейс переводит через _(), а в po-ru/5gmodem.po
их нет (или перевод пуст), плюс дубликаты msgid. Код возврата 1, если нашлось
хоть что-то - так проверку можно ставить в релизный порядок и в CI.

Две ловушки, на которых сверка «на глаз» уже ошибалась:
  * кавычки. В po они экранированы (\\"), в JS-строке стоит обычная " - если
    сравнивать как есть, каждая строка с кавычкой выглядит непереведённой;
  * \\uXXXX. Многоточие в JS пишут escape-последовательностью, а в каталог оно
    попадает уже символом.
Поэтому обе стороны приводятся к тому виду, в котором строка приходит в
рантайме, и только потом сравниваются.

Смотрим ВЕСЬ htdocs, а не только view/modem5g: переводимые строки живут ещё в
protocol/, sms-tool-5gm/ и view/status/include/.
"""
import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PO = os.path.join(ROOT, 'po-ru', '5gmodem.po')
ESCAPES = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\'}


def po_unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            out.append(ESCAPES.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def trimws(s):
    """Ключ так, как его ищет LuCI (trimws в cbi.js, lmo_translate в luci-base):
    края обрезаны, пробелы, табы и переводы строк схлопнуты в один пробел.
    po2lmo хеширует msgid как написан, поэтому ключ в другой форме не найдётся."""
    return re.sub(r'[ \t\n]+', ' ', s.strip())


def js_unescape(s):
    s = s.replace('\\\n', '')
    s = s.replace("\\'", "'").replace('\\"', '"').replace('\\\\', '\\')
    for _ in range(2):
        s = re.sub(r'\\u([0-9a-fA-F]{4})', lambda m: chr(int(m.group(1), 16)), s)
    return s


def load_catalog():
    text = io.open(PO, encoding='utf-8').read()
    pairs = re.findall(
        r'^msgid\s+((?:"(?:[^"\\]|\\.)*"\s*)+)msgstr\s+((?:"(?:[^"\\]|\\.)*"\s*)+)',
        text, re.M)
    catalog, order = {}, []
    for msgid, msgstr in pairs:
        key = po_unescape(''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', msgid)))
        order.append(key)
        catalog[key] = po_unescape(''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', msgstr)))
    return catalog, order


CALL = re.compile(r"""\b_\(\s*'((?:[^'\\]|\\.)*)'|\b_\(\s*"((?:[^"\\]|\\.)*)\"""")


def main():
    catalog, order = load_catalog()
    missing, empty = {}, {}
    for path in sorted(glob.glob(os.path.join(ROOT, 'htdocs', '**', '*.js'), recursive=True)):
        rel = os.path.relpath(path, ROOT)
        for m in CALL.finditer(io.open(path, encoding='utf-8').read()):
            raw = m.group(1) if m.group(1) is not None else m.group(2)
            if not raw:
                continue
            s = trimws(js_unescape(raw))
            if s not in catalog:
                missing.setdefault(s, set()).add(rel)
            elif catalog[s] == '':
                empty.setdefault(s, set()).add(rel)
    dups = sorted({k for k in order if order.count(k) > 1 and k})
    unnorm = sorted({k for k in order if k and trimws(k) != k})

    for title, data in (('НЕТ в каталоге', missing), ('перевод ПУСТОЙ', empty)):
        if data:
            print('%s: %d' % (title, len(data)))
            for s, files in sorted(data.items()):
                print('  [%s] %s' % (', '.join(sorted(files)), s))
    if dups:
        print('дубликаты msgid: %d' % len(dups))
        for s in dups:
            print('  %s' % s)
    if unnorm:
        print('msgid не в форме рантайма (пробелы по краям, табы, переводы строк): %d' % len(unnorm))
        for k in unnorm:
            print('  %r' % k)
    if not (missing or empty or dups or unnorm):
        print('перевод полный: %d строк, дубликатов нет' % len(catalog))
        return 0
    return 1


if __name__ == '__main__':
    sys.exit(main())
