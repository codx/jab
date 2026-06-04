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

jab also respects `.gitignore` automatically. By default it reads the
repository-root `.gitignore` with a built-in matcher (a pattern with no slash
matches at any depth, e.g. `*.json` ignores `src/sub/x.json`). With `--ext` it
delegates to `git check-ignore`, additionally honouring nested `.gitignore`
files, `.git/info/exclude`, and the global `core.excludesFile`. Pass `--all` to
disable `.gitignore` and the default skipped directories entirely.

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

## Build

Requires [Zig 0.15+](https://ziglang.org/download/).

```sh
make build     # debug build
make test      # run tests
make release   # release binary
make fmt       # format zig source
```
