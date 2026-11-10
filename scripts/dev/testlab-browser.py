#!/usr/bin/env python3
"""Test-lab stage 6 (hobnix/server#432): a headless browser signs in to the web interface of the installed VM and opens every page of the
navigation (web/src/nav.js of the tested checkout). A page fails when the HTTP status is not 200, the script throws (pageerror), the console
logs an error, or the page stays empty.

UNVERIFIED: written without Incus, a browser or the playwright package. Not tested on hardware yet.

  testlab-browser.py run --url http://<vm>:8480 --nav <nav.js> --out <result-browser.json> [--user adminuser] [--timeout 120]
  testlab-browser.py pages <nav.js>          the paths it would open (no browser needed)

The password comes from HS_NESTED_PASSWORD (never argv). Exit codes: 0 all pages fine, 1 a page failed, 3 no browser here (playwright missing),
4 the web interface did not answer.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.request


def pages(nav_js):
    """The unique paths of the navigation tree, in order. Paths with a parameter are not opened."""
    with open(nav_js, encoding="utf-8") as f:
        text = f.read()
    seen, out = set(), []
    for p in re.findall(r"path:\s*'(/[^']*)'", text):
        if ":" in p or p in seen:
            continue
        seen.add(p)
        out.append(p)
    return out


def wait_up(url, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            urllib.request.urlopen(url + "/", timeout=5).read(1)
            return True
        except Exception:
            time.sleep(3)
    return False


def run(a):
    paths = pages(a.nav)
    pw = os.environ.get("HS_NESTED_PASSWORD", "")
    if not pw:
        print("HS_NESTED_PASSWORD is not set", file=sys.stderr)
        return 2
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("playwright is not installed here: stage 6 cannot run", file=sys.stderr)
        return 3
    if not wait_up(a.url, a.timeout):
        print("the web interface at %s did not answer within %ss" % (a.url, a.timeout), file=sys.stderr)
        return 4
    results = []
    with sync_playwright() as pwr:
        try:
            browser = pwr.chromium.launch(headless=True)
        except Exception as e:   # no browser binary
            print("no headless browser could start: %s" % e, file=sys.stderr)
            return 3
        ctx = browser.new_context(viewport={"width": 1280, "height": 900})
        login = ctx.request.post(a.url + "/api/login", data={"realm": "local", "user": a.user, "password": pw})
        results.append({"step": "sign in as %s" % a.user, "ok": login.ok})
        if login.ok:
            for p in paths:
                errors = []
                page = ctx.new_page()
                page.on("pageerror", lambda e, errors=errors: errors.append("script error: %s" % e))
                page.on("console", lambda m, errors=errors: errors.append("console: %s" % m.text) if m.type == "error" else None)
                rec = {"step": "open %s" % p, "ok": False}
                try:
                    resp = page.goto(a.url + p, wait_until="networkidle", timeout=30000)
                    status = resp.status if resp else 0
                    body = page.inner_text("body").strip()
                    if status != 200:
                        errors.append("HTTP %s" % status)
                    if not body:
                        errors.append("the page is empty")
                    if "/login" in page.url and p != "/login":
                        errors.append("sent back to the sign-in page")
                except Exception as e:
                    errors.append(str(e)[:200])
                rec["ok"] = not errors
                if errors:
                    rec["error"] = "; ".join(errors[:3])
                results.append(rec)
                page.close()
                print("  %s  %s" % ("ok  " if rec["ok"] else "FAIL", rec["step"]), flush=True)
        browser.close()
    ok = all(r["ok"] for r in results)
    with open(a.out, "w") as f:
        json.dump({"stage": "browser", "ok": ok, "steps": results}, f, indent=1)
    return 0 if ok else 1


def main(argv):
    ap = argparse.ArgumentParser(prog="testlab-browser")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pages")
    p.add_argument("nav")
    p = sub.add_parser("run")
    p.add_argument("--url", required=True)
    p.add_argument("--nav", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--user", default="adminuser")
    p.add_argument("--timeout", type=int, default=120)
    a = ap.parse_args(argv)
    if a.cmd == "pages":
        print("\n".join(pages(a.nav)))
        return 0
    return run(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
