# 0013: Cluster state and behaviour during a network partition

Status: Accepted (2026-11-10)
Issue: hobnix/server#256 (part of #203). The owner decides; nothing here is built beyond what the Context lists.

## Context

- Every server is a node of one repository (the former TODO.md section D). The roles are `homeserver`, `edge` and `minimal`; storage, Incus, Samba and
  backup are capabilities (docs/adr/0008-capabilities-and-packages.md). Your server is the local node; the public VPS and another person's
  server are remote nodes. The proxyserver repository is deprecated and becomes an `edge` node.
- Rules that exist: "the main node pulls from a peer through a narrow read allowlist; a peer never gets a shell or control of the main node; the
  VPS key never gets more than fixed words; the cousin's server is another person's: read-only first; no shared control plane" (the former TODO.md section D).
- Built: `hs node add|list|remove|show|key|status` (scripts/node.sh). A node is read over SSH with a key whose line in `authorized_keys`
  carries a forced command (`scripts/node-remote.sh`). The only word the main node ever sends is `status` (`NODE_WORDS`), the receiving
  side checks it again. The answer is one JSON status document, read at most 256 KiB (scripts/node.sh). Kinds: `vps` (the proxyserver, port 2222, forced command
  `vps-remote.sh` of the proxyserver repository), `edge` (port 2222, `node-remote.sh`, answers `edge status`) and `peer` (another home server, port 22).
  Nodes talk over Tailscale or WireGuard.
- The web interface shows remote nodes as tree roots and reads their pages through the cached status document. When a node does not
  answer, `hs node status` exits 1 and the page shows an error; the only age rule is in docs/PLAN-web-backend.md: a document older than 300 s is shown as "status is old" (amber), judged by the
  document's own `time`. Nothing says what a node does when it cannot reach the others, or what is shown after hours of silence.
- Each node already runs alone: backups, SMART, notifications, the watcher on the edge and the sync jobs need no other node. The data that
  matters (shares, containers, secrets, `machine.toml`) is in one place by design.
- No code or document says what two nodes that disagree do; this record writes it down before anything is built that could make them
  disagree.

## What has to be decided

1. Which data is shared between nodes at all.
2. Who may change a given object.
3. What a node may do alone while it cannot reach the others, and what it shows about the others.
4. How the nodes agree again afterwards.
5. What a compromised node can do to the rest.

## Options

### A. Federated: one owner per object, read-only cached copies (recommended)
Every object (a node's inventory, its health, its shares, its apps) has exactly one owning node, the one it lives on. Other nodes hold a copy
they pulled, mark it with the time it was read, and never write to it. A change to an object is made on its owner (or sent to the owner as a
request it checks). In a partition the copy gets older and is shown as stale; nothing votes.
- Fits what is built: pull of a `status` document through a forced command is exactly this.
- No quorum, so two nodes (the usual size) work; a partition has no wrong side.
- Cost: no change to a remote object while the link is down, and no single view that is always current.

### B. Embedded consensus (Raft or similar)
All nodes keep one replicated log; a change is accepted when a majority has it.
- One consistent view and changes that can be made from any node while a majority is up.
- Needs an odd number of voters to be meaningful. With two nodes (home and edge) a partition leaves no majority: the cut-off node cannot change
  anything, including itself. A third voter (a cheap VPS) must be added for the sake of the protocol only.
- Every voter has to be trusted with the whole state: a compromised edge node, the one on the public internet, could take part in votes
  and read what the log holds. This works against the rule "a peer never gets control of the main node".
- Another person's server cannot be a voter: its owner does not give a stranger a vote over their machine.
- A library to build, upgrade and debug in a bash and Python code base, run by people who are not operators.

### C. Replicated data with automatic merge (CRDT or last-writer-wins)
Each node writes anything and copies converge by merge.
- Works through partitions and needs no quorum.
- Rejected: a merge of settings, shares or firewall rules has no meaning that a person would accept; last-writer-wins depends on clocks that
  are not synchronised (a VPS and a home server), and a wrong winner on a firewall or a share can open something to the world.

### D. One authority node, others are agents
The home server holds the truth; edge nodes only execute.
- Simple, and close to today for the edge node.
- When the home server is down (a power cut, storage locked) the edge node has no instruction and nothing to say about the home server; the
  other person's server cannot be an agent of yours. It is option A with the owner fixed to one node, so A covers it.

## Decision (proposed): option A

1. **One owner per object.** The owner of an object is the node it runs on. The registry of nodes (`hs node`) is the only list of who the nodes
   are and is kept by each node itself; there is no shared copy of it.
2. **A node writes only its own objects.** A change to a remote object is a request to its owner through a forced-command word the owner
   knows and checks again (today: `status` only). Every new word is a decision of its own with its own record, and never a general shell.
3. **What is shared, and what is not.** Shared as a read-only copy: the status document, at most (the fields of the VPS document are in docs/PLAN-web-backend.md; this list is the limit, not a description of it) (host, role, capabilities, version, uptime, health
   summary, disk and pool verdicts, instance names and states, the events of the last days). Node-local, never sent: secrets and the vault,
   keys, `machine.toml`, shares and their file names, backup contents and passwords, SMART raw data, logs, user lists. A new field in the
   document is reviewed like a new `hs sys` row (ADR 0006) and has a size limit.
4. **Pulls, not pushes, towards the main node.** The main node reads. A remote node does not open a connection to the main node, and no
   remote node holds a key to the main node. (An edge node that must report when the main node is silent does so with a notification to a
   channel outside both, see Open points.)
5. **Every copy carries the time the reader got it.** The cache stores `as_of` taken from the reader's own clock, never from the remote
   document, so a skewed or lying clock does not make a copy look young. This replaces today's rule, which trusts the document's own `time`. A copy older than three times the polling interval is `stale`; older
   than a day is `unknown`. The web interface shows both, greyed, with the age; a node is never shown as healthy because its last copy was.
6. **A partition degrades to stale, not to a vote.** While the link is down each node keeps doing everything it does alone: serving, backups,
   sync, alarms for its own objects. It makes no change to a remote object, takes over nothing automatically and starts no failover.
   Taking over a function of another node (an edge node serving a different mail target, for example) is an explicit action by a person at the
   node that takes over, never a side effect of silence.
7. **Convergence is the next successful read.** The new document replaces the cached one completely. There is nothing to merge because there
   is one writer per object. The document gets a counter `gen` (new; today's document has none, verify) that only grows; a smaller `gen` than the cached one is shown as "node was reset or
   restored", not applied silently.
8. **Silence is an alarm on the reader.** A node that has been stale longer than a configured time raises a health problem and an event on the
   reading node (`node:<name>:silent`). A compromised node that stops reporting is therefore noticed, as is one that is simply down.
9. **A remote document is untrusted input.** The reader accepts only known keys, enforces the size limit (256 KiB) and the type of each
   field, and the web interface renders it as text, never as markup. A document that does not fit is discarded and the old copy goes stale.
10. **One key per node and direction.** The main node has a separate key for each remote node, with a forced command and only that node's
    allowed words; a key is never reused between nodes. The main node records the host key of each node at the first contact and refuses a changed one (today `StrictHostKeyChecking=accept-new` in scripts/node.sh trusts the first key it sees, so the first contact must happen over a path the owner trusts).

## Threat note: what a compromised node can do to the others

| Node | Can | Cannot (under this decision) |
| --- | --- | --- |
| Edge VPS (public, the most likely to be taken) | send a false or empty status document; stop answering; refuse mail or ports it serves itself; read what it holds locally; try to use the main node's pull as an attack (an oversized or hostile document) | reach the main node (no key, no connection towards it), run anything there, read shares, secrets or machine.toml, change another node's objects |
| Another person's server (read-only peer) | the same as the edge node: lie, go quiet | anything on your node; it holds none of your keys |
| Main node (the keys to every node live here) | read the status of every node; use each key only for the words the forced command allows | run a shell on a node: the forced command refuses everything except the fixed words |

So the worst result of a compromised remote node is wrong or missing information on the main node, which decisions 5, 8 and 9 turn into a stale
mark, an alarm, or a discarded document. What stays outside this record: a compromise of the main node (it holds the keys, and every
`status` it reads from the others), and the VPN: a stolen Tailscale or WireGuard key lets an outsider reach the SSH port of a node, where the
forced command and the recorded host key are the only defence. #203 (security review) should check both.

## Consequences

- A remote object cannot be changed during a partition. This is the intended price of no quorum and of keeping the other person's server out of
  your control.
- No fail-over. If the home server is down, nobody takes its role automatically, and nothing is lost that a person could not do by hand.
- The web interface needs an age and a state (`fresh`, `stale`, `unknown`, `reset`) for every remote value. This work follows the Nodes page
  (#346).
- Option B stays possible later for a group of nodes of one owner; this record does not block it and does not prepare it.

## Open points

- The polling interval and the silence limits (proposed: 60 s, `stale` at 3 intervals, alarm at 15 minutes, `unknown` at a day).
- Who tells you that the home server itself is down, when everything on it, including notifications, is down: today a channel outside the
  server (the former TODO.md section E asks for one) and the watcher on the edge node. Whether the edge node may run a watcher that only notifies, and
  where, is for the owner; it needs the outbound channel and nothing else.
- Whether changes to a remote node are ever allowed (the owner of that node creates the key and the words, as written for the other person's
  server), and what a request while stale looks like.
- Several nodes of the same owner that want one inventory page: covered by option A with more readers; no record needed unless a node must
  read a node it is not the main of.
- Time: nodes should keep their clocks in line by NTP; nothing in this record depends on it (decision 5).
- Not tested on hardware: nothing here was run; the Nodes page and the forced command are not run on a real VPS either (the former TODO.md item D1).
