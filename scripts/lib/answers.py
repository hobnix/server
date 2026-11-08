#!/usr/bin/env python3
"""Check an answers file for unattended installs (docs/install.md "Answers file for unattended installs").

  answers.py check <file>   prints  level<TAB>where<TAB>text  (error|warn; an empty field is "-")
                            exit 0 no errors, 1 errors, 2 file unreadable or not valid TOML
Secret values are never printed and secret files are never read (only their mode and size are looked at).
Test knobs: HS_PRESETS_DIR (presets are checked against it when set), HS_ZONEINFO_DIR (default /usr/share/zoneinfo).
"""
import os
import re
import stat
import sys

try:
    import tomllib
except ImportError:  # pragma: no cover
    tomllib = None

SCHEMA = {
    "install": {
        "role": str, "disk": str, "confirm_disk": str, "hostname": str, "timezone": str,
        "preset": str, "nic": str, "smb_allow": str, "bios": bool,
    },
    "ssh": {"key": str, "key_file": str},
    "secrets": {"admin_password_file": str},
}
ROLES = ("homeserver", "edge", "minimal")
SECRET_WORDS = ("password", "passphrase", "token", "secret", "key")
PUBKEY = re.compile(r"^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp\d+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) \S+")
LABEL = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
ZONE = re.compile(r"^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
DEVICE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
CIDR = re.compile(r"^(\d{1,3}\.){3}\d{1,3}(/\d{1,2})?$")


def looks_secret(name):
    n = name.lower()
    return any(w in n for w in SECRET_WORDS) and not n.endswith("_file")


def main(argv):
    if len(argv) != 3 or argv[1] != "check":
        sys.stderr.write("usage: answers.py check <file>\n")
        return 2
    path = argv[2]
    out = []

    def err(where, text):
        out.append(("error", where, text))

    def warn(where, text):
        out.append(("warn", where, text))

    try:
        with open(path, "rb") as f:
            raw = f.read()
        if tomllib is None:
            sys.stderr.write("python 3.11 or newer is needed (tomllib)\n")
            return 2
        data = tomllib.loads(raw.decode("utf-8"))
    except OSError as e:
        sys.stdout.write("error\t-\tcannot read the file: %s\n" % (e.strerror or "error"))
        return 2
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as e:
        # the parser message names a line and a column, never the value
        sys.stdout.write("error\t-\tnot valid TOML: %s\n" % str(e).splitlines()[0])
        return 2

    ver = data.get("version")
    if "version" not in data:
        err("version", "missing; write version = 1")
    elif type(ver) is not int:
        err("version", "must be the integer 1")
    elif ver != 1:
        err("version", "unknown version %d; this hs knows version 1" % ver)

    for k, v in data.items():
        if k == "version":
            continue
        if k not in SCHEMA:
            if looks_secret(k) and not isinstance(v, dict):
                err(k, "secrets are never inline; use %s_file" % k)
            else:
                err(k, "unknown key")
            continue
        if not isinstance(v, dict):
            err(k, "must be a table [%s]" % k)
            continue
        for kk, vv in v.items():
            where = "%s.%s" % (k, kk)
            if kk not in SCHEMA[k]:
                if looks_secret(kk) and not isinstance(vv, dict):
                    err(where, "secrets are never inline; use %s_file" % kk)
                else:
                    err(where, "unknown key")
                continue
            want = SCHEMA[k][kk]
            if type(vv) is not want:
                err(where, "must be %s" % ("true or false" if want is bool else "a string"))
            elif want is str and vv == "":
                err(where, "is empty; leave the key out to be asked")

    def val(sect, key):
        v = data.get(sect)
        v = v.get(key) if isinstance(v, dict) else None
        return v if isinstance(v, str) and v != "" else None

    role = val("install", "role")
    if role is not None and role not in ROLES:
        err("install.role", "must be one of " + ", ".join(ROLES))
    disk = val("install", "disk")
    if disk is not None and not DEVICE.match(disk.removeprefix("/dev/")):
        err("install.disk", "is not a device name")
    cdisk = val("install", "confirm_disk")
    if cdisk is not None and disk is None:
        err("install.confirm_disk", "needs install.disk")
    elif cdisk is not None and cdisk != disk:
        err("install.confirm_disk", "must equal install.disk (an unattended run never erases on a guess)")
    if disk is not None and cdisk is None:
        warn("install.confirm_disk", "not set; an unattended run needs install.disk and install.confirm_disk")
    host = val("install", "hostname")
    if host is not None and not LABEL.match(host):
        err("install.hostname", "must be a name of letters, digits and hyphens (1 to 63, not starting or ending with a hyphen)")
    tz = val("install", "timezone")
    if tz is not None:
        if not ZONE.match(tz) or ".." in tz:
            err("install.timezone", "is not a time zone name such as Europe/Vienna")
        else:
            zi = os.environ.get("HS_ZONEINFO_DIR", "/usr/share/zoneinfo")
            if os.path.isdir(zi) and not os.path.isfile(os.path.join(zi, tz)):
                err("install.timezone", "unknown time zone")
    preset = val("install", "preset")
    if preset is not None:
        if not NAME.match(preset):
            err("install.preset", "is not a preset name")
        else:
            pd = os.environ.get("HS_PRESETS_DIR", "")
            if pd and os.path.isdir(pd) and not any(os.path.exists(os.path.join(pd, preset + e)) for e in ("", ".toml", ".nix")):
                err("install.preset", "no such preset")
    nic = val("install", "nic")
    if nic is not None and not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,14}$", nic):
        err("install.nic", "is not an interface name")
    smb = val("install", "smb_allow")
    if smb is not None:
        ok = bool(CIDR.match(smb)) and all(int(p) <= 255 for p in smb.split("/")[0].split(".")) \
            and (("/" not in smb) or int(smb.split("/")[1]) <= 32)
        if not ok:
            err("install.smb_allow", "must be an address or a network such as 192.168.1.0/24")

    key, kfile = val("ssh", "key"), val("ssh", "key_file")
    if key is not None and kfile is not None:
        err("ssh", "give exactly one of key and key_file, not both")
    elif key is not None:
        if "PRIVATE KEY" in key:
            err("ssh.key", "this is a private key; give the public key")
        elif not PUBKEY.match(key):
            err("ssh.key", "is not a public SSH key")
    elif kfile is not None:
        if not os.path.isabs(kfile):
            err("ssh.key_file", "must be an absolute path")
        elif not os.path.isfile(kfile):
            err("ssh.key_file", "file not found")
    else:
        warn("ssh", "no key and no key_file; you are asked for the key")

    pw = val("secrets", "admin_password_file")
    if pw is not None:
        w = "secrets.admin_password_file"
        if not os.path.isabs(pw):
            err(w, "must be an absolute path")
        else:
            try:
                st = os.stat(pw)
            except OSError:
                st = None
            if st is None:
                err(w, "file not found")
            elif not stat.S_ISREG(st.st_mode):
                err(w, "is not a regular file")
            elif st.st_mode & 0o177:
                err(w, "mode is %03o; use 600 (owner only)" % (st.st_mode & 0o777))
            elif st.st_size == 0:
                err(w, "file is empty")

    for lvl, where, text in out:
        sys.stdout.write("%s\t%s\t%s\n" % (lvl, where or "-", text or "-"))
    return 1 if any(o[0] == "error" for o in out) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
