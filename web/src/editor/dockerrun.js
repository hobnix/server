// `docker run ...` -> a compose file. Pure logic (no DOM), tested in plain node (tests/web-docker-editor.mjs).
// convert(text) -> { name, compose, env, notes[], error? }. Every -e KEY=VALUE goes to the env text (the service gets `env_file: .env`),
// so a secret stays in the .env panel. A flag it does not know is kept as a "# not converted: ..." comment and a note: nothing is dropped silently.

// shell words: single quotes, double quotes (\" \\ \$ \` escapes), backslash outside quotes, backslash-newline = continuation
export function tokenize(text) {
  const out = [];
  let cur = '', has = false, i = 0;
  const push = () => { if (has) out.push(cur); cur = ''; has = false; };
  while (i < text.length) {
    const c = text[i];
    if (c === '\\') {
      const n = text[i + 1];
      if (n === '\n') i += 2;
      else if (n === '\r' && text[i + 2] === '\n') i += 3;
      else if (n === undefined) i++;
      else { cur += n; has = true; i += 2; }
    } else if (c === "'") {
      const e = text.indexOf("'", i + 1);
      const end = e < 0 ? text.length : e;
      cur += text.slice(i + 1, end); has = true; i = end + 1;
    } else if (c === '"') {
      i++; has = true;
      while (i < text.length && text[i] !== '"') {
        if (text[i] === '\\' && '"\\$`\n'.includes(text[i + 1] ?? 'x')) { if (text[i + 1] !== '\n') cur += text[i + 1]; i += 2; }
        else cur += text[i++];
      }
      i++;
    } else if (/\s/.test(c)) { push(); i++; }
    else { cur += c; has = true; i++; }
  }
  push();
  return out;
}

const q = (s) => JSON.stringify(String(s));
// compose reads $ in the file: a literal $ is written $$
const dd = (s) => s.replace(/\$/g, () => '$$');
const cq = (s) => dd(q(s));
const cj = (a) => dd(JSON.stringify(a));
const plain = (s) => /^[A-Za-z0-9_./-][A-Za-z0-9_./:-]*$/.test(s) && !/^(true|false|yes|no|null|on|off|~)$/i.test(s) && !/^[0-9.]+$/.test(s);
const scalar = (s) => (plain(s) ? s : cq(s));
const BOOL = new Set(['d', 'detach', 'rm', 'init', 'privileged', 'i', 'interactive', 't', 'tty', 'it', 'read-only', 'sig-proxy', 'oom-kill-disable', 'q', 'quiet']);
const IGNORED = new Set(['d', 'detach', 'rm', 'sig-proxy', 'q', 'quiet']);
const WITH_VALUE = new Set(['name', 'p', 'publish', 'v', 'volume', 'mount', 'e', 'env', 'env-file', 'restart', 'network', 'net', 'u', 'user', 'w', 'workdir',
  'h', 'hostname', 'cap-add', 'cap-drop', 'device', 'gpus', 'l', 'label', 'entrypoint', 'm', 'memory', 'cpus', 'add-host', 'dns', 'pull', 'platform',
  'log-driver', 'log-opt', 'security-opt', 'shm-size', 'tmpfs', 'group-add', 'ulimit', 'expose', 'health-cmd', 'sysctl', 'pid', 'ipc', 'cgroupns',
  'runtime', 'stop-signal', 'stop-timeout', 'cpuset-cpus', 'cpuset-mems', 'cpu-shares', 'cpu-period', 'cpu-quota', 'link', 'blkio-weight', 'memory-swap',
  'memory-reservation', 'health-interval', 'health-retries', 'health-timeout', 'health-start-period', 'oom-score-adj',
  'mac-address', 'ip', 'ip6', 'dns-search', 'dns-option', 'label-file', 'volumes-from', 'userns', 'uts', 'cgroup-parent', 'cidfile', 'detach-keys',
  'domainname', 'annotation', 'network-alias', 'net-alias', 'a', 'attach', 'storage-opt', 'device-cgroup-rule', 'kernel-memory', 'pids-limit', 'isolation']);
const SIMPLE_LIST = { 'cap-drop': 'cap_drop', 'security-opt': 'security_opt', dns: 'dns', tmpfs: 'tmpfs', link: 'links', sysctl: 'sysctls', 'group-add': 'group_add', 'add-host': 'extra_hosts', expose: 'expose' };
const SIMPLE_ONE = { pull: 'pull_policy', platform: 'platform', 'shm-size': 'shm_size', pid: 'pid', ipc: 'ipc', cgroupns: 'cgroup', runtime: 'runtime', 'stop-signal': 'stop_signal', 'cpuset-cpus': 'cpuset' };
const pwd = (s) => s.replace(/^(\$\(pwd\)|\$PWD|\$\{PWD\})(?=\/|$)/, '.');

const hostPath = (s) => (/^(\/|\.|~|[A-Za-z]:[\\/])/.test(s) ? s : `./${s}`);

function volume(spec, notes) {
  const parts = spec.split(':');
  parts[0] = pwd(parts[0]);
  if (parts.length === 1) { notes.push(`volume ${spec}: only a container path, made ./data${spec.replace(/\/+$/, '')} next to the compose file`); return `./data${spec.replace(/\/+$/, '')}:${spec}`; }
  if (!/^(\/|\.|~)/.test(parts[0]) && !/^[A-Za-z]:/.test(parts[0])) notes.push(`volume ${parts[0]}: a named volume is not supported, made the folder ./${parts[0]}`);
  parts[0] = hostPath(parts[0]);
  return parts.join(':');
}

function mountOf(spec, notes) {
  const kv = {};
  for (const p of spec.split(',')) { const [k, ...v] = p.split('='); kv[k.trim()] = v.join('='); }
  const src = kv.source ?? kv.src, dst = kv.target ?? kv.destination ?? kv.dst;
  if (!src || !dst || !['bind', 'volume', undefined].includes(kv.type)) { notes.push(`--mount ${spec}: not converted`); return null; }
  if (kv.type !== 'bind' && !/^(\/|\.|~)/.test(src)) notes.push(`mount ${src}: a named volume is not supported, made the folder ./${src}`);
  const on = (k) => k in kv && !/^(false|0)$/i.test(kv[k]);
  return `${hostPath(pwd(src))}:${dst}${on('readonly') || on('ro') ? ':ro' : ''}`;
}

function envLine(k, v) {
  if (!/[\s#"'$\\]/.test(v)) return `${k}=${v}`;
  // single quotes keep a $ literal in a .env file; with a ' inside, double quotes and \$
  if (!v.includes("'") && !/[\r\n]/.test(v)) return `${k}='${v}'`;
  return `${k}=${q(v).replace(/\$/g, '\\$')}`;
}

function nameFrom(image) {
  const base = image.split('@')[0].split('/').pop().split(':')[0].toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^[^a-z0-9]+/, '');
  return base.slice(0, 41) || 'app';
}

export function convert(text) {
  const notes = [], skipped = [];
  let t = tokenize(String(text ?? ''));
  while (t[0] === '$' || t[0] === 'sudo') t.shift();
  if (t[0] === 'docker') t.shift();
  if (t[0] === 'container') t.shift();
  if (t[0] !== 'run') return { name: '', compose: '', env: '', notes: [], error: 'This is not a docker run command.' };
  t.shift();

  const o = { ports: [], vols: [], env: [], labels: [], caps: [], devices: [], simple: {}, lists: {} };
  let image = '', rest = [];
  for (let i = 0; i < t.length; i++) {
    const a = t[i];
    if (a === '--') { image = t[i + 1] ?? ''; rest = t.slice(i + 2); break; }
    if (!a.startsWith('-') || a === '-') { image = a; rest = t.slice(i + 1); break; }
    let flag, val;
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      flag = eq < 0 ? a.slice(2) : a.slice(2, eq);
      val = eq < 0 ? undefined : a.slice(eq + 1);
    } else {
      // short flags: -p 80:80, -p80:80, a cluster of booleans (-dit)
      // walk the cluster: the first flag with a value takes the rest of the token or the next token (-dp 80:80, -de A=b, -itp80:80)
      const f = a.slice(1);
      for (let k = 0; k < f.length; k++) {
        const ch = f[k];
        if (WITH_VALUE.has(ch) && !BOOL.has(ch)) { flag_(ch, k + 1 < f.length ? f.slice(k + 1) : (t[++i] ?? ''), `-${ch}`); break; }
        flag_(ch, undefined, `-${ch}`);
      }
      continue;
    }
    if (val === undefined && WITH_VALUE.has(flag) && !BOOL.has(flag)) val = t[++i] ?? '';
    // an unknown flag without =value is a switch, unless a value and the image seem to follow (then we cannot tell which is which)
    if (val === undefined && !BOOL.has(flag) && !WITH_VALUE.has(flag) && t.length - i - 1 >= 2 && !t[i + 1].startsWith('-')) {
      return { name: '', compose: '', env: '', notes, error: `${a}: this flag is not known here. Write it as ${a}=value (or remove it) so the image can be found.` };
    }
    flag_(flag, val, a);
  }

  function flag_(flag, val, raw = `-${flag}`) {
    switch (flag) {
      case 'name': o.name = val; break;
      case 'p': case 'publish': o.ports.push(val); break;
      case 'v': case 'volume': o.vols.push(volume(val, notes)); break;
      case 'mount': { const m = mountOf(val, notes); if (m) o.vols.push(m); else skipped.push(`--mount ${val}`); break; }
      case 'e': case 'env': o.env.push(val); break;
      case 'env-file': skipped.push(`--env-file ${val}`); notes.push(`--env-file ${val}: copy its lines into the .env panel`); break;
      case 'restart': o.restart = val; break;
      case 'network': case 'net': if (val === 'host') o.network_mode = 'host'; else { o.network_mode = val; notes.push(`--network ${val}: kept as network_mode, check it`); } break;
      case 'u': case 'user': o.user = val; break;
      case 'w': case 'workdir': o.working_dir = val; break;
      case 'h': case 'hostname': o.hostname = val; break;
      case 'cap-add': o.caps.push(val); break;
      case 'device': o.devices.push(val); break;
      case 'l': case 'label': o.labels.push(val); break;
      case 'entrypoint': o.entrypoint = val; break;
      case 'privileged': o.privileged = true; notes.push('--privileged gives the container full access to the host: check that the app needs it.'); break;
      case 'i': case 'interactive': o.stdin_open = true; break;
      case 't': case 'tty': o.tty = true; break;
      case 'it': o.stdin_open = true; o.tty = true; notes.push('-it ignored (stdin_open and tty set)'); break;
      case 'init': o.init = true; break;
      case 'read-only': o.read_only = true; break;
      case 'm': case 'memory': o.mem_limit = val; break;
      case 'cpus': o.cpus = val; break;
      case 'gpus':
        { const g = String(val ?? 'all').replace(/^["']|["']$/g, '');
          o.runtime = 'nvidia';
          if (g === 'all' || g === '') o.nvidia = 'all';
          else if (/^device=/.test(g)) o.nvidia = g.slice(7).replace(/^"|"$/g, '');
          else { skipped.push(`--gpus ${g}`); notes.push(`--gpus ${g} is a count: runtime: nvidia is set, add deploy.resources.reservations.devices with count: ${g} by hand, or use --gpus device=<ids>`); }
          notes.push(`--gpus: made runtime: nvidia${o.nvidia ? ` and NVIDIA_VISIBLE_DEVICES=${o.nvidia}` : ''}; the host needs the NVIDIA container toolkit`); }
        break;
      default:
        if (IGNORED.has(flag)) { notes.push(`${raw.startsWith('--') ? '--' + flag : '-' + flag} ignored (not needed in compose)`); break; }
        if (SIMPLE_LIST[flag] && val !== undefined) { (o.lists[SIMPLE_LIST[flag]] ??= []).push(val); break; }
        if (SIMPLE_ONE[flag] && val !== undefined) { o.simple[SIMPLE_ONE[flag]] = val; break; }
        { const shown = val !== undefined && !raw.includes('=') ? `${raw} ${val}` : raw; skipped.push(shown); notes.push(`${shown}: not converted, add it by hand`); }
    }
  }

  if (!image) return { name: '', compose: '', env: '', notes, error: 'No image found in the command.' };

  const name = (o.name || nameFrom(image)).toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^[^a-z0-9]+/, '').slice(0, 41) || 'app';
  const envLines = [];
  for (const e of o.env) {
    const k = e.split('=')[0];
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) { notes.push(`-e ${k}: not a NAME=value, not converted`); skipped.push(`-e ${e.split('=')[0]}`); continue; }
    if (!e.includes('=')) { notes.push(`-e ${k} had no value (it took the value from the shell): fill it in the .env panel`); envLines.push(`${k}=`); } else envLines.push(envLine(k, e.slice(k.length + 1)));
  }
  if (o.nvidia) envLines.push(`NVIDIA_VISIBLE_DEVICES=${o.nvidia}`);

  const L = [];
  for (const s of skipped) L.push(`# not converted: ${s.replace(/\n/g, ' ')}`);
  L.push('services:', `  ${name}:`, `    image: ${scalar(image)}`);
  const list = (key, items) => { if (items.length) { L.push(`    ${key}:`); for (const x of items) L.push(`      - ${cq(x)}`); } };
  const one = (key, v) => { if (v !== undefined && v !== '') L.push(`    ${key}: ${scalar(v)}`); };
  if (o.entrypoint !== undefined) L.push(`    entrypoint: ${cj(tokenize(o.entrypoint))}`);
  if (rest.length) L.push(`    command: ${cj(rest)}`);
  list('ports', o.ports);
  list('volumes', o.vols);
  if (envLines.length) L.push('    env_file: .env');
  one('restart', o.restart);
  one('network_mode', o.network_mode);
  one('user', o.user);
  one('working_dir', o.working_dir);
  one('hostname', o.hostname);
  list('cap_add', o.caps);
  list('devices', o.devices);
  list('labels', o.labels);
  for (const [k, v] of Object.entries(o.lists)) list(k, v);
  for (const [k, v] of Object.entries(o.simple)) one(k, v);
  one('runtime', o.runtime);
  if (o.privileged) L.push('    privileged: true');
  if (o.stdin_open) L.push('    stdin_open: true');
  if (o.tty) L.push('    tty: true');
  if (o.init) L.push('    init: true');
  if (o.read_only) L.push('    read_only: true');
  one('mem_limit', o.mem_limit);
  one('cpus', o.cpus);
  return { name, compose: L.join('\n') + '\n', env: envLines.length ? envLines.join('\n') + '\n' : '', notes };
}
