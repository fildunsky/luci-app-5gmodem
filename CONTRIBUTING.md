# Contributing

- **No explanatory comments in code.** Code should read on its own. Reasons, hardware quirks, bug history and OpenWrt/LuCI pitfalls go into [`docs/`](docs/README.md), into the subsystem or modem page they belong to.
- If a line would look like a mistake without context, leave one short English line pointing to the doc: `# see docs/modems/fibocom.md#teardown-keeps-the-bearer`. Keep these rare.
- Keep shebangs, license headers and build-system markers (`# call BuildPackage`).
- When code changes, update the matching doc section in the same commit.
- Commit messages and docs are in English.
