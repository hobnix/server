# The `hs sys` contract as OpenAPI

`openapi.json` is an OpenAPI 3.1 document of the `hs sys` words: one operation per `sys` row of `scripts/lib/registry.tsv`
(a path segment is an argv word, `<name>` is a path parameter), with the exit codes of plan and start, stdin, and for some rows
the exact lines. It describes the command line contract, not the JSON of `scripts/web-serve.py`; `x-hs-web` on an operation
names the `/api/sys/...` route and READS kind, so the web shapes can be derived from it later.
Decision record: [ADR 0001](../adr/0001-rust-strangler.md).

The file is generated. Never edit it by hand:

    python3 scripts/openapi-gen.py write

Run that in the same commit as a new, renamed or changed `sys` row. `tests/openapi.sh` fails when the file is stale.

## Describe a row

Rows without an entry are marked `x-hs-described: false`. To describe one, add it to `sys.toml` (key = row path without `sys `):

- `kind`: `tsv`, `json` or `text` (must equal the READS kind when the row is in READS).
- `columns = [...]` when every line has the same fields, or `records = {tag = [fields after the tag]}` when the first field names the line.
- Optional `enums = {field = [...]}` (records: `"tag.field"`), `stdin = "line"|"bytes"`, `note`.

Then run `write`. Left out of v1: extension rows (`commands.tsv`) and `jobs stream`. Whether a change to a described shape bumps
`scripts/lib/api-level` is not decided.
