# code jab

Single-binary lint, fix & format for bash, JSON, YAML, Python, and HCL/Terraform. Written in Zig, runs in ≤10ms.

## Install

Download the latest binary for your platform from [releases](../../releases), or build from source:

```sh
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/jab /usr/local/bin/
```

## Usage

```
jab [options] [files...]

Options:
  -f                 Fix + format in-place (default: check only)
  --staged           Only git-staged files
  --skip=<rules>     Comma-separated rules (JBxxxx) or categories (lint, format)
  --ignore=<pat>     Ignore files matching pattern (glob, repeatable)
  --version          Print version and exit

Exit codes:
  0  Clean
  1  Diagnostics found (check), or unfixable diagnostics remain (fix)
  2  Tool error
```

```sh
jab                          # check all supported files recursively
jab src/ config.yaml         # check specific files/directories
jab -f                       # fix + format in-place
jab --staged                 # only git-staged files (pre-commit)
jab --skip=format            # lint only, no reformatting
jab --skip=JB1001,JB0001     # skip specific rules
```

## Rules

### Universal (all files)

| Rule | Description | Fixable |
|------|-------------|---------|
| JB0001 | Trailing whitespace | Yes |
| JB0002 | UTF-8 BOM | Yes |
| JB0003 | Zero-width characters | Yes |
| JB0004 | Bidi override characters (CVE-2021-42574) | Yes |
| JB0005 | Non-breaking space | Yes |
| JB0006 | Homoglyph characters | No |
| JB0007 | Missing trailing newline | Yes |
| JB0008 | Mixed line endings (CRLF + LF) | Yes |
| JB0009 | Null bytes | No |
| JB0010 | Smart quotes | Yes |
| JB0011 | Invalid UTF-8 | No |

### Bash (.sh, .bash)

| Rule | Description | Fixable |
|------|-------------|---------|
| JB1001 | Unquoted variable expansion | Yes |
| JB1002 | Unquoted command substitution | Yes |
| JB1003 | Legacy backtick syntax | Yes |
| JB1004 | cd without error handling | No |
| JB1005 | Unquoted `$@` | Yes |
| JB1006 | `read` without `-r` (SC2162) | No |
| JB1007 | `local x=$(cmd)` masks return value (SC2155) | No |
| JB1008 | `==` in `[ ]` test, not POSIX (SC2039) | Yes |
| JB1009 | `$?` comparison instead of direct `if` (SC2181) | No |
| JB1010 | `-a`/`-o` in `[ ]` test, not POSIX (SC2166) | No |

### Python (.py, .pyi)

| Rule | Description | Fixable |
|------|-------------|---------|
| JB2001 | Bare `except:` clause | Yes |
| JB2002 | `== None` / `!= None` | Yes |
| JB2003 | `== True` / `== False` | Yes |

### HCL/Terraform (.tf, .tfvars, .hcl, .tofu)

| Rule | Description | Fixable |
|------|-------------|---------|
| JB3001 | Deprecated interpolation-only `"${var.x}"` | Yes |
| JB3002 | Duplicate block labels | No |

### JSON (.json, .jsonc)

| Rule | Description | Fixable |
|------|-------------|---------|
| JB4001 | Duplicate keys | No |
| JB4002 | Trailing commas | Yes |

### YAML (.yaml, .yml)

| Rule | Description | Fixable |
|------|-------------|---------|
| JB5001 | Ambiguous truthy strings (yes/no/on/off) | Yes |
| JB5002 | Duplicate keys | No |

### Markdown (.md)

| Rule | Description | Fixable |
|------|-------------|---------|
| JB6001 | Heading level skipped | No |
| JB6003 | Empty link destination `[text]()` | No |

### TOML (.toml)

| Rule | Description | Fixable |
|------|-------------|---------|
| JB7001 | Duplicate keys (same table) | No |
| JB7002 | Duplicate table headers | No |

## Inline Suppression

Disable rules on specific lines with `jab:disable` in a comment:

```python
x == None  # jab:disable none-equality
```

```python
# jab:disable none-equality
x == None
```

```yaml
# jab:disable truthy-string
enabled: yes
```

```markdown
<!-- jab:disable heading-increment -->
### Skipped heading
```

Use `jab:disable` with no arguments to suppress all rules on that line.

## Ignoring Files

Use `--ignore` to exclude files by pattern (repeatable):

```sh
jab --ignore=vendor --ignore='*.generated.py'
```

jab also respects `.gitignore` patterns automatically.

## Pre-commit Hook

```sh
make install-hook
```

Or manually:

```sh
#!/bin/sh
jab --staged
```

## GitHub Actions

jab auto-detects `GITHUB_ACTIONS=true` and outputs `::error` annotations that appear inline on PRs.

```yaml
- name: Lint
  run: jab --staged
```

## Performance

~8ms to lint 14 files across all 5 languages. Target: ≤33ms on a typical 10-file commit.

| Platform | Binary size |
|----------|------------|
| darwin-arm64 | 2.6 MB |
| darwin-amd64 | 2.5 MB |
| linux-amd64 | 6.3 MB |
| linux-arm64 | 6.5 MB |
| windows-amd64 | 2.9 MB |

## Build

Requires [Zig 0.15+](https://ziglang.org/download/).

```sh
make build     # debug build
make test      # run tests
make release   # release binary
make fmt       # format zig source
```

## License

MIT
