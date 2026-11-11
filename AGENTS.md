# Rules for AI agents working on luci-app-5gmodem

This repository is public: anything committed or pushed is published and stays in the
history. Follow these rules strictly.

## Privacy
- Do not name people in code, docs, commit messages or release notes: no nicknames,
  real names, issue reporters or fork authors. Write "a field report", "the reporter".
- Do not publish identifiers or personal details: IMEI, IMSI, ICCID, EID, serial
  numbers, phone numbers, addresses, account data, details of anyone's own devices.
  Use obviously synthetic values in tests (`000000000000000`, `123456789012345`).
- Investigation notes and audits stay local (`docs/audits/` is ignored). Do not add
  them to the repository and do not link to them from public docs.
- Files named `*.local.md` and `.claude/settings.local.json` are private; never commit them.

## Git
- Do not commit or push unless the maintainer asks for it.
- Never bypass hooks (`--no-verify`, `-n`, `core.hooksPath`), never force-add ignored
  files, never rewrite history or force-push without an explicit order.
- If a hook blocks a commit or push, fix the content instead of working around it.

## Public text
- Issue and PR comments and release notes are public too: agree on the text with the
  maintainer before posting.
