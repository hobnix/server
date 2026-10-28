# How to write a guide

Every guide of Hobnix (the nine core guides and the guide of a package) has the same shape, the same words and the same tone, so a reader
who has used one can use all of them. English only. This page is the template and the glossary; `tests/docs.sh` checks the parts it can.

## Shape

```
# <Title: what the reader gets, 2-5 words>          (one H1, the title the docs page shows)

<One or two sentences: what this guide does and for whom. No history, no "in this guide we will".>

## Before you start
- the things that must be true or at hand (an installed server, a share, an account), each with the guide that gives it: [Install](install.md)

## <Task 1: a verb phrase: "Add a disk", "Create a share">
<Why in one sentence, only if it is not obvious.>

```bash
sudo hs share add photos
```

<What you see or what changed, one or two sentences.>

## <Task 2>
...

## Check that it worked
- the command or page that shows the result, and what good looks like

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |

## Next
- one to three links to the guide that usually follows
```

## Rules

1. **Command first, one command per block.** A block holds one command, tagged `bash`, no `$` prompt and no output. Use the `hs` form
   (`sudo hs share add photos`); the long form (`nixos-rebuild`, `incus`, `zfs`) only where there is no `hs` command, and then say why.
2. **Plain words, short sentences.** Imperative for steps ("Run", "Open"), present tense for results. No "simply", "just", "easy".
3. **Name the thing the same way everywhere** (glossary below). A guide never invents a second word for a thing that has one.
4. **Placeholders** are `<angle-brackets>` in lower-case words (`<share>`, `<disk>`); examples use `example.com`, `192.168.1.x`,
   `homeserver`, `admin`. No real names, domains, addresses or hardware of any person's server.
5. **Dangerous steps** (data loss, formatting, anything that cannot be undone) say so in one bold sentence **before** the command, name what
   is lost, and show the check that comes first (`--dry-run`, `hs ... list`). Commands that destroy ask you to type the name of the thing.
6. **State what is untested.** A step that has not been run on real hardware says so in one line: "Not tested on hardware yet."
   Never claim a result that was not seen.
7. **Links** between guides are relative file links (`[Storage](storage-and-disks.md)`); no raw HTML tags anywhere (the renderer shows them
   as text). Images are optional, in `docs/img/`, with alt text.
8. **Length:** a core guide is 100 to 400 lines, a package guide 40 to 150. Longer means it is two guides or the detail belongs in the
   command's own help (`hs <command> --help`).
9. **Reference does not go in guides.** Every command and option is in the generated command page; a guide shows the commands of its task
   and links to the reference for the rest.

## Glossary (use exactly these words)

| Word | Means | Not |
| --- | --- | --- |
| server | the machine running Hobnix | host, box, node (a *node* is one server among several that the web interface manages) |
| container | an Incus system container | VM (a virtual machine is called a VM), docker container (say "Docker container") |
| instance | a container or a VM, when both are meant | |
| recipe | a package that sets up an app in its own container or VM | script, installer |
| extension | a package that adds commands and pages to the server | plugin, addon, module |
| package | a recipe or an extension | |
| repository | a place packages are fetched from (`hs pkg repo list`) | repo (in prose) |
| pool | a ZFS pool, or the SnapRAID pool `bulk` | array |
| share | a folder offered over the network (SMB) | shared folder |
| vault | the encrypted volume that holds the server's secrets | safe, keyring |
| web interface | the browser interface of the server | dashboard (the dashboard is the Homepage tile page) |
| `hs` | the command of the server: `hs <command>` | the CLI, the tool |

## Where guides live

- Core guides: `docs/<slug>.md` (slugs: install, containers-and-apps, users-and-shares, storage-and-disks, encryption-and-vault,
  backup-and-recovery, web-interface, operations). The command reference is generated.
- A package's guide: `guide.md` in the package folder (`packages/<name>/guide.md`, `capabilities/<name>/guide.md`, or in the repository
  of the package). It is shown on the docs page while the package is installed, in the group Apps or Extensions, under its package name.
- Contributor documents: the `PLAN-*` notes and `docs/Entwicklungsnotizen.md` describe design decisions for people who change the code.
  They are the only docs that are not guides and do not follow this template.
