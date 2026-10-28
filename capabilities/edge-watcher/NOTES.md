# edge-watcher

The outside view of the home server (a power cut, a dead router or a broken tunnel is seen only from outside), ported from the proxyserver repo
(modules/watch.nix). `hs-edge-watch.timer` runs vps/hs-watch.sh every 5 minutes: no "alive" message of the home server on the heartbeat topic for
45 minutes, or a public address (`edgeWatchSites`) with no answer / a 5xx, is an urgent message to this node's push address. Sends only when the set of
problems changes, once a day as a reminder, and when it is over.

- This repo has the ONE copy of the script (vps/hs-watch.sh) and of scripts/lib/ntfy.sh. The proxyserver repo's copies end with that repo ("change both" is gone).
- Both addresses are secrets, so they are files, not machine.toml: `hs config set heartbeatUrl <the home server's heartbeat topic>` (what the watcher
  READS) and `hs config set notifyUrl <this node's own topic>` (where the alarm goes). Without the heartbeat file only the addresses are probed.
- The edge node never posts a heartbeat itself: scripts/edge-health.sh leaves that out on purpose.
- For the status document the script also writes `<state>.run` (every run), `<state>.beat` (newest heartbeat message) and `<state>.sites` (answer and
  since per site); scripts/lib/edge_facts.py turns them into the `watcher` key (state ok | alert | stale).
- Test: tests/vps-watch.sh (the script), tests/edge-facts.sh (the key).
