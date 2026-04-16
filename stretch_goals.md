# Stretch Goals

## --stdin + --lang

Read source from stdin with a language hint for editor integration. Low priority — jab is fast enough (~8ms) that running on saved files is fine for most setups.

## jabw wrapper

Auto-download binary, SHA256 verify, `--install-hook`. Distribution tool, not a linter feature (Decision 27).

- Generate platform-appropriate download URL from GitHub releases
- SHA256 checksum verification
- `jabw --install-hook` wires up git pre-commit hook
- Single `curl | sh` install story
