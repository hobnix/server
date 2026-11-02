#!/usr/bin/env python3
import json, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HELPER = os.path.join(ROOT, "scripts", "lib", "docker_app_doc.py")
PY = sys.executable

class Doc(unittest.TestCase):
    def run_helper(self, mode, stdin):
        p = subprocess.run([PY, HELPER, mode], input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return p

    def test_parse_roundtrip(self):
        raw = b"rev\t0123456789abcdef\nmanaged\tweb\nenv\tFOO\nenv\tBAR\n__HS_COMPOSE__\nservices:\n  x:\n    image: y\n"
        p = self.run_helper("parse", raw)
        self.assertEqual(p.returncode, 0, p.stderr)
        d = json.loads(p.stdout)
        self.assertEqual(d["rev"], "0123456789abcdef")
        self.assertEqual(d["managed"], "web")
        self.assertEqual(d["env"], ["FOO", "BAR"])
        self.assertIn("services:", d["compose"])

    def test_parse_compose_with_separator_text(self):
        raw = b"rev\t0123456789abcdef\nmanaged\tother\n__HS_COMPOSE__\n# __HS_COMPOSE__\nhello\n"
        p = self.run_helper("parse", raw)
        self.assertEqual(p.returncode, 0)
        d = json.loads(p.stdout)
        self.assertEqual(d["compose"], "# __HS_COMPOSE__\nhello\n")

    def test_parse_malformed(self):
        for raw in (b"no separator here", b"rev\tbad\nmanaged\tweb\n__HS_COMPOSE__\nx", b"rev\t0123456789abcdef\nmanaged\tweb\nenv\t1bad\n__HS_COMPOSE__\nx"):
            p = self.run_helper("parse", raw)
            self.assertNotEqual(p.returncode, 0, raw)

    def test_check_named_volume(self):
        cfg = {"services": {"a": {"image": "x"}}, "volumes": {"data": {}}}
        p = self.run_helper("check", json.dumps(cfg).encode())
        self.assertEqual(p.returncode, 0)
        self.assertIn(b"refuse\tTop-level named volumes are not allowed.", p.stdout)

    def test_check_implicit_port(self):
        cfg = {"services": {"a": {"image": "x", "ports": [{"target": 80}]}}}
        p = self.run_helper("check", json.dumps(cfg).encode())
        self.assertEqual(p.returncode, 0)
        self.assertIn(b"refuse\tEvery published port must name the host port.", p.stdout)

    def test_check_valid_ports_and_warnings(self):
        cfg = {"services": {"a": {"image": "x", "ports": [{"published": 8080, "target": 80}], "environment": {"DB_PASSWORD": "x", "TOKEN": "y", "OK": "z"}}}}
        p = self.run_helper("check", json.dumps(cfg).encode())
        self.assertEqual(p.returncode, 0)
        self.assertIn(b"port\t8080", p.stdout)
        self.assertIn(b"warn\tService a environment key DB_PASSWORD holds a literal value", p.stdout)
        self.assertIn(b"warn\tService a environment key TOKEN holds a literal value", p.stdout)
        self.assertNotIn(b"x", p.stdout)

    def test_check_malformed_json(self):
        p = self.run_helper("check", b"{not json")
        self.assertNotEqual(p.returncode, 0)

if __name__ == "__main__":
    unittest.main(verbosity=1)
PY