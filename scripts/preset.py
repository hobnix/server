#!/usr/bin/env python3
"""Reads the presets (presets/<name>.toml) for scripts/preset.sh. Stdlib only.

  preset.py list [lang]              name<TAB>title
  preset.py meta <name> [lang]       title, description and recipes as key<TAB>value lines
  preset.py rows <name>              machine<TAB>key<TAB>toml literal / setting<TAB>key<TAB>value, one per line; refuses a key
                                     that is not an option of config/schema.toml or sits in the wrong table
Test knobs: HS_PRESETS_DIR, HS_SCHEMA, HS_MACHINE_FILE (the checkout beside it is used when the scripts run from a copy).
"""
import json
import os
import sys
import tomllib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def beside(*parts):
    """Where the checkout is when the scripts run from a copy in /nix/store (no presets/ or config/ folder there): next to machine.toml."""
    machine = os.environ.get("HS_MACHINE_FILE") or "/etc/nixos/machine.toml"
    return os.path.join(os.path.dirname(machine), *parts)


def first_existing(candidates, default):
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return default


PRESETS = first_existing([os.environ.get("HS_PRESETS_DIR"), os.path.join(ROOT, "presets"), beside("presets")], os.path.join(ROOT, "presets"))
SCHEMA = first_existing([os.environ.get("HS_SCHEMA"), os.path.join(ROOT, "config", "schema.toml"), beside("config", "schema.toml")],
                        os.path.join(ROOT, "config", "schema.toml"))


def literal(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return json.dumps(v, ensure_ascii=False)
    if isinstance(v, list):
        return "[" + ", ".join(literal(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{ " + ", ".join("%s = %s" % (k, literal(x)) for k, x in v.items()) + " }"
    raise SystemExit("a value of type %s is not allowed in a preset" % type(v).__name__)


def load(name):
    if not name or "/" in name or name.startswith("."):
        raise SystemExit("no preset called '%s'" % name)
    path = os.path.join(PRESETS, name + ".toml")
    if not os.path.isfile(path):
        raise SystemExit("no preset called '%s'" % name)
    with open(path, "rb") as f:
        return tomllib.load(f)


def options():
    with open(SCHEMA, "rb") as f:
        items = tomllib.load(f).get("item", [])
    return {i["key"]: i.get("store", "machine") for i in items if i.get("kind") == "option"}


def main(argv):
    sys.stdout.reconfigure(newline="\n")   # LF only, also on Windows: bash reads these lines
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "list":
        lang = argv[2] if len(argv) > 2 else "en"
        for fn in sorted(os.listdir(PRESETS)):
            if not fn.endswith(".toml"):
                continue
            p = load(fn[:-5])
            print("%s\t%s" % (fn[:-5], p.get("title_" + lang) or p.get("title") or fn[:-5]))
    elif cmd == "meta":
        p = load(argv[2])
        lang = argv[3] if len(argv) > 3 else "en"
        print("title\t%s" % (p.get("title_" + lang) or p.get("title", argv[2])))
        print("description\t%s" % (p.get("description_" + lang) or p.get("description", "")))
        print("recipes\t%s" % " ".join(p.get("recipes", [])))
    elif cmd == "rows":
        p = load(argv[2])
        known = options()
        for table, kind in (("machine", "machine"), ("settings", "settings")):
            for k, v in p.get(table, {}).items():
                if k not in known:
                    raise SystemExit("preset %s: '%s' is not an option (config/schema.toml)" % (argv[2], k))
                if (known[k] == "settings") != (table == "settings"):
                    raise SystemExit("preset %s: '%s' belongs in [%s]" % (argv[2], k, "settings" if known[k] == "settings" else "machine"))
                if table == "settings":
                    print("setting\t%s\t%s" % (k, v if isinstance(v, str) else json.dumps(v)))
                else:
                    print("machine\t%s\t%s" % (k, literal(v)))
    else:
        raise SystemExit("usage: preset.py list|meta|rows")


if __name__ == "__main__":
    main(sys.argv)
