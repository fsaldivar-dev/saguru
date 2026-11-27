#!/usr/bin/env python3
"""Writes the app's translation tables from Localization/<language>.json.

    scripts/make-strings.py <Resources folder>

Each JSON file maps a Spanish text of the interface to its translation. macOS wants them as
<language>.lproj/Localizable.strings; Spanish gets an empty table, so that it is offered as a language.
"""
import glob, json, os, sys

def quote(text):
    return '"' + text.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t') + '"'

resources = sys.argv[1]
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Localization')
os.makedirs(os.path.join(resources, 'es.lproj'), exist_ok=True)
open(os.path.join(resources, 'es.lproj', 'Localizable.strings'), 'w', encoding='utf-8').write('/* Spanish is the language the interface is written in. */\n')
for path in sorted(glob.glob(os.path.join(here, '*.json'))):
    language = os.path.basename(path)[:-5]
    if language == 'keys':
        continue
    table = json.load(open(path, encoding='utf-8'))
    folder = os.path.join(resources, language + '.lproj')
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, 'Localizable.strings'), 'w', encoding='utf-8') as out:
        for key in sorted(table):
            if table[key] and table[key] != key:
                out.write(quote(key) + ' = ' + quote(table[key]) + ';\n')
    print(f'{language}: {len(table)} textos')
