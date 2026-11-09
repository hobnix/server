// GENERATED from docs/api/openapi.json by scripts/openapi-ts-gen.py: never edit by hand.
// Regenerate: python3 scripts/openapi-ts-gen.py write (in the same commit as a change to docs/api/openapi.json).
// Use through JSDoc, e.g. @param {import('./api/sys.gen').SysLines<'live.status'>} rows

/** one tab-separated field; an empty value is written - */
export type Field = string;

export type ChangeLines = ([tag: "status", field: "done" | "needs" | "ok" | "refused" | "started"]
  | [tag: "reason", field: Field]
  | [tag: "heading", field: Field]
  | [tag: "needs", field: Field]
  | [tag: "step", field: Field]
  | [tag: "note", field: Field]
  | [tag: "warn", field: Field]
  | [tag: "danger", field: Field]
  | [tag: "section", field: Field]
  | [tag: "text", field: Field]
  | [tag: "command", field: Field]
  | [tag: "confirm_name", field: Field]
  | [tag: "long", field: "yes" | "no"]
  | [tag: "option", field: Field]
  | [tag: "fix", field: Field]
  | [tag: "unit", field: Field]
  | [tag: "id", field: Field]
  | [field: string, field2: Field])[];

/** Every `hs sys` operation by operationId: its words, URL path, the shape of stdout lines and the exit codes. */
export interface SysOperations {
  "admin.plan.by_action": {
    /** what a test push message, pinning the MACs, moving the upload cache or cleaning the fans would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused) */
    words: ["admin", "plan", "<action>"];
    path: "/admin/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "admin.start.by_action": {
    /** do it (hs sys admin start test-push | pin-macs | cache-mover | fans-clean [--seconds N]); the first two answer done, the others start a job */
    words: ["admin", "start", "<action>"];
    path: "/admin/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "audit": {
    /** who did what: the commands that changed the server; id, time (epoch seconds), actor, result ok|failed, exit, command (hs sys audit [N]) */
    words: ["audit"];
    path: "/audit";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: ([id: Field, time: Field, actor: Field, result: "ok" | "failed", exit: Field, command: Field])[];
  };
  "backup.find.by_word": {
    /** files whose name contains a word, in every snapshot, as data: snapshot, time, path, type, bytes (at most 200; mounts the backup disk, can take a while) */
    words: ["backup", "find", "<word>"];
    path: "/backup/find/{word}";
    method: "get";
    class: "read";
    params: { word: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "backup.overview": {
    /** every share, instance and always-included part with its backup switch and size */
    words: ["backup", "overview"];
    path: "/backup/overview";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "backup.plan.by_action": {
    /** what switching a share or instance, backing up now, a check, a restore drill or browsing would do, as data: status and plan lines (never asks; exit 0 ok, 1 refused, 2 something missing) */
    words: ["backup", "plan", "<action>"];
    path: "/backup/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "backup.scheduled": {
    /** nightly backup (systemd) */
    words: ["backup", "scheduled"];
    path: "/backup/scheduled";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "backup.shares": {
    /** shares and containers with their backup switch */
    words: ["backup", "shares"];
    path: "/backup/shares";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "backup.snapshots": {
    /** the snapshots of the shares in the backup (id, time, tags) */
    words: ["backup", "snapshots"];
    path: "/backup/snapshots";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "backup.snapshots.by_tag": {
    /** the snapshots with one tag (shares, host or ct:<name>) */
    words: ["backup", "snapshots", "<tag>"];
    path: "/backup/snapshots/{tag}";
    method: "get";
    class: "read";
    params: { tag: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "backup.start.by_action": {
    /** do it as a background job (hs sys backup start toggle --name <n> --kind shares|sensitive|ct --to on|off | now | verify | drill [--count N] | browse --to on|off) */
    words: ["backup", "start", "<action>"];
    path: "/backup/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "backup.state": {
    /** backup state as key and value */
    words: ["backup", "state"];
    path: "/backup/state";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "cache.state": {
    /** upload cache state per share */
    words: ["cache", "state"];
    path: "/cache/state";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "changes.list": {
    /** the changelog as data: one range line (range, base, head, mode update|from|since|all|newest), then entry lines (entry, id, date, type, title, docs, body; empty = -); options --from <rev> | --since <date> | --all */
    words: ["changes", "list"];
    path: "/changes/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "complete": {
    /** completion candidates for the shell */
    words: ["complete"];
    path: "/complete";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "config.check": {
    /** the result of hs config check as plain text */
    words: ["config", "check"];
    path: "/config/check";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "config.list": {
    /** every option of machine.toml.example: section, key, current value, default, type, help, settable (secrets only as (set)) */
    words: ["config", "list"];
    path: "/config/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "config.plan.by_action": {
    /** what changing a setting of machine.toml would do, as data: status and plan lines (never asks; exit 0 ok, 1 refused) */
    words: ["config", "plan", "<action>"];
    path: "/config/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "config.start.by_action": {
    /** do it (hs sys config start set <key> <value>); the file is checked and put back when the check fails */
    words: ["config", "start", "<action>"];
    path: "/config/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "ct.bindings.by_ct": {
    /** the storage of an instance with pool, disks, size, backup, cache and who else mounts it */
    words: ["ct", "bindings", "<ct>"];
    path: "/ct/bindings/{ct}";
    method: "get";
    class: "read";
    params: { ct: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "ct.list": {
    /** instances with state and address */
    words: ["ct", "list"];
    path: "/ct/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: [name: Field, type: Field, state: Field, address: Field, ram: Field, cpu: Field, autostart: Field, mac_pinned: Field, docker: Field, disk: Field, snapshots: Field, last_snapshot: Field, memory_in_use: Field, cpu_time: Field, bindings: Field, last_start_utc: Field, owner: Field][];
  };
  "ct.logs.by_ct": {
    /** the last lines of the journal inside an instance (hs sys ct logs <ct> [lines]) */
    words: ["ct", "logs", "<ct>"];
    path: "/ct/logs/{ct}";
    method: "get";
    class: "read";
    params: { ct: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "ct.plan.by_ct.by_action": {
    /** what a change of an instance would do, as data: status, plan lines, confirm_name (never asks; exit 2 = something is missing) */
    words: ["ct", "plan", "<ct>", "<action>"];
    path: "/ct/plan/{ct}/{action}";
    method: "post";
    class: "plan";
    params: { ct: string; action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "ct.pools": {
    /** the Incus storage pools to put a disk on: name, driver, kind (fast|bulk|other), free bytes, total bytes, source (- when unknown) */
    words: ["ct", "pools"];
    path: "/ct/pools";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "ct.profiles": {
    /** network profiles an instance can be created on: name, network, description */
    words: ["ct", "profiles"];
    path: "/ct/profiles";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "ct.snapshots": {
    /** snapshots of an instance */
    words: ["ct", "snapshots"];
    path: "/ct/snapshots";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "ct.snapshots.by_ct": {
    /** snapshots of one instance */
    words: ["ct", "snapshots", "<ct>"];
    path: "/ct/snapshots/{ct}";
    method: "get";
    class: "read";
    params: { ct: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "ct.start.by_ct.by_action": {
    /** do a change of an instance as a background job; needs --confirm <name> when the plan has a danger line */
    words: ["ct", "start", "<ct>", "<action>"];
    path: "/ct/start/{ct}/{action}";
    method: "post";
    class: "start";
    params: { ct: string; action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "ct.storage": {
    /** storage of an instance */
    words: ["ct", "storage"];
    path: "/ct/storage";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "ct.storage.by_ct": {
    /** storage of one instance */
    words: ["ct", "storage", "<ct>"];
    path: "/ct/storage/{ct}";
    method: "get";
    class: "read";
    params: { ct: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "ct.users": {
    /** users inside an instance */
    words: ["ct", "users"];
    path: "/ct/users";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "ct.users.by_ct": {
    /** users inside one instance */
    words: ["ct", "users", "<ct>"];
    path: "/ct/users/{ct}";
    method: "get";
    class: "read";
    params: { ct: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "dc.plan.by_action": {
    /** what making the CA or renewing the certificate of the domain controller would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused) */
    words: ["dc", "plan", "<action>"];
    path: "/dc/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "dc.start.by_action": {
    /** do it (hs sys dc start ca | renew [--dc <instance>] --confirm <instance>); ca answers done, renew starts a job */
    words: ["dc", "start", "<action>"];
    path: "/dc/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "dc.state": {
    /** the CA of this setup and the certificate of the domain controller as key and value lines: ca, ca_until, dc, cert, subject, names, valid_until, days_left, checked */
    words: ["dc", "state"];
    path: "/dc/state";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "deck": {
    /** one JSON document with the numbers for a status display (network and cpu counters, pools, disks, backup, problems, instances) */
    words: ["deck"];
    path: "/deck";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: unknown;
  };
  "disk-health.list": {
    /** SMART findings per disk */
    words: ["disk-health", "list"];
    path: "/disk-health/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "disk.event.by_action.by_name": {
    /** a disk was plugged in or taken out (udev, hs-disk-event@.service): log it, push a message, never touch the disk */
    words: ["disk", "event", "<action>", "<name>"];
    path: "/disk/event/{action}/{name}";
    method: "post";
    class: "change";
    params: { action: string; name: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "disk.ls.by_member": {
    /** one folder level of a data disk (type d|f, bytes, name; --path shares/...), for the move dialog */
    words: ["disk", "ls", "<member>"];
    path: "/disk/ls/{member}";
    method: "get";
    class: "read";
    params: { member: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "disk.marks": {
    /** data disks that are out of the pool by hand: member, detached|recovering, since (epoch seconds); for the Pool page */
    words: ["disk", "marks"];
    path: "/disk/marks";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "disk.plan.by_disk.by_action": {
    /** what a self-test of a disk, or erasing a free disk (wipe), or mounting, copying from or ejecting another disk (temp-mount, temp-copy, temp-eject), would do, as data: status, plan lines (never asks; exit 1 = refused: unknown disk or a test running already) */
    words: ["disk", "plan", "<disk>", "<action>"];
    path: "/disk/plan/{disk}/{action}";
    method: "post";
    class: "plan";
    params: { disk: string; action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "disk.results.by_disk": {
    /** outcome of the last self-tests of a disk */
    words: ["disk", "results", "<disk>"];
    path: "/disk/results/{disk}";
    method: "get";
    class: "read";
    params: { disk: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "disk.start.by_disk.by_action": {
    /** start the self-test inside the disk: hs sys disk start <disk> test short|long (status done, the disk reports the outcome) */
    words: ["disk", "start", "<disk>", "<action>"];
    path: "/disk/start/{disk}/{action}";
    method: "post";
    class: "start";
    params: { disk: string; action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "disk.test.by_disk": {
    /** start a self-test inside a disk: sys disk test <disk> short|long */
    words: ["disk", "test", "<disk>"];
    path: "/disk/test/{disk}";
    method: "post";
    class: "change";
    params: { disk: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "dns.list": {
    /** the DNS names of the instances in the zone, no header: name, type, value */
    words: ["dns", "list"];
    path: "/dns/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "docker-app.plan.by_app.by_action": {
    /** what starting, stopping, restarting, pulling, saving, rebuilding, recreating or deleting an app in Docker would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused with a reason); app-save and app-write (the files only) take --rev new|<rev> with document stdin and print `finding<TAB>level<TAB>where<TAB>text` lines (the editor's Test); delete confirms by name */
    words: ["docker-app", "plan", "<app>", "<action>"];
    path: "/docker-app/plan/{app}/{action}";
    method: "post";
    class: "plan";
    params: { app: string; action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "docker-app.start.by_app.by_action": {
    /** do it (hs sys docker-app start <app> start|stop|restart|pull|app-save|app-write|rebuild|recreate|delete); app-save/app-write need --rev and document stdin, rebuild runs docker compose up --build --pull always, recreate runs docker compose up -d only, delete snapshots docker first */
    words: ["docker-app", "start", "<app>", "<action>"];
    path: "/docker-app/start/{app}/{action}";
    method: "post";
    class: "start";
    params: { app: string; action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "docker-registry.plan.by_action": {
    /** what adding or removing a registry login would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused with a reason and a fix when the vault is closed) */
    words: ["docker-registry", "plan", "<action>"];
    path: "/docker-registry/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "docker-registry.start.by_action": {
    /** do it (hs sys docker-registry start add <host> --user <u> | remove <host> --confirm <host>); the token of add is the one stdin line */
    words: ["docker-registry", "start", "<action>"];
    path: "/docker-registry/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "docker.app.by_app": {
    /** the app as JSON: rev, managed (web|recipe|other), env NAMES only, compose text (no env values; compose may hold secrets) */
    words: ["docker", "app", "<app>"];
    path: "/docker/app/{app}";
    method: "get";
    class: "read";
    params: { app: string; };
    stdin: "none";
    exit: number;
    lines: unknown;
  };
  "docker.apps": {
    /** the apps in Docker as name, parent, project, state, running/total, ports, address, images, managed, update, files (same|changed|new|invalid|-; - when empty; kind unmanaged = a container without a compose project; no row when Docker is off or does not answer) */
    words: ["docker", "apps"];
    path: "/docker/apps";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "docker.containers": {
    /** every container in Docker as name, project, state (- when empty; no row when Docker is off or does not answer): the editor checks container_name against it */
    words: ["docker", "containers"];
    path: "/docker/containers";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "docker.health": {
    /** the checks of the Docker capability page as id, state (ok|warn|fail|off), fix, detail, reason (- when empty): container, share (apps on the SSD pool), mount (apps mounted in Docker) */
    words: ["docker", "health"];
    path: "/docker/health";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "docker.list": {
    /** the apps in Docker as name, parent, project, state, ports (- when empty; no row when Docker is off or does not answer) */
    words: ["docker", "list"];
    path: "/docker/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "docker.logs.by_app": {
    /** the Compose log of one app: name parent project state ports, then log lines (--tail 200 by default, up to 2000) */
    words: ["docker", "logs", "<app>"];
    path: "/docker/logs/{app}";
    method: "post";
    class: "change";
    params: { app: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "docker.mount": {
    /** give the locked container docker a folder, the only route (hs sys docker mount <share> <path> --as <uid>:<gid> | remote:<peer> <path>) [--yes] [--dry-run]: a local share restarts the container and every app in it */
    words: ["docker", "mount"];
    path: "/docker/mount";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "docker.plan.by_action": {
    /** what turning Docker on (hs sys docker plan setup --set dockerManager=webui --set dockerSize=m) or giving it a folder (hs sys docker plan mount <share|remote:peer> --path /shares/<share> [--as uid:gid]) or moving the apps (plan move-apps) would do, as data: status, plan lines (never changes anything; exit 0 ok, 1 refused with a reason) */
    words: ["docker", "plan", "<action>"];
    path: "/docker/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "docker.registries": {
    /** the registry logins as host, user, state (ok|locked|missing), used_by (apps, comma; - when none or empty; no token is ever printed) */
    words: ["docker", "registries"];
    path: "/docker/registries";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "docker.rev.by_app": {
    /** the revision of the compose file and .env of one app, one line (what hs sys docker app prints as rev): the open editor polls it for "changed on disk" */
    words: ["docker", "rev", "<app>"];
    path: "/docker/rev/{app}";
    method: "get";
    class: "read";
    params: { app: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "docker.start.by_action": {
    /** do it (hs sys docker start setup --set key=value ... | mount <share|remote:peer> --path <p> [--as uid:gid] | move-apps): hs docker enable, hs docker mount and hs docker move-apps run as a background job (status started, unit) */
    words: ["docker", "start", "<action>"];
    path: "/docker/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "docker.status": {
    /** Docker as key<TAB>value: state, instance, owned, running, manager, size, memory, cpus, children, address, mapped (the one user mapped onto the share owner as uid:gid, - when none) (- when empty) */
    words: ["docker", "status"];
    path: "/docker/status";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "edge.status": {
    /** the status document of an edge node (public VPS) as one JSON object: mail queue, watcher, ports, certificate, Tailscale, system */
    words: ["edge", "status"];
    path: "/edge/status";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "encryption.list": {
    /** the encrypted volumes of this server: type (vault|luks|zfs), device, state (open|locked|unmanaged), size (tab separated; other people's disks are not listed) */
    words: ["encryption", "list"];
    path: "/encryption/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "event.list": {
    /** the event log: id, time (epoch seconds), source, kind, subject, level info|warn|error, text, payload (JSON or -); hs sys event list [N] [--source S] [--after ID] */
    words: ["event", "list"];
    path: "/event/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: ([id: Field, time: Field, source: Field, kind: Field, subject: Field, level: "info" | "warn" | "error", text: Field, payload: Field])[];
  };
  "expiry.list": {
    /** entries as name, date, days left, state (ok|soon|due|expired|invalid), how to renew */
    words: ["expiry", "list"];
    path: "/expiry/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "expiry.plan.by_action": {
    /** what adding or removing an expiry entry would do, as data: status, plan lines (never asks; exit 2 = the date is missing) */
    words: ["expiry", "plan", "<action>"];
    path: "/expiry/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "expiry.start.by_action": {
    /** do it (hs sys expiry start add <name> --date YYYY-MM-DD [--renew <text>] | remove <name>), answers status done */
    words: ["expiry", "start", "<action>"];
    path: "/expiry/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "ext.list": {
    /** extension packages as name, on|off, commands, nix (yes = a rebuild switches it), title */
    words: ["ext", "list"];
    path: "/ext/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "fm.locations": {
    /** file manager: the places a pane can show (disks of the array, pools, upload cache, shares, temporary disks) as loc rows: id, kind, label, filesystem, size, free, writable, reason, pool, disk */
    words: ["fm", "locations"];
    path: "/fm/locations";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "fm.ls.by_location": {
    /** file manager: one page of a folder: row lines (type d|f|l, bytes, mtime, name, disks, flags, busy), then cursor or end; --path, --cursor, --limit */
    words: ["fm", "ls", "<location>"];
    path: "/fm/ls/{location}";
    method: "get";
    class: "read";
    params: { location: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "fm.pair.by_left.by_right": {
    /** file manager: may these two places be the two sides of a copy or move? status ok, or refused with the reason (a pool disk and the pool of its array show the same files) */
    words: ["fm", "pair", "<left>", "<right>"];
    path: "/fm/pair/{left}/{right}";
    method: "get";
    class: "read";
    params: { left: string; right: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "fm.plan.by_op": {
    /** file manager: what copy|move|delete|rename|mkdir would do, as data (status, heading, step, note, warn, files, folders, bytes, free_after, conflicts, parity, confirm_name, long); the selection comes on stdin, NUL separated; --conflicts lists the conflicts; never asks */
    words: ["fm", "plan", "<op>"];
    path: "/fm/plan/{op}";
    method: "post";
    class: "plan";
    params: { op: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "fm.progress.by_unit": {
    /** file manager: state of a copy/move/delete job (files and bytes done and total, speed, eta, current, phase, result, skipped, failed); stop it with sys jobs stop <unit> */
    words: ["fm", "progress", "<unit>"];
    path: "/fm/progress/{unit}";
    method: "get";
    class: "read";
    params: { unit: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "fm.start.by_op": {
    /** file manager: do it as a background job (status done + unit); delete and an overwrite choice need --confirm <confirm_name> from the plan */
    words: ["fm", "start", "<op>"];
    path: "/fm/start/{op}";
    method: "post";
    class: "start";
    params: { op: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "gateway.certs": {
    /** the certificate of each directly served host as host, state (staging|default|none|ok), valid until (- when empty) */
    words: ["gateway", "certs"];
    path: "/gateway/certs";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "gateway.health": {
    /** the gateway checks as id, state (ok|warn|fail|off), fix step, detail, reason (- when empty) */
    words: ["gateway", "health"];
    path: "/gateway/health";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "gateway.plan.by_action": {
    /** what changing the gateway setup (hs sys gateway plan setup --set key=value ...) would do, as data: status, plan lines, confirm_name for an opened port (never asks; exit 0 ok, 1 refused) */
    words: ["gateway", "plan", "<action>"];
    path: "/gateway/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "gateway.routes": {
    /** the routes as kind, host, path, target, file (- when empty) */
    words: ["gateway", "routes"];
    path: "/gateway/routes";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "gateway.start.by_action": {
    /** do it (hs sys gateway start setup --set key=value ... [--confirm <port>]): the files are checked and put back when the check fails, then hs rebuild runs as a job (status started, unit) */
    words: ["gateway", "start", "<action>"];
    path: "/gateway/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "gateway.status": {
    /** the gateway proxy as key<TAB>value: service, port80, public ports, domain, wildcard, counts, webui, direct */
    words: ["gateway", "status"];
    path: "/gateway/status";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "hardware": {
    /** the processor and the board's sensors: cpu-model, cpu-cores, cpu-threads, temp and fan rows (read only, no root) */
    words: ["hardware"];
    path: "/hardware";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "health.dry-run": {
    /** current problems, nothing is sent */
    words: ["health", "dry-run"];
    path: "/health/dry-run";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "health.list": {
    /** every problem as id, text, acked or - (acknowledged: hs health ack), since (epoch seconds), channels that took the last message (comma separated or -) */
    words: ["health", "list"];
    path: "/health/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "health.next": {
    /** problems with their fix command (problem, next) */
    words: ["health", "next"];
    path: "/health/next";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "health.plan.by_action": {
    /** what acknowledging a problem, taking it back or lifting the pause of the bulk jobs would do, as data: status, plan lines (never asks) */
    words: ["health", "plan", "<action>"];
    path: "/health/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "health.start.by_action": {
    /** do it (hs sys health start ack <id> | unack <id> | resume), answers status done */
    words: ["health", "start", "<action>"];
    path: "/health/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "incident.plan.by_action": {
    /** what pausing the writing apps (pause) or letting them run again (resume) would do, as data (never asks; exit 1 = refused) */
    words: ["incident", "plan", "<action>"];
    path: "/incident/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "incident.start.by_action": {
    /** do it: hs sys incident start pause|resume (status done) */
    words: ["incident", "start", "<action>"];
    path: "/incident/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "incident.state": {
    /** the storage incident as lines: incident, member, target, share, app, progress, paused, free, phase, step, next (or one ok line); for the Incident page */
    words: ["incident", "state"];
    path: "/incident/state";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: ([tag: "ok", scope: Field, text: Field]
      | [tag: "incident", id: Field, pool: Field, kind: "pool-degraded" | "member-down" | "disk-failing", severity: "warn" | "error", text: Field]
      | [tag: "member", pool: Field, name: Field, state: Field, group: Field, disk: Field, why: Field]
      | [tag: "target", pool: Field, member: Field, dev: Field, disk: Field]
      | [tag: "share", pool: Field, name: Field, path: Field, impact: "unavailable" | "at-risk"]
      | [tag: "app", pool: Field, name: Field, state: Field, via: Field, writes: "yes" | "no"]
      | [tag: "progress", pool: Field, kind: "resilver" | "rebuild", percent: Field, text: Field]
      | [tag: "paused", paused: "yes" | "no", instances: Field]
      | [tag: "free", disk: Field, bytes: Field, role: Field]
      | [tag: "phase", pool: Field, phase: "detect" | "ready" | "running"]
      | [tag: "step", n: Field, state: "done" | "now" | "todo" | "optional", title: Field]
      | [tag: "next", command: Field, text: Field])[];
  };
  "iso.dir": {
    /** the folder of the library (setting isoDir) */
    words: ["iso", "dir"];
    path: "/iso/dir";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "iso.list": {
    /** images as name, bytes, algo, checksum, checked (yes|no), source, added, used by (instances or -) */
    words: ["iso", "list"];
    path: "/iso/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "iso.plan.by_action": {
    /** what adding or removing an image would do, as data: status, plan lines (never asks; exit 2 = the checksum is missing) */
    words: ["iso", "plan", "<action>"];
    path: "/iso/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "iso.start.by_action": {
    /** do it (hs sys iso start add <file-or-url> (--checksum <hex> | --no-checksum) [--name <n>] | remove <name> --confirm <n>); add answers status started and the unit, remove status done */
    words: ["iso", "start", "<action>"];
    path: "/iso/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "jobs.children.by_id": {
    /** the sub-jobs of an orchestration job (ADR 0018), oldest first, the columns of jobs records; empty: none */
    words: ["jobs", "children", "<id>"];
    path: "/jobs/children/{id}";
    method: "get";
    class: "read";
    params: { id: string; };
    stdin: "none";
    exit: number;
    lines: ([id: Field, slug: Field, description: Field, state: "queued" | "running" | "waiting" | "ok" | "failed" | "cancelled" | "interrupted", queued: Field, started: Field, ended: Field, exit: Field, step_n: Field, step_of: Field, step_text: Field, progress_done: Field, progress_total: Field, progress_unit: Field])[];
  };
  "jobs.list": {
    /** timers and services with next and last run */
    words: ["jobs", "list"];
    path: "/jobs/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: ([unit: Field, description: Field, next: Field, last: Field, result: "ok" | "failed" | "never"])[];
  };
  "jobs.log.by_unit": {
    /** the last journal lines of one job, plain (hs sys jobs log <unit> [N]) */
    words: ["jobs", "log", "<unit>"];
    path: "/jobs/log/{unit}";
    method: "get";
    class: "read";
    params: { unit: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "jobs.plan.by_action": {
    /** what stopping a running job or running a scheduled one now would do, as data: status and plan lines (never asks; exit 0 ok, 1 refused) */
    words: ["jobs", "plan", "<action>"];
    path: "/jobs/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "jobs.record.by_id": {
    /** one job record as JSON (ADR 0004): state, step, progress, times, exit, error, result */
    words: ["jobs", "record", "<id>"];
    path: "/jobs/record/{id}";
    method: "get";
    class: "read";
    params: { id: string; };
    stdin: "none";
    exit: number;
    lines: unknown;
  };
  "jobs.records": {
    /** the job records, newest first, tab separated (hs sys jobs records [--state S] [N], N up to 500, default 50) */
    words: ["jobs", "records"];
    path: "/jobs/records";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: ([id: Field, slug: Field, description: Field, state: "queued" | "running" | "waiting" | "ok" | "failed" | "cancelled" | "interrupted", queued: Field, started: Field, ended: Field, exit: Field, step_n: Field, step_of: Field, step_text: Field, progress_done: Field, progress_total: Field, progress_unit: Field])[];
  };
  "jobs.running": {
    /** background jobs that are running now */
    words: ["jobs", "running"];
    path: "/jobs/running";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: [unit: Field, description: Field, started: Field][];
  };
  "jobs.show.by_unit": {
    /** the facts of one job: description, state, exit status, started, last and next run, command */
    words: ["jobs", "show", "<unit>"];
    path: "/jobs/show/{unit}";
    method: "get";
    class: "read";
    params: { unit: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "jobs.start.by_action": {
    /** do it (hs sys jobs start stop <unit> [--confirm stop] | run <unit>); run prints the unit to follow */
    words: ["jobs", "start", "<action>"];
    path: "/jobs/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "jobs.stop.by_unit": {
    /** stop a running background job */
    words: ["jobs", "stop", "<unit>"];
    path: "/jobs/stop/{unit}";
    method: "post";
    class: "change";
    params: { unit: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "jobs.tail.by_unit": {
    /** state and new journal lines of a job since line N (state, exit, line, next) */
    words: ["jobs", "tail", "<unit>"];
    path: "/jobs/tail/{unit}";
    method: "get";
    class: "read";
    params: { unit: string; };
    stdin: "none";
    exit: number;
    lines: ([tag: "state", state: "running" | "ok" | "failed" | "unknown"]
      | [tag: "exit", status: Field]
      | [tag: "line", text: Field]
      | [tag: "next", count: Field])[];
  };
  "live.check": {
    /** problems of the live state (Redis down, a topic older than three intervals): key and text */
    words: ["live", "check"];
    path: "/live/check";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "live.inspect": {
    /** every live-state topic as JSON for the inspector page: words, interval, lock, origin, capability, groups, age, gen, exit code, error, error time, bytes (needs, status, ttl only when known) */
    words: ["live", "inspect"];
    path: "/live/inspect";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: unknown;
  };
  "live.raw.by_topic": {
    /** the stored document of one live-state topic as JSON, the output capped at 64 KiB */
    words: ["live", "raw", "<topic>"];
    path: "/live/raw/{topic}";
    method: "get";
    class: "read";
    params: { topic: string; };
    stdin: "none";
    exit: number;
    lines: unknown;
  };
  "live.refresh": {
    /** ask the live-state collector to read these topics again now (--all: every topic); returns at once */
    words: ["live", "refresh"];
    path: "/live/refresh";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "live.status": {
    /** every live-state topic: topic, interval, age in seconds (-1 = none), generation, exit code, error, error time, needs (comma list of topics, - = none), status (fresh|stale|error|expired, - = no document) */
    words: ["live", "status"];
    path: "/live/status";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "logs.show": {
    /** the journal as plain lines: hs sys logs show [--unit <key>] [--level err|warning|info] [--since 1h|today|boot] [--lines <N>] */
    words: ["logs", "show"];
    path: "/logs/show";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "logs.units": {
    /** what the journal can be filtered by (key and label) */
    words: ["logs", "units"];
    path: "/logs/units";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "monitor.disks": {
    /** disk table of the overview */
    words: ["monitor", "disks"];
    path: "/monitor/disks";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "motd.status": {
    /** the three status lines (problems, last backup, system) as plain text, no root (for tools such as homeserver-cli) */
    words: ["motd", "status"];
    path: "/motd/status";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "net.nics": {
    /** the physical network cards: name, link (up|down), MAC (- = none), current (yes = the nic of machine.toml; listed first) */
    words: ["net", "nics"];
    path: "/net/nics";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "net.plan.by_action": {
    /** what connecting the router would do, as data: status, plan lines (never asks; the API key is the first line on standard input; exit 0 ok, 1 refused, 2 = address or key missing) */
    words: ["net", "plan", "<action>"];
    path: "/net/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "net.start.by_action": {
    /** do it (hs sys net start setup --address <url>, the API key on standard input), answers status done */
    words: ["net", "start", "<action>"];
    path: "/net/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "node.keyline.by_name": {
    /** the key of a node as data: key (ok|locked|missing), user, file (where the other server's owner puts the line) and line (the public half with the forced command; never the private key) */
    words: ["node", "keyline", "<name>"];
    path: "/node/keyline/{name}";
    method: "get";
    class: "read";
    params: { name: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "node.list": {
    /** the other servers (nodes) of this one, one per line: name, kind (peer|vps), host, port, source (file|setting), key (ok|locked|missing) */
    words: ["node", "list"];
    path: "/node/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "node.plan.by_action": {
    /** what adding, removing or making the key of a node would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused, 2 = something is missing) */
    words: ["node", "plan", "<action>"];
    path: "/node/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "node.remote": {
    /** the forced command of the key another server uses to look at this one: accepts only the word status in SSH_ORIGINAL_COMMAND, anything else exits 2 */
    words: ["node", "remote"];
    path: "/node/remote";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "node.show.by_name": {
    /** one node as key<TAB>value lines: name, kind, host, port, user, source, key, words (what this server may ask it), command (exit 1: unknown node) */
    words: ["node", "show", "<name>"];
    path: "/node/show/{name}";
    method: "get";
    class: "read";
    params: { name: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "node.start.by_action": {
    /** add, remove or make the key of a node (hs sys node start add <name> <host> [--kind K] [--port N] | remove <name> | key <name> [--new]); changes nothing on the other server */
    words: ["node", "start", "<action>"];
    path: "/node/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "node.status.by_name": {
    /** the status document of a node, read over SSH with the key of hs node key: one JSON object (exit 1: no key, vault closed, no answer) */
    words: ["node", "status", "<name>"];
    path: "/node/status/{name}";
    method: "get";
    class: "read";
    params: { name: string; };
    stdin: "none";
    exit: number;
    lines: unknown;
  };
  "notify.channel.by_name": {
    /** one channel as key<TAB>value lines; a secret is set or -, never its value (exit 1: unknown channel) */
    words: ["notify", "channel", "<name>"];
    path: "/notify/channel/{name}";
    method: "get";
    class: "read";
    params: { name: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "notify.channels": {
    /** the notification channels, one per line: name, provider, enabled, minprio, quiet, outside (outside|inside), source (file|derived), ready (ok|incomplete), categories (comma separated), caps of the provider (comma separated), then the last send: time (epoch seconds or -), ok|failed or -, short reason or - */
    words: ["notify", "channels"];
    path: "/notify/channels";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "notify.plan.by_action": {
    /** what adding, changing, removing or testing a notification channel would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused, 2 = something is missing) */
    words: ["notify", "plan", "<action>"];
    path: "/notify/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "notify.providers": {
    /** the providers and their settings: provider, key, label, kind (text|secret), required|optional, pattern (or -), caps (comma separated) */
    words: ["notify", "providers"];
    path: "/notify/providers";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "notify.start.by_action": {
    /** do it (hs sys notify start add|set <name> ... | remove <name> | test <name> | migrate; one secret on stdin), answers status done */
    words: ["notify", "start", "<action>"];
    path: "/notify/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "parts.list": {
    /** the optional parts (capabilities) of this server, one per line: name, on|off, extension|part, nix (yes = needs a rebuild), switch (yes = machine.toml switches it), title */
    words: ["parts", "list"];
    path: "/parts/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "parts.pending": {
    /** the parts the next hs rebuild changes, one per line: name, on (switched on in machine.toml, not built yet) or off (taken out of machine.toml, still running); empty: nothing waits */
    words: ["parts", "pending"];
    path: "/parts/pending";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "parts.plan.by_action": {
    /** what switching a part on or off would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused; off with a NixOS module is red) */
    words: ["parts", "plan", "<action>"];
    path: "/parts/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "parts.start.by_action": {
    /** switch a part on or off (hs sys parts start enable|disable <part>): an extension without a module at once, any other part with the next rebuild */
    words: ["parts", "start", "<action>"];
    path: "/parts/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "peers.plan.by_action": {
    /** what mounting a share of another homeserver, stopping it, taking back the access given, or attaching it to an instance would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused) */
    words: ["peers", "plan", "<action>"];
    path: "/peers/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "peers.start.by_action": {
    /** do it (hs sys peers start add <peer> <host> <share> --user <login> with the password on stdin | remove|revoke <peer> [<share>] --confirm <peer> | attach <peer> <instance> | detach <peer> <instance>), answers status done */
    words: ["peers", "start", "<action>"];
    path: "/peers/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "pkg.available": {
    /** what the repositories offer as data: repo, package, kind, version, applied version (- = not installed) */
    words: ["pkg", "available"];
    path: "/pkg/available";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "pkg.list": {
    /** every package as data: name, kind, version, applied version (- = never), audience, title */
    words: ["pkg", "list"];
    path: "/pkg/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "pkg.market": {
    /** every installable package as data: name, kind, repo, available version, installed version (- = none), state (new|current|update|orphan), core (yes|no), audience, title */
    words: ["pkg", "market"];
    path: "/pkg/market";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "pkg.plan.by_action": {
    /** what installing, updating or removing a package, fetching, or adding or removing a repository would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused); check-draft checks a package.toml draft on stdin (finding lines, changes nothing) */
    words: ["pkg", "plan", "<action>"];
    path: "/pkg/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "pkg.repos": {
    /** the package repositories as data: name, address, signed|unsigned, default|added */
    words: ["pkg", "repos"];
    path: "/pkg/repos";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "pkg.start.by_action": {
    /** do it (hs sys pkg start install <name> [--repo R] | update <name> | remove <name> | fetch [<repo>] | repo-add <name> <url> (key line on stdin) | repo-remove <name>); red changes need --confirm <name> */
    words: ["pkg", "start", "<action>"];
    path: "/pkg/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "pool.disks": {
    /** disks the interface offers (device, size, role) */
    words: ["pool", "disks"];
    path: "/pool/disks";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "pool.info": {
    /** layout and state of the pools */
    words: ["pool", "info"];
    path: "/pool/info";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "pool.info.by_pool": {
    /** layout and state of one pool */
    words: ["pool", "info", "<pool>"];
    path: "/pool/info/{pool}";
    method: "get";
    class: "read";
    params: { pool: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "pool.members": {
    /** members of the bulk pool */
    words: ["pool", "members"];
    path: "/pool/members";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "pool.members.by_pool": {
    /** members of one pool */
    words: ["pool", "members", "<pool>"];
    path: "/pool/members/{pool}";
    method: "get";
    class: "read";
    params: { pool: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "pool.plan.by_pool.by_action": {
    /** what a change of a pool would do, as data: status, plan lines, confirm_name (never asks; exit 2 = something is missing) */
    words: ["pool", "plan", "<pool>", "<action>"];
    path: "/pool/plan/{pool}/{action}";
    method: "post";
    class: "plan";
    params: { pool: string; action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "pool.start.by_pool.by_action": {
    /** do a change of a pool as a background job; needs --confirm <name> (passphrase on stdin with --encrypt) */
    words: ["pool", "start", "<pool>", "<action>"];
    path: "/pool/start/{pool}/{action}";
    method: "post";
    class: "start";
    params: { pool: string; action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "pool.state": {
    /** what the pools are doing: the bulk lock, the health-check pause, last scrub and last parity sync (lock, paused, scrub <pool>, sync bulk; read only) */
    words: ["pool", "state"];
    path: "/pool/state";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: ([tag: "lock", state: "pool-change" | "free" | "busy" | "unknown", text: Field]
      | [tag: "paused", state: "yes" | "no", text: Field]
      | [tag: "scrub", pool: Field, state: Field, text: Field]
      | [tag: "sync", pool: Field, state: Field, text: Field])[];
  };
  "pool.state.by_pool": {
    /** the same for one pool */
    words: ["pool", "state", "<pool>"];
    path: "/pool/state/{pool}";
    method: "get";
    class: "read";
    params: { pool: string; };
    stdin: "none";
    exit: number;
    lines: ([tag: "lock", state: "pool-change" | "free" | "busy" | "unknown", text: Field]
      | [tag: "paused", state: "yes" | "no", text: Field]
      | [tag: "scrub", pool: Field, state: Field, text: Field]
      | [tag: "sync", pool: Field, state: Field, text: Field])[];
  };
  "ports.list": {
    /** what listens on the server and in each running container, and the Zoraxy proxy targets with their warnings (listen and proxy lines, see scripts/ports.sh) */
    words: ["ports", "list"];
    path: "/ports/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "power.started": {
    /** send the "server started" push message (hs-boot-notice.service) */
    words: ["power", "started"];
    path: "/power/started";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "power.stopping": {
    /** send the "going down" push message (hs-shutdown-notice.service) */
    words: ["power", "stopping"];
    path: "/power/stopping";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "reads.collect": {
    /** read the slow reads of the web interface and keep their output in the state database (the timer hs-reads-collect does it every 15 s; --all ignores the intervals) */
    words: ["reads", "collect"];
    path: "/reads/collect";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "reads.status": {
    /** every read the collector keeps, as data: read, interval in seconds, age of the kept output (-1 = never), milliseconds, exit code, bytes */
    words: ["reads", "status"];
    path: "/reads/status";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "rebuild.pending": {
    /** the machine.toml changes that wait for one hs rebuild, one per line: key, the value the running system was built with, the value now (- = not set); empty: nothing waits or no copy was kept yet */
    words: ["rebuild", "pending"];
    path: "/rebuild/pending";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "recipes.asks.by_recipe": {
    /** the questions a recipe wants answered before it runs, as data: key, label, kind (text|secret|choice:a,b), default, pattern, when (- when empty); the last row is input and form|terminal|none */
    words: ["recipes", "asks", "<recipe>"];
    path: "/recipes/asks/{recipe}";
    method: "get";
    class: "read";
    params: { recipe: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "recipes.list": {
    /** the app recipes: name, description, instances, state (installed|partly|not installed|parked|unknown) */
    words: ["recipes", "list"];
    path: "/recipes/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "recipes.plan.by_recipe.by_action": {
    /** what running a recipe would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused, also for a recipe that needs something typed) */
    words: ["recipes", "plan", "<recipe>", "<action>"];
    path: "/recipes/plan/{recipe}/{action}";
    method: "post";
    class: "plan";
    params: { recipe: string; action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "recipes.start.by_recipe.by_action": {
    /** run a recipe as a background job with the stored answers or the defaults (hs sys recipes start <recipe> run [--name <container>]), answers status started and the unit */
    words: ["recipes", "start", "<recipe>", "<action>"];
    path: "/recipes/start/{recipe}/{action}";
    method: "post";
    class: "start";
    params: { recipe: string; action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "recipes.versions": {
    /** the app recipes with versions: name, available version, applied version (- = not known), state (current|update|unknown) */
    words: ["recipes", "versions"];
    path: "/recipes/versions";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "registry": {
    /** the command registry (kind, path, script) */
    words: ["registry"];
    path: "/registry";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "release.plan.by_action": {
    /** what switching the update channel would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused: unknown channel, same channel, invalid tag signature); a newer channel adds a danger line and confirm_name */
    words: ["release", "plan", "<action>"];
    path: "/release/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "release.show": {
    /** the update channel and what the next update does, as key<TAB>value lines: channel, installed, offer (channel, ref or -, state) for each channel, then ref, state (none|unknown|current|kept|update) and signed (yes|no|-) of the current channel; reads fetched refs only */
    words: ["release", "show"];
    path: "/release/show";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: ([tag: "channel", channel: Field]
      | [tag: "installed", version: Field]
      | [tag: "offer", channel: Field, ref: Field, state: "none" | "unknown" | "current" | "kept" | "update"]
      | [tag: "ref", ref: Field]
      | [tag: "state", state: "none" | "unknown" | "current" | "kept" | "update"]
      | [tag: "signed", signed: "yes" | "no" | "-"])[];
  };
  "release.start.by_action": {
    /** do it (hs sys release start channel <stable|beta|edge> [--confirm <channel>]; a newer channel needs its own name), answers status done */
    words: ["release", "start", "<action>"];
    path: "/release/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "remote.list": {
    /** offers and mounts, tab separated: kind, peer, share, host or login, state */
    words: ["remote", "list"];
    path: "/remote/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "remote.mount-all": {
    /** mount what is set up and not mounted (the timer hs-remote-mount) */
    words: ["remote", "mount-all"];
    path: "/remote/mount-all";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "routes.plan.by_action": {
    /** what applying the service routes to the reverse proxy, adopting hand-made routes, importing services or removing one would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused or nothing to do) */
    words: ["routes", "plan", "<action>"];
    path: "/routes/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "routes.start.by_action": {
    /** do it (hs sys routes start apply --confirm apply | adopt | import | remove <service>); apply is a background job, the others answer status done */
    words: ["routes", "start", "<action>"];
    path: "/routes/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "secrets.plan.by_action": {
    /** what a header backup of the vault, moving secrets into it, closing it or fixing the permissions of the secrets would do, as data: status, plan lines (never asks; exit 0 ok, 1 refused) */
    words: ["secrets", "plan", "<action>"];
    path: "/secrets/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "secrets.start.by_action": {
    /** do it as a background job (hs sys secrets start header-backup | move [<name>] | close --confirm close | secrets-fix), answers status started and the unit */
    words: ["secrets", "start", "<action>"];
    path: "/secrets/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "services.app": {
    /** the services for the Apps page as data: name, container, title, local, public, fqdn, exposure, admin */
    words: ["services", "app"];
    path: "/services/app";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "services.list": {
    /** the services as data: name, title, target, exposure, names, wants */
    words: ["services", "list"];
    path: "/services/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "services.local-routes": {
    /** the local proxy's routes against the services, as data (same columns as sys services routes) */
    words: ["services", "local-routes"];
    path: "/services/local-routes";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "services.plan": {
    /** the proxy routes against the services as data: act, host, path, target, service, note (status none without a proxy) */
    words: ["services", "plan"];
    path: "/services/plan";
    method: "post";
    class: "plan";
    params: { };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "services.routes": {
    /** the proxy routes against the services, as data (the same as sys services plan; the web page reads this one because a read must not be named plan): act, host, path, target, service, note */
    words: ["services", "routes"];
    path: "/services/routes";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "services.show.by_name": {
    /** one service as data: key, value (where, machine, port, names, exposure, public_paths, want ...; - when empty) */
    words: ["services", "show", "<name>"];
    path: "/services/show/{name}";
    method: "get";
    class: "read";
    params: { name: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "services.stats": {
    /** the live values of the dashboard tiles as data: service, index, label, state, value, unit */
    words: ["services", "stats"];
    path: "/services/stats";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "services.tiles": {
    /** the dashboard tiles as data: group, title, link, description, icon, name */
    words: ["services", "tiles"];
    path: "/services/tiles";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "setup.list": {
    /** the first-run checklist: id, state (done|open), label, command, web page; the last line (finished) is done once setupDone is true */
    words: ["setup", "list"];
    path: "/setup/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "shares.acl": {
    /** who may use a share */
    words: ["shares", "acl"];
    path: "/shares/acl";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "shares.acl.by_share": {
    /** who may use one share */
    words: ["shares", "acl", "<share>"];
    path: "/shares/acl/{share}";
    method: "get";
    class: "read";
    params: { share: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "shares.delete.by_share": {
    /** take a share away without erasing it (the system layer behind sys shares start <share> delete; --dry-run lists the steps) */
    words: ["shares", "delete", "<share>"];
    path: "/shares/delete/{share}";
    method: "post";
    class: "change";
    params: { share: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "shares.deleted": {
    /** the kept folders of deleted shares (<share>.deleted-<date>) with their size */
    words: ["shares", "deleted"];
    path: "/shares/deleted";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "shares.history.by_share": {
    /** the ZFS snapshots of a share (empty on SnapRAID) */
    words: ["shares", "history", "<share>"];
    path: "/shares/history/{share}";
    method: "get";
    class: "read";
    params: { share: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "shares.list": {
    /** shares with size and cache */
    words: ["shares", "list"];
    path: "/shares/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "shares.measure": {
    /** measure the share sizes (nightly) */
    words: ["shares", "measure"];
    path: "/shares/measure";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "shares.measure.by_share": {
    /** measure the size of one share now */
    words: ["shares", "measure", "<share>"];
    path: "/shares/measure/{share}";
    method: "post";
    class: "change";
    params: { share: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "shares.mounts.by_share": {
    /** who mounts a share (instance, device, inside path, ro|rw) */
    words: ["shares", "mounts", "<share>"];
    path: "/shares/mounts/{share}";
    method: "get";
    class: "read";
    params: { share: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "shares.overview": {
    /** every share with size, disks, backup, cache and the instances that mount it */
    words: ["shares", "overview"];
    path: "/shares/overview";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "shares.plan.by_share.by_action": {
    /** what a change of a share would do, as data: status, plan lines, confirm_name (never asks; exit 2 = something is missing) */
    words: ["shares", "plan", "<share>", "<action>"];
    path: "/shares/plan/{share}/{action}";
    method: "post";
    class: "plan";
    params: { share: string; action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "shares.principals": {
    /** users and groups a share can be given to */
    words: ["shares", "principals"];
    path: "/shares/principals";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "shares.purge.by_share": {
    /** remove a kept folder <share>.deleted-<date> for good (the system layer behind sys shares start <name> purge; --dry-run lists the steps) */
    words: ["shares", "purge", "<share>"];
    path: "/shares/purge/{share}";
    method: "post";
    class: "change";
    params: { share: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "shares.start.by_share.by_action": {
    /** do a change of a share as a background job; needs --confirm <share> when the plan has a danger line */
    words: ["shares", "start", "<share>", "<action>"];
    path: "/shares/start/{share}/{action}";
    method: "post";
    class: "start";
    params: { share: string; action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "shares.undelete.by_share": {
    /** bring a kept folder <share>.deleted-<date> back as the share <share> (the system layer behind sys shares start <name> undelete; --dry-run lists the steps) */
    words: ["shares", "undelete", "<share>"];
    path: "/shares/undelete/{share}";
    method: "get";
    class: "read";
    params: { share: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "shares.visible.by_share": {
    /** is a share listed when browsing the server (visible | hidden) */
    words: ["shares", "visible", "<share>"];
    path: "/shares/visible/{share}";
    method: "get";
    class: "read";
    params: { share: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "ssh-key.list": {
    /** the SSH keys of adminuser, one per line: id (fingerprint), type, comment, session (yes = this session's key); never the key itself */
    words: ["ssh-key", "list"];
    path: "/ssh-key/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "ssh-key.plan.by_action": {
    /** what adding or removing an SSH key would do, as data: status and plan lines (never asks; exit 0 ok, 1 refused) */
    words: ["ssh-key", "plan", "<action>"];
    path: "/ssh-key/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "ssh-key.start.by_action": {
    /** do it (hs sys ssh-key start add <public key line> | remove <id> --confirm remove); takes effect with hs rebuild */
    words: ["ssh-key", "start", "<action>"];
    path: "/ssh-key/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "state.baseline": {
    /** the daily SMART check per disk: serial, name, kind, level healthy|watch|failing, since, last read, first read, wwn, realloc, pending, uncorr, crc, nv_crit, nv_media, nv_used, nv_spare, present, note */
    words: ["state", "baseline"];
    path: "/state/baseline";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.baseline-run": {
    /** read every disk and compare with the stored reading (the timer hs-smart-baseline; root) */
    words: ["state", "baseline-run"];
    path: "/state/baseline-run";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.collect": {
    /** read the disks and update the state database (the one writer; root) */
    words: ["state", "collect"];
    path: "/state/collect";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.deck-disks": {
    /** the disk lines of the status document from the last collector run (exit 1 when it is not fresh) */
    words: ["state", "deck-disks"];
    path: "/state/deck-disks";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.disks": {
    /** the disk inventory: serial, model, size, name, state ok|missing|unknown, role, pool, first and last seen, worse, note */
    words: ["state", "disks"];
    path: "/state/disks";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "state.disks-json": {
    /** the disk inventory as JSON with masked serials (what the status endpoint serves at /disks) */
    words: ["state", "disks-json"];
    path: "/state/disks-json";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.events": {
    /** disk events from the state database: time, kind, serial, text */
    words: ["state", "events"];
    path: "/state/events";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "state.events-json": {
    /** the latest disk events as JSON with masked serials (what the status endpoint serves at /events) */
    words: ["state", "events-json"];
    path: "/state/events-json";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.forget.by_serial": {
    /** remove a MISSING disk from the inventory for good (no question: the caller asked; a disk that is present is refused) */
    words: ["state", "forget", "<serial>"];
    path: "/state/forget/{serial}";
    method: "post";
    class: "change";
    params: { serial: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.history": {
    /** the last 24 hours (one median per hour) as the status document shows them (JSON) */
    words: ["state", "history"];
    path: "/state/history";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: unknown;
  };
  "state.history-record": {
    /** add one reading (time rx tx cpu_total cpu_idle mem_total mem_available gpu uptime) to the last 24 hours; the status service does */
    words: ["state", "history-record"];
    path: "/state/history-record";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.inventory-json": {
    /** the inventory summary for the status document (JSON) */
    words: ["state", "inventory-json"];
    path: "/state/inventory-json";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.problems": {
    /** problems the state database knows (missing or worsening disks, a stopped collector): key and text */
    words: ["state", "problems"];
    path: "/state/problems";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.read-get.by_key": {
    /** the output the collector kept for a read (exit 1: none) */
    words: ["state", "read-get", "<key>"];
    path: "/state/read-get/{key}";
    method: "get";
    class: "read";
    params: { key: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.read-put.by_key": {
    /** keep the output of a read (standard input) in the state database; only the collector (reads-collect.sh) calls it */
    words: ["state", "read-put", "<key>"];
    path: "/state/read-put/{key}";
    method: "get";
    class: "read";
    params: { key: string; };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.reads": {
    /** what the collector keeps for the web interface, oldest first: read, age in seconds, milliseconds it took, exit code, bytes (which reads are slow, which are stale) */
    words: ["state", "reads"];
    path: "/state/reads";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "state.smart.by_serial": {
    /** the stored SMART readings of one disk over time */
    words: ["state", "smart", "<serial>"];
    path: "/state/smart/{serial}";
    method: "get";
    class: "read";
    params: { serial: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "status": {
    /** the facts the Overview shows: backup age, encryption, parity sync and scrub, upload cache, disk health, instances, hottest disk, last disk event, the Hobnix version */
    words: ["status"];
    path: "/status";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "system.cleanup": {
    /** the cleanup report as plain text (read only, changes nothing) */
    words: ["system", "cleanup"];
    path: "/system/cleanup";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "system.config": {
    /** read and change the common settings in machine.toml (language, gpu, notifyUrl, metrics, backupNewShares, incusUi, loginMessage, shareSnapshots, syncEveryHours, timeZone) */
    words: ["system", "config"];
    path: "/system/config";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "system.doctor": {
    /** the doctor's report as plain text (read only) */
    words: ["system", "doctor"];
    path: "/system/doctor";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "system.plan.by_action": {
    /** what updating the parity, a scrub, an update, a rebuild, a rollback or a garbage collection would do, as data: status, plan lines (never asks; exit 2 = something is missing) */
    words: ["system", "plan", "<action>"];
    path: "/system/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "system.report": {
    /** collect what a helper needs into one text file, prints where it is */
    words: ["system", "report"];
    path: "/system/report";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "system.start.by_action": {
    /** do it as a background job (hs sys system start sync | scrub --pool <pool> | update | rebuild | rollback --confirm rollback | gc --days <N>) */
    words: ["system", "start", "<action>"];
    path: "/system/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "system.updates": {
    /** how many new commits the checkout is behind its upstream, from refs already fetched (read only, fetches nothing): rows behind, ahead, upstream, fetched */
    words: ["system", "updates"];
    path: "/system/updates";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "temp-disk.raw": {
    /** disks that can be mounted as temp disk */
    words: ["temp-disk", "raw"];
    path: "/temp-disk/raw";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "unifi.clients": {
    /** every address the router has reserved or sees online, no header, by address: ip, mac, name (- when none), reserved|online|reserved+online */
    words: ["unifi", "clients"];
    path: "/unifi/clients";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "unifi.networks": {
    /** the router's networks, no header: name, subnet, dhcp true|false, first, last address of the DHCP range */
    words: ["unifi", "networks"];
    path: "/unifi/networks";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "unifi.reserved": {
    /** reserved addresses at the router */
    words: ["unifi", "reserved"];
    path: "/unifi/reserved";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "unifi.used": {
    /** addresses in use at the router */
    words: ["unifi", "used"];
    path: "/unifi/used";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "unlock.alarm": {
    /** send the "unlock needed" push message until it arrives, while the storage is locked (hs-unlock-alarm.service) */
    words: ["unlock", "alarm"];
    path: "/unlock/alarm";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "unlock.boot": {
    /** unlock at boot (systemd) */
    words: ["unlock", "boot"];
    path: "/unlock/boot";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "unlock.stdin": {
    /** unlock the encrypted storage, the passphrase is the first line on standard input, plain output (for tools such as homeserver-cli; set HS_CALLER) */
    words: ["unlock", "stdin"];
    path: "/unlock/stdin";
    method: "post";
    class: "change";
    params: { };
    stdin: "none";
    exit: number;
    lines: string;
  };
  "ups.status": {
    /** the UPS as key and value lines (state, charge, runtime, load), no root */
    words: ["ups", "status"];
    path: "/ups/status";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "users.access.by_user": {
    /** the shares a user can reach, and through which entry */
    words: ["users", "access", "<user>"];
    path: "/users/access/{user}";
    method: "get";
    class: "read";
    params: { user: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "users.details.by_user": {
    /** the editable fields of a user: full, mail, description (an empty value is -) */
    words: ["users", "details", "<user>"];
    path: "/users/details/{user}";
    method: "get";
    class: "read";
    params: { user: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "users.group-access.by_group": {
    /** the shares a group has an entry on */
    words: ["users", "group-access", "<group>"];
    path: "/users/group-access/{group}";
    method: "get";
    class: "read";
    params: { group: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "users.group-details.by_group": {
    /** the editable fields of a group: description (an empty value is -) */
    words: ["users", "group-details", "<group>"];
    path: "/users/group-details/{group}";
    method: "get";
    class: "read";
    params: { group: string; };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "users.groups": {
    /** domain groups and their members */
    words: ["users", "groups"];
    path: "/users/groups";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "users.list": {
    /** domain users */
    words: ["users", "list"];
    path: "/users/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "users.plan.by_name.by_action": {
    /** what a change of a user or group would do, as data: status, plan lines (never asks; exit 2 = something is missing) */
    words: ["users", "plan", "<name>", "<action>"];
    path: "/users/plan/{name}/{action}";
    method: "post";
    class: "plan";
    params: { name: string; action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "users.start.by_name.by_action": {
    /** do a change of a user or group as a background job */
    words: ["users", "start", "<name>", "<action>"];
    path: "/users/start/{name}/{action}";
    method: "post";
    class: "start";
    params: { name: string; action: string; };
    stdin: "no";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "vault.list": {
    /** the vault's items: name, kind, state (tab separated) */
    words: ["vault", "list"];
    path: "/vault/list";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "vault.usage": {
    /** the vault's state, device, size, used and free bytes, age of the header backup (key and value lines) */
    words: ["vault", "usage"];
    path: "/vault/usage";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "vault.uses": {
    /** who uses each vault item: name, text (tab separated) */
    words: ["vault", "uses"];
    path: "/vault/uses";
    method: "get";
    class: "read";
    params: { };
    stdin: "none";
    exit: number;
    lines: string[][];
  };
  "vps.plan.by_action": {
    /** what `vps update` or `vps watch` on the proxyserver would do, as data: status and plan lines (never asks; exit 0 ok, 1 refused: vpsHost not set, no key, vault closed) */
    words: ["vps", "plan", "<action>"];
    path: "/vps/plan/{action}";
    method: "post";
    class: "plan";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
  "vps.start.by_action": {
    /** do it as a background job over SSH with the key of hs vps key (hs sys vps start update|watch), answers status started and the unit */
    words: ["vps", "start", "<action>"];
    path: "/vps/start/{action}";
    method: "post";
    class: "start";
    params: { action: string; };
    stdin: "none";
    exit: 0 | 1 | 2;
    lines: ChangeLines;
  };
}

export type SysOperationId = keyof SysOperations;
/** the lines one operation prints on stdout (exit 0) */
export type SysLines<K extends SysOperationId> = SysOperations[K]["lines"];
/** one line of it */
export type SysLine<K extends SysOperationId> = SysOperations[K]["lines"] extends (infer L)[] ? L : never;
