#!/usr/bin/env bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/cut-tag.sh"

load "helpers/repo.sh"

setup() {
  WORK="$(mktemp -d)"
  export GITHUB_OUTPUT="$(mktemp)"
  # Never push in tests; there is no remote.
  export INPUT_SKIP_PUSH="true"
  export INPUT_VERSION_LEVEL="patch"
  export INPUT_PREFIX=""
  export INPUT_PRE_RELEASE="false"
  export INPUT_VERSION_FILE=".version"
}

teardown() {
  rm -rf "$WORK"
  rm -f "$GITHUB_OUTPUT"
}

# Run the script inside a prepared repo. Args are passed to make_repo as tags.
# Usage: run_cut <version-file-contents> [<tag> ...]
run_cut() {
  local vfile="$1"; shift
  make_repo "$WORK" "$@"
  write_version_file "$WORK" "$vfile"
  ( cd "$WORK" && bash "$SCRIPT" )
}

tag_out()  { output_value "$GITHUB_OUTPUT" tag; }
ver_out()  { output_value "$GITHUB_OUTPUT" version; }
base_out() { output_value "$GITHUB_OUTPUT" base-version; }
prerelease_out() { output_value "$GITHUB_OUTPUT" is-pre-release; }

# ---------------------------------------------------------------------------
# Core version computation
# ---------------------------------------------------------------------------

@test "patch bump on current line" {
  run_cut "v1.2" v1.0.0 v1.2.3 v1.2.4
  [ "$(tag_out)" = "v1.2.5" ]
  [ "$(prerelease_out)" = "false" ]
}

@test "minor bump advances the minor and zeroes the patch" {
  export INPUT_VERSION_LEVEL="minor"
  run_cut "v1.2" v1.2.4
  [ "$(tag_out)" = "v1.3.0" ]
}

@test "major bump advances the major and zeroes minor/patch" {
  export INPUT_VERSION_LEVEL="major"
  run_cut "v1.2" v1.2.4
  [ "$(tag_out)" = "v2.0.0" ]
}

@test "version file leapfrogs the latest tag" {
  run_cut "v1.3" v1.2.4
  [ "$(tag_out)" = "v1.3.0" ]
}

@test "no matching tag starts a fresh line at .0" {
  run_cut "v9.9"
  [ "$(tag_out)" = "v9.9.0" ]
}

@test "pre-release tags are ignored when finding the latest release" {
  run_cut "v1.2" v1.2.4 v1.2.5-1782043845
  [ "$(tag_out)" = "v1.2.5" ]
}

@test "latest is chosen by version order, not tag creation order" {
  # v1.10.0 must beat v1.9.0 despite lexical ordering.
  run_cut "v1.2" v1.9.0 v1.10.0
  [ "$(tag_out)" = "v1.10.1" ]
}

# ---------------------------------------------------------------------------
# Prefix handling
# ---------------------------------------------------------------------------

@test "no prefix in file yields unprefixed tags" {
  run_cut "1.4" 1.4.0 1.4.9
  [ "$(tag_out)" = "1.4.10" ]
}

@test "prefix override takes precedence over the file" {
  export INPUT_PREFIX="v"
  run_cut "1.2" v1.2.4
  [ "$(tag_out)" = "v1.2.5" ]
}

@test "only tags with the matching prefix are considered" {
  # 'rel-' prefix must not pick up the 'v' tags.
  run_cut "rel-2.0" v9.9.9 rel-2.0.7
  [ "$(tag_out)" = "rel-2.0.8" ]
}

# ---------------------------------------------------------------------------
# Pre-release builds
# ---------------------------------------------------------------------------

@test "pre-release build appends an -<epoch> timestamp suffix" {
  export INPUT_PRE_RELEASE="true"
  run_cut "v1.2" v1.2.4
  [ "$(prerelease_out)" = "true" ]
  [ "$(base_out)" = "1.2.5" ]
  [[ "$(ver_out)" =~ ^1\.2\.5-[0-9]+$ ]]
  [[ "$(tag_out)" =~ ^v1\.2\.5-[0-9]+$ ]]
}

@test "pre-release build creates the tag locally" {
  export INPUT_PRE_RELEASE="true"
  run_cut "v1.2" v1.2.4
  local tag
  tag="$(tag_out)"
  git -C "$WORK" rev-parse -q --verify "refs/tags/$tag" >/dev/null
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

@test "missing version file fails clearly" {
  make_repo "$WORK" v1.0.0
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Version file not found"* ]]
}

@test "empty version file fails clearly" {
  make_repo "$WORK" v1.0.0
  write_version_file "$WORK" ""
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Empty version file"* ]]
}

@test "malformed version file fails clearly" {
  make_repo "$WORK" v1.0.0
  write_version_file "$WORK" "v1"
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Malformed version file"* ]]
}

@test "invalid version-level fails clearly" {
  export INPUT_VERSION_LEVEL="bogus"
  make_repo "$WORK" v1.0.0
  write_version_file "$WORK" "v1.2"
  run bash -c "cd '$WORK' && INPUT_VERSION_LEVEL=bogus bash '$SCRIPT'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"version-level must be"* ]]
}

@test "existing target tag fails clearly (pre-release re-run, fixed epoch)" {
  # With a mocked fixed epoch, a second pre-release build computes the same tag.
  export PATH="${BATS_TEST_DIRNAME}/mocks:${PATH}"
  export INPUT_PRE_RELEASE="true"
  make_repo "$WORK" v1.2.4
  write_version_file "$WORK" "v1.2"
  ( cd "$WORK" && bash "$SCRIPT" )   # creates v1.2.5-1782043845
  run bash -c "cd '$WORK' && bash '$SCRIPT'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}

@test "version file is never modified" {
  run_cut "v1.2" v1.2.4
  [ "$(cat "$WORK/.version")" = "v1.2" ]
}

@test "no commit is created (HEAD unchanged)" {
  make_repo "$WORK" v1.2.4
  local before
  before="$(git -C "$WORK" rev-parse HEAD)"
  write_version_file "$WORK" "v1.2"
  ( cd "$WORK" && bash "$SCRIPT" )
  [ "$(git -C "$WORK" rev-parse HEAD)" = "$before" ]
}
