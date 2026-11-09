#!/usr/bin/env python3
"""scripts/web-serve.py, the `pkg check-draft` entry of CHANGES (the package builder, ADR 0020): the draft travels as a document on stdin, only for that
word, only as text of a bounded size; the other pkg entries do not take a document. The check itself is tested in tests/pkg-change.sh."""
import importlib.util
import os
import unittest

here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("web_login_test_base", os.path.join(here, "web-login-test.py"))
lt = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lt)
ws = lt.ws


class Draft(unittest.TestCase):
    def test_draft_is_allowed(self):
        ch = ws.validate_change({"area": "pkg", "args": ["check-draft"], "document": {"manifest": 'name = "x"\n'}})
        self.assertEqual(ch, ("pkg", ["check-draft"], None, b'name = "x"\n'))

    def test_refusals(self):
        bad = [
            {"area": "pkg", "args": ["check-draft"], "document": {"manifest": 5}},
            {"area": "pkg", "args": ["check-draft"], "document": {"manifest": "a\0b"}},
            {"area": "pkg", "args": ["check-draft"], "document": {"manifest": "x" * (ws.DRAFT_MAX + 1)}},
            {"area": "pkg", "args": ["check-draft"], "document": {"manifest": "x", "extra": 1}},
            {"area": "pkg", "args": ["check-draft", "extra"], "document": {"manifest": "x"}},
            {"area": "pkg", "args": ["fetch"], "document": {"manifest": "x"}},
            {"area": "pkg", "args": ["check-draft"], "stdin": "x", "document": {"manifest": "x"}},
        ]
        for b in bad:
            self.assertIsNone(ws.validate_change(b), b)

    def test_plan_is_never_cached(self):
        self.assertFalse(ws.plan_cacheable("pkg", ["check-draft"], None))


if __name__ == "__main__":
    unittest.main(verbosity=1)
