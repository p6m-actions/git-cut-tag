# Git Cut Tag

![Latest Release](https://img.shields.io/github/v/release/p6m-actions/git-cut-tag?style=flat-square&label=Latest%20Release&color=green)

## Description

A **language-agnostic** GitHub Action that cuts semantic-version git tags without touching any
language manifest. The version is driven by two things:

1. **The latest git tag** on the current line — provides the number to increment.
2. **A version-line file** (default `.version`) — holds `<prefix><major>.<minor>` (e.g. `v1.2`) and
   acts as the authoritative floor for the major/minor line, plus the source of the tag **prefix**.

The next version is computed by bumping the latest release tag by `version-level`, then clamping the
result up to the version-line floor: if you bump the file's line ahead of every existing tag, the next
release starts a fresh `.0` on that line.

It also supports **pre-release tags** via the `pre-release` flag: a valid semver pre-release with a
trailing epoch timestamp (e.g. `v1.2.5-1782043845`). Pre-release builds create a tag only.

> **The version file is owned by the maintainer.** This action treats it as read-only — it never
> writes to the file and never creates a commit. To move the major/minor line, edit `.version`
> yourself in a normal PR; the action reads it on the next run.

## Usage

```yaml
- uses: p6m-actions/git-cut-tag@v1
  with:
    version-level: patch
```

### Required permissions

This action uses [`token-exchange`](https://github.com/p6m-actions/token-exchange) to mint a P6M
installation token via OIDC, and pushes the tag. Your workflow needs:

```yaml
permissions:
  contents: write
  id-token: write
```

Check out with full history so tags are available:

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
```

## The version file

A single line containing the prefix and the `major.minor` line:

```
v1.2
```

- The **prefix** is the leading non-digit characters (`v` here). `1.2` yields no prefix. Override
  with the `prefix` input.
- The **major.minor** is the floor for the line. Bumping it (e.g. to `v1.3`) makes the next release
  `v1.3.0`, regardless of the latest tag. You maintain this file by hand.

## How the next version is computed

1. Read the floor `major.minor` and prefix from the version file.
2. Find the latest **release** tag with that prefix (pre-release tags are ignored). Selection is by
   semantic-version order, so `v1.10.0` beats `v1.9.0`.
3. Bump it by `version-level` (`patch` → +1 patch, `minor` → +1 minor & patch 0, `major` → +1 major
   & minor/patch 0). With no existing tag, the base is `0.0.0`.
4. If the file's `major.minor` is greater than the bumped result, use the file's line with patch `0`.
5. If `pre-release` is `true`, append `-<epoch-seconds>`.

| Version file | Latest tag | `version-level` | `pre-release` | Result tag |
|---|---|---|---|---|
| `v1.2` | `v1.2.4` | `patch` | `false` | `v1.2.5` |
| `v1.2` | `v1.2.4` | `minor` | `false` | `v1.3.0` |
| `v1.3` | `v1.2.4` | `patch` | `false` | `v1.3.0` |
| `v1.2` | *(none)* | `patch` | `false` | `v1.2.0` |
| `v1.2` | `v1.2.4` | `patch` | `true`  | `v1.2.5-1782043845` |
| `1.4`  | `1.4.9`  | `patch` | `false` | `1.4.10` |

## Inputs

| Input | Description | Required | Default |
|---|---|---|---|
| `version-file` | Path to the version-line file (`<prefix><major>.<minor>`) | No | `.version` |
| `version-level` | Level to bump relative to the latest tag: `patch`, `minor`, `major` | No | `patch` |
| `prefix` | Override the tag prefix (e.g. `v`). Empty = infer from the version file | No | `""` |
| `pre-release` | Build a pre-release tag with a trailing epoch timestamp | No | `false` |
| `working-directory` | Directory to operate in (contains the version file, inside the repo) | No | `.` |
| `skip-push` | Skip pushing the tag (useful for testing) | No | `false` |

## Outputs

| Output | Description |
|---|---|
| `version` | New version without prefix (e.g. `1.2.5` or `1.2.5-1782043845`) |
| `tag` | Created git tag with prefix (e.g. `v1.2.5`) |
| `base-version` | Release version without any pre-release suffix (e.g. `1.2.5`) |
| `is-pre-release` | `true` when a pre-release tag was created |

## Examples

### Basic patch release

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
- uses: p6m-actions/git-cut-tag@v1
  with:
    version-level: patch
```

### Pre-release build

```yaml
- uses: p6m-actions/git-cut-tag@v1
  id: tag
  with:
    pre-release: "true"
- run: echo "Built pre-release tag ${{ steps.tag.outputs.tag }}"
```

### Custom version file and prefix

```yaml
- uses: p6m-actions/git-cut-tag@v1
  with:
    version-file: ".release-line"
    prefix: "v"
```

## Development

The version logic lives in `scripts/cut-tag.sh` and is covered by a [bats](https://github.com/bats-core/bats-core)
suite:

```bash
brew install bats-core        # or: sudo apt-get install -y bats
bats tests/cut-tag.bats
```
