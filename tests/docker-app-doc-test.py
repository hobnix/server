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

    def test_parse_env_text(self):
        import base64
        text = "A=1\nDB_PASSWORD=h\u00e4\n"
        raw = b"rev\t0123456789abcdef\nmanaged\tweb\nenv\tA\nenvb64\t" + base64.b64encode(text.encode()) + b"\n__HS_COMPOSE__\nx"
        p = self.run_helper("parse", raw)
        self.assertEqual(p.returncode, 0, p.stderr)
        d = json.loads(p.stdout)
        self.assertEqual(d["envText"], text)
        self.assertNotIn("envTooBig", d)

    def test_parse_env_none_and_big(self):
        p = self.run_helper("parse", b"rev\t0123456789abcdef\nmanaged\tweb\n__HS_COMPOSE__\nx")
        self.assertEqual(json.loads(p.stdout)["envText"], "")
        p = self.run_helper("parse", b"rev\t0123456789abcdef\nmanaged\tweb\nenvbig\t1\n__HS_COMPOSE__\nx")
        d = json.loads(p.stdout)
        self.assertTrue(d["envTooBig"])
        self.assertEqual(d["envText"], "")

    def test_parse_env_bad_base64_or_utf8(self):
        import base64
        for val in (b"!!!notbase64", base64.b64encode(b"\xff\xfe")):
            p = self.run_helper("parse", b"rev\t0123456789abcdef\nmanaged\tweb\nenvb64\t" + val + b"\n__HS_COMPOSE__\nx")
            self.assertNotEqual(p.returncode, 0, val)

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

    def test_check_secret_from_env_file_is_no_warning(self):
        env = {"DB_PASSWORD": "s3cretvalue", "API_KEY": "literalkey", "DB_URL": "postgres://u:s3cretvalue@h/d"}
        cfg = {"services": {"a": {"image": "x", "environment": env}}}
        raw = {"services": {"a": {"image": "x", "environment": {"DB_PASSWORD": "${DB_PASSWORD:?set it}", "API_KEY": "literalkey", "DB_URL": "postgres://u:${DB_PASSWORD}@h/d"}}}}
        stdin = json.dumps(cfg).encode() + b"\n\x1e\n" + json.dumps(raw).encode()
        p = self.run_helper("check", stdin)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotIn(b"DB_PASSWORD", p.stdout)
        self.assertIn(b"warn\tService a environment key API_KEY holds a literal value", p.stdout)
        self.assertNotIn(b"s3cretvalue", p.stdout)

    def test_check_paths_cname_and_bind(self):
        cfg = {"volumes": {"v": {}}, "services": {"web": {"image": "x", "container_name": "cn", "ports": [{"target": 80}, {"published": 8080, "target": 80}],
               "volumes": [{"type": "bind", "source": "/srv/a", "target": "/a"}, {"type": "bind", "source": "/srv/b", "target": "/b", "read_only": True}, {"type": "volume", "source": "n", "target": "/c"}]}}}
        p = self.run_helper("check", json.dumps(cfg).encode())
        self.assertEqual(p.returncode, 0)
        out = p.stdout.decode()
        self.assertIn("refuse\tTop-level named volumes are not allowed.\tvolumes\n", out)
        self.assertIn("refuse\tEvery published port must name the host port.\tservices.web.ports\n", out)
        self.assertIn("port\t8080\tservices.web.ports\n", out)
        self.assertIn("cname\tcn\tservices.web.container_name\n", out)
        self.assertIn("bind\t/srv/a\trw\tservices.web.volumes\n", out)
        self.assertIn("bind\t/srv/b\tro\tservices.web.volumes\n", out)

    def test_check_malformed_json(self):
        p = self.run_helper("check", b"{not json")
        self.assertNotEqual(p.returncode, 0)

if __name__ == "__main__":
    unittest.main(verbosity=1)
PY