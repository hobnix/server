"""Package repositories for scripts/pkg.py (docs/PLAN-packages.md, "Repositories" and "Trust"). Standard library plus `git`.

A repository is a git repository with `index.toml` at its root and one folder per package. A RELEASE is a tag `v<semver>` signed with an SSH
key; only the newest tag whose signature verifies against the repository's allowed-signers file is ever used (never a branch). The index at
that tag says which package versions the release holds:

    [package.arr]
    version = "1.4.0"
    kind = "recipe"
    path = "recipes/arr"
    requires_core = ">=1"

State, all under <state>/packages (root-owned on the server):
    repos.toml            repositories added by a person (name, url, signers or unsigned)
    keys/<name>.signers   the allowed-signers file of an added repository
    repos/<name>/         the local clone (fetched with --tags)
    current/<name>/       the installed package (read-only copy of the folder at the tag; the loaders read this folder)
    previous/<name>@<commit>/   the one before, kept for a rollback until the next update
    installed.toml        version, repo, commit and tag of every applied package
The two default repositories come from config/package-repos.toml; their allowed signers from config/trusted-keys/<name>.allowed_signers.
"""
import io
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tomllib

TAG = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
REPO_NAME = re.compile(r"^[a-z][a-z0-9-]{0,40}$")


class Refused(Exception):
    """a reason shown to the person, exit 1"""


def git(*args, cwd=None, input=None):
    r = subprocess.run(["git", *args], cwd=cwd, input=input, capture_output=True)
    if r.returncode != 0:
        raise Refused("git %s: %s" % (args[0], r.stderr.decode("utf-8", "replace").strip().splitlines()[-1:] or "failed"))
    return r.stdout


def git_ok(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True).returncode == 0


class Repos:
    def __init__(self, pkg):
        self.pkg = pkg
        self.state = pkg.state_dir()

    # ── the list of repositories ──
    def defaults(self):
        f = os.path.join(self.pkg.root(), "config", "package-repos.toml")
        try:
            with open(f, "rb") as fh:
                return [dict(r, default=True) for r in tomllib.load(fh).get("repo", [])]
        except OSError:
            return []

    def added(self):
        try:
            with open(os.path.join(self.state, "repos.toml"), "rb") as fh:
                return [dict(r, default=False) for r in tomllib.load(fh).get("repo", [])]
        except (OSError, tomllib.TOMLDecodeError):
            return []

    def all(self):
        return {r["name"]: r for r in self.defaults() + self.added()}

    def signers(self, r):
        """path of the allowed-signers file, or None (unsigned repository)"""
        if r.get("unsigned"):
            return None
        if r.get("default"):
            return os.path.join(self.pkg.root(), "config", "trusted-keys", r["name"] + ".allowed_signers")
        return os.path.join(self.state, "keys", r["name"] + ".signers")

    def save_added(self, rows):
        os.makedirs(self.state, exist_ok=True)
        f = os.path.join(self.state, "repos.toml")
        with open(f + ".new", "w", encoding="utf-8") as o:
            for r in rows:
                o.write("[[repo]]\nname = %s\nurl = %s\n" % (self.pkg.q(r["name"]), self.pkg.q(r["url"])))
                if r.get("unsigned"):
                    o.write("unsigned = true\n")
                o.write("\n")
        os.replace(f + ".new", f)

    def add(self, name, url, key=None, unsigned=False):
        if not REPO_NAME.match(name):
            raise Refused("the repository name is a lowercase word")
        if name in self.all():
            raise Refused("a repository called %s exists already" % name)
        if not re.match(r"^(https://|ssh://|git@|file://|/|[A-Za-z]:[\/])", url):
            raise Refused("the address must be https://, ssh://, git@host:path or a local path")
        if bool(key) == bool(unsigned):
            raise Refused("give --key <allowed_signers file> (releases must be signed) or --unsigned")
        if key:
            with open(key, encoding="utf-8") as fh:
                text = fh.read()
            if not re.search(r"(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+|sk-\S+)\s+\S+", text):
                raise Refused("%s holds no SSH public key in allowed-signers format" % key)
            os.makedirs(os.path.join(self.state, "keys"), exist_ok=True)
            shutil.copyfile(key, os.path.join(self.state, "keys", name + ".signers"))
        self.save_added(self.added() + [{"name": name, "url": url, "unsigned": unsigned}])

    def remove(self, name):
        rows = self.added()
        if name not in [r["name"] for r in rows]:
            raise Refused("%s is not a repository that was added (the defaults stay)" % name)
        self.save_added([r for r in rows if r["name"] != name])
        shutil.rmtree(os.path.join(self.state, "repos", name), ignore_errors=True)
        try:
            os.remove(os.path.join(self.state, "keys", name + ".signers"))
        except OSError:
            pass

    # ── git: fetch and verify ──
    def clone_dir(self, name):
        return os.path.join(self.state, "repos", name)

    def fetch(self, r):
        d = self.clone_dir(r["name"])
        if os.path.isdir(os.path.join(d, ".git")) or os.path.isfile(os.path.join(d, "HEAD")):
            git("fetch", "--quiet", "--tags", "--force", "origin", cwd=d)
        else:
            os.makedirs(os.path.dirname(d), exist_ok=True)
            git("clone", "--quiet", "--no-checkout", r["url"], d)
            git("fetch", "--quiet", "--tags", "--force", "origin", cwd=d)

    def tags(self, r):
        d = self.clone_dir(r["name"])
        if not os.path.isdir(d):
            return []
        out = git("tag", "--list", "v*", cwd=d).decode().split()
        return sorted((t for t in out if TAG.match(t)), key=lambda t: tuple(int(x) for x in t[1:].split(".")), reverse=True)

    def verified_tag(self, r):
        """the newest release tag whose signature verifies, as (tag, commit); Refused with the reason when there is none"""
        d = self.clone_dir(r["name"])
        sig = self.signers(r)
        tags = self.tags(r)
        if not tags:
            raise Refused("%s has no release tag (v1.2.3) yet" % r["name"])
        if sig is None:
            t = tags[0]
            return t, git("rev-list", "-n", "1", t, cwd=d).decode().strip()
        if not os.path.isfile(sig):
            raise Refused("%s: no trusted key (%s); the release cannot be verified" % (r["name"], os.path.basename(sig)))
        for t in tags:
            if git_ok("-c", "gpg.format=ssh", "-c", "gpg.ssh.allowedSignersFile=" + sig, "verify-tag", t, cwd=d):
                return t, git("rev-list", "-n", "1", t, cwd=d).decode().strip()
        raise Refused("%s: none of its %d release tags has a valid signature from a trusted key" % (r["name"], len(tags)))

    def index(self, r, tag):
        d = self.clone_dir(r["name"])
        try:
            return tomllib.loads(git("show", tag + ":index.toml", cwd=d).decode("utf-8")).get("package", {})
        except tomllib.TOMLDecodeError as e:
            raise Refused("%s: index.toml is not valid (%s)" % (r["name"], e))

    def fetch_all(self, only=None):
        """-> [(repo, tag, commit, error)] after fetching every repository (or one)"""
        out = []
        for name, r in self.all().items():
            if only and name != only:
                continue
            try:
                self.fetch(r)
                t, c = self.verified_tag(r)
                out.append((name, t, c, ""))
            except Refused as e:
                out.append((name, "", "", str(e)))
        return out

    def catalog(self):
        """{package name: [(repo, entry, tag, commit)]} from the cached clones, newest verified tag each"""
        cat = {}
        for name, r in self.all().items():
            try:
                t, c = self.verified_tag(r)
                for pname, entry in self.index(r, t).items():
                    cat.setdefault(pname, []).append((name, entry, t, c))
            except Refused:
                continue
        return cat

    # ── install ──
    def choose(self, name, repo=None):
        cat = self.catalog().get(name, [])
        if repo:
            cat = [c for c in cat if c[0] == repo]
        if not cat:
            raise Refused("no package %s in the repositories (hs pkg fetch updates them)" % name)
        if len(cat) > 1:
            raise Refused("%s is in %s: name one with --repo (a package name is never shadowed silently)" % (name, ", ".join(c[0] for c in cat)))
        if any(m.get("name") == name and "/current/" not in p.replace("\\", "/") for p, m in self.pkg.manifests()):
            raise Refused("%s is part of this installation already (a built-in package is not replaced by a repository)" % name)
        return cat[0]

    def extract(self, r, tag, path, dest):
        d = self.clone_dir(r["name"])
        if not re.match(r"^[A-Za-z0-9._/-]+$", path) or ".." in path.split("/"):
            raise Refused("%s: the path %r in index.toml is not allowed" % (r["name"], path))
        data = git("archive", "--format=tar", tag + ":" + path, cwd=d)
        os.makedirs(dest)
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            for m in tf.getmembers():
                if not (m.isfile() or m.isdir()) or m.name.startswith("/") or ".." in m.name.split("/"):
                    raise Refused("%s: %s is a link or leaves the folder; refused" % (r["name"], m.name))
            tf.extractall(dest)
        for base, dirs, files in os.walk(dest):      # read-only: nothing a user can write is ever run as root
            for n in files:
                p = os.path.join(base, n)
                os.chmod(p, os.stat(p).st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
        for base, dirs, files in os.walk(dest, topdown=False):
            os.chmod(base, os.stat(base).st_mode & ~(stat.S_IWGRP | stat.S_IWOTH))

    def check_entry(self, name, entry, repo):
        pkg = self.pkg
        path = str(entry.get("path", ""))
        if not re.match(r"^[A-Za-z0-9._/-]+$", path) or ".." in path.split("/"):
            raise Refused("%s: the path %r in index.toml is not allowed" % (repo, path))
        if not pkg.NAME.match(name):
            raise Refused("%s: not a package name" % name)
        rq = pkg.REQUIRES.match(str(entry.get("requires_core", "")))
        if not rq:
            raise Refused('%s: requires_core in the index must look like ">=1"' % name)
        if int(rq.group(1)) > pkg.api_level():
            raise Refused("%s needs core API level %s, this one has %d: hs update first" % (name, rq.group(1), pkg.api_level()))
        if not pkg.SEMVER.match(str(entry.get("version", ""))):
            raise Refused("%s: the version in the index is not semver" % name)

    def install(self, name, repo=None):
        r_name, entry, tag, commit = self.choose(name, repo)
        r = self.all()[r_name]
        self.check_entry(name, entry, r_name)
        cur = os.path.join(self.state, "current", name)
        tmp = os.path.join(self.state, "current", ".new-" + name)
        shutil.rmtree(tmp, ignore_errors=True)
        os.makedirs(os.path.dirname(cur), exist_ok=True)
        self.extract(r, tag, entry["path"], tmp)
        with open(os.path.join(tmp, "package.toml"), "rb") as fh:
            m = tomllib.load(fh)
        if m.get("name") != name or m.get("version") != entry["version"]:
            shutil.rmtree(tmp, ignore_errors=True)
            raise Refused("%s: package.toml (name %s, version %s) does not match the index (%s)" % (name, m.get("name"), m.get("version"), entry["version"]))
        old = self.pkg.installed().get(name, {})
        if os.path.isdir(cur):
            prev = os.path.join(self.state, "previous")
            os.makedirs(prev, exist_ok=True)
            for x in os.listdir(prev):
                if x.startswith(name + "@"):
                    self.rm(os.path.join(prev, x))
            os.rename(cur, os.path.join(prev, "%s@%s" % (name, old.get("commit", "unknown")[:12])))
        os.rename(tmp, cur)
        data = self.pkg.installed()
        data[name] = {"version": entry["version"], "repo": r_name, "commit": commit, "tag": tag}
        self.pkg.save_installed(data)
        return entry["version"], r_name, tag

    @staticmethod
    def rm(path):
        def onerr(fn, p, _):
            os.chmod(p, stat.S_IRWXU)
            fn(p)
        shutil.rmtree(path, onerror=onerr)

    def remove_package(self, name):
        data = self.pkg.installed()
        if "repo" not in data.get(name, {}):
            raise Refused("%s was not installed from a repository" % name)
        self.rm(os.path.join(self.state, "current", name))
        del data[name]
        self.pkg.save_installed(data)

    # ── update ──
    def diff(self, name):
        """-> (old commit, new tag, new commit, diff text) or None when the installed package is current"""
        have = self.pkg.installed().get(name, {})
        if "repo" not in have:
            raise Refused("%s was not installed from a repository" % name)
        r_name, entry, tag, commit = self.choose_installed(name, have["repo"])
        self.check_entry(name, entry, r_name)
        if commit == have.get("commit") or not self.pkg.semver_key(entry["version"]) > self.pkg.semver_key(have["version"]):
            return None
        d = self.clone_dir(r_name)
        text = git("diff", "--stat", "-p", have["commit"], commit, "--", entry["path"], cwd=d).decode("utf-8", "replace")
        return have["commit"], tag, commit, text

    def choose_installed(self, name, repo):
        cat = [c for c in self.catalog().get(name, []) if c[0] == repo]
        if not cat:
            raise Refused("%s is not in %s any more" % (name, repo))
        return cat[0]


def run(pkg, cmd, rest):
    """the commands of pkg.py that need a repository; returns the exit code"""
    R = Repos(pkg)
    try:
        if cmd == "repo":
            sub = rest[0] if rest else "list"
            if sub == "list":
                for n, r in R.all().items():
                    print("\t".join([n, r["url"], "unsigned" if r.get("unsigned") else "signed", "default" if r.get("default") else "added"]))
            elif sub == "add":
                key = rest[rest.index("--key") + 1] if "--key" in rest else None
                R.add(rest[1], rest[2], key=key, unsigned="--unsigned" in rest)
            elif sub == "remove":
                R.remove(rest[1])
            else:
                raise Refused("repo list | add <name> <url> (--key <file> | --unsigned) | remove <name>")
        elif cmd == "fetch":
            bad = 0
            for name, tag, commit, err in R.fetch_all(rest[0] if rest else None):
                print("\t".join([name, tag or "-", commit[:12] or "-", err or "ok"]))
                bad += bool(err)
            return 1 if bad else 0
        elif cmd == "available":
            have = pkg.installed()
            for pname, rows in sorted(R.catalog().items()):
                for r_name, e, tag, _ in rows:
                    print("\t".join([r_name, pname, e.get("kind", "?"), str(e.get("version")), have.get(pname, {}).get("version", "-")]))
        elif cmd == "market":
            # everything a person can install, as data (hs sys pkg market): package, kind, repository, available version, installed version
            # (- = no copy in current/), state (new|current|update|orphan), core (yes|no), audience, title. A package of a repository that
            # is gone (or no longer lists it) is an orphan: its copy stays until `hs pkg remove`.
            have = pkg.installed()
            cur = os.path.join(R.state, "current")
            seen = set()
            for pname, rows in sorted(R.catalog().items()):
                for r_name, e, tag, _ in rows:
                    ver = str(e.get("version"))
                    inst = "-"
                    if os.path.isdir(os.path.join(cur, pname)):
                        inst = str(have.get(pname, {}).get("version", "?"))
                    if inst == "-":
                        state = "new"
                    elif inst == ver:
                        state = "current"
                    else:
                        try:
                            state = "update" if pkg.semver_key(ver) > pkg.semver_key(inst) else "current"
                        except ValueError:
                            state = "update"
                    seen.add(pname)
                    print("	".join([pname, e.get("kind", "?"), r_name, ver, inst, state, "yes" if e.get("core") else "no",
                                     e.get("audience", "generic"), (e.get("title") or "-").replace("	", " ")]))
            if os.path.isdir(cur):
                for pname in sorted(os.listdir(cur)):
                    if pname in seen or pname.startswith("."):
                        continue
                    print("	".join([pname, "?", have.get(pname, {}).get("repo", "-"), "-", str(have.get(pname, {}).get("version", "?")), "orphan", "no", "-", "-"]))
        elif cmd == "install" and rest and rest[0] == "--core":
            # the packages the core refers to by name (`core = true` in the index) and the ones applied here: fetch what is neither built in nor installed yet
            bad = 0
            for name, tag, commit, err in R.fetch_all():
                bad += bool(err)
                if err:
                    print("%s: %s" % (name, err), file=sys.stderr)
            # wanted: the core packages and every recipe already applied on this server (installed.toml also holds the versions `hs recipe`
            # recorded before packages came from a repository); there: its folder in current/ or a built-in one
            applied = pkg.installed()
            builtin = {m.get("name") for p, m in pkg.manifests() if "/current/" not in p.replace("\\", "/")}
            for pname, rows in sorted(R.catalog().items()):
                there = os.path.isdir(os.path.join(R.state, "current", pname)) or pname in builtin
                if there or not (rows[0][1].get("core") or pname in applied):
                    continue
                try:
                    v, r_name, tag = R.install(pname, rows[0][0])
                    print("%s %s from %s (%s)" % (pname, v, r_name, tag))
                except Refused as e:
                    bad += 1
                    print("%s: %s" % (pname, e), file=sys.stderr)
            return 1 if bad else 0
        elif cmd == "install":
            repo = rest[rest.index("--repo") + 1] if "--repo" in rest else None
            v, r_name, tag = R.install(rest[0], repo)
            print("%s %s from %s (%s)" % (rest[0], v, r_name, tag))
        elif cmd == "update":
            res = R.diff(rest[0])
            if res is None:
                print("current")
                return 0
            old, tag, commit, text = res
            print(text)
            if "--yes" not in rest:
                if not sys.stdin.isatty():
                    raise Refused("an update changes code that runs as root: read the diff above and run again with --yes")
                if input("Install %s? [y/N] " % tag).strip().lower() not in ("y", "yes"):
                    raise Refused("not installed")
            v, r_name, tag = R.install(rest[0], pkg.installed()[rest[0]]["repo"])
            print("%s %s from %s (%s)" % (rest[0], v, r_name, tag))
        elif cmd == "remove":
            R.remove_package(rest[0])
        else:
            return 2
    except Refused as e:
        print(str(e), file=sys.stderr)
        return 1
    except IndexError:
        print("missing argument", file=sys.stderr)
        return 1
    return 0
