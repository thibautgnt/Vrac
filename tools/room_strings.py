#!/usr/bin/env python3
"""Add or update entries in a room string catalog (English key, French value).

    tools/room_strings.py CATALOG "Key" "Valeur"
    tools/room_strings.py CATALOG "%lld files" --plural "%lld fichier" "%lld fichiers" "%lld file"
    (the last argument is the English singular)
"""
import json
import os
import sys


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def plural(one, other):
    return {"variations": {"plural": {"one": unit(one), "other": unit(other)}}}


def main():
    args = sys.argv[1:]
    if len(args) < 3:
        sys.exit(__doc__)
    path, key = args[0], args[1]
    catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.1"}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            catalog = json.load(f)
    if args[2] == "--plural":
        fr_one, fr_other, en_one = args[3], args[4], args[5]
        entry = {"en": plural(en_one, key), "fr": plural(fr_one, fr_other)}
    else:
        entry = {"fr": unit(args[2])}
    catalog["strings"][key] = {"extractionState": "manual", "localizations": entry}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
