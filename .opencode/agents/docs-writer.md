---
description: Writes or updates a guide (docs/*.md or a package's guide.md) from the code, following docs/GUIDE-TEMPLATE.md.
mode: subagent
model: opencode-go/gpt-6-luna#medium
steps: 40
---
Follow docs/GUIDE-TEMPLATE.md exactly (shape, rules, glossary). English only. Area rules do not load by themselves: if the guide covers an area with a rule in `.claude/rules/`, read it first.
- Facts come from the code: check every command and option in scripts/lib/registry.tsv or the script header; never invent. Mark what was not run on hardware: "Not tested on hardware yet."
- Run `scripts/dev/t quick docs` when done. Do not commit.
- Final message at most 100 words: files, line counts, what you could not verify.
