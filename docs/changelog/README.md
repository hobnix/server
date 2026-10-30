# Changelog entries

One small TOML file per user-visible change: `YYYY-MM-DD-<slug>.toml` (slug: lower case letters, digits, `-`). English only.

    date  = "2026-10-30"          # must equal the date in the file name
    type  = "feature"             # feature | fix | change | security
    title = "One line, plain words, what the user sees"   # 1..100 chars
    docs  = "operations#see-what-changed-after-an-update" # optional: guide[#anchor], must exist
    body  = """Optional. At most 1000 characters. A blank line starts a new paragraph."""

No other keys. No real names, domains or hardware. Check with `python3 -I scripts/lib/changelog.py validate .`.
`hs changes` and the web page "What's new" read these files. Format and rules: `scripts/lib/changelog.py`.
