#!/usr/bin/env bash
# git-cut-tag: compute the next semantic version from the latest git tag and a
# version-line file, then create (and push) the tag.
#
# Driven entirely by INPUT_* environment variables (GitHub Actions convention):
#   INPUT_VERSION_FILE   Path to the version-line file. Holds '<prefix><major>.<minor>' (e.g. 'v1.2').
#   INPUT_VERSION_LEVEL  patch | minor | major (default patch).
#   INPUT_PREFIX         Override the tag prefix. Empty = infer from the version file.
#   INPUT_PRE_RELEASE    'true' to build a pre-release tag '<version>-<epoch>'.
#   INPUT_SKIP_PUSH      'true' to skip pushing the tag (useful for testing).
#
# The version file is treated as read-only: the maintainer owns it. This action
# never writes to it and never creates a commit — it only reads and tags.
set -euo pipefail

VERSION_FILE="${INPUT_VERSION_FILE:-.version}"
LEVEL="${INPUT_VERSION_LEVEL:-patch}"
PREFIX_OVERRIDE="${INPUT_PREFIX:-}"
PRE_RELEASE="${INPUT_PRE_RELEASE:-false}"
SKIP_PUSH="${INPUT_SKIP_PUSH:-false}"

# ---- Read and parse the version-line file ----------------------------------
if [ ! -f "$VERSION_FILE" ]; then
  echo "::error title=Version file not found::No version file at '$VERSION_FILE'. Create one containing the version line with prefix, e.g. 'v1.2'."
  exit 1
fi

RAW="$(tr -d ' \t\r\n' < "$VERSION_FILE")"
if [ -z "$RAW" ]; then
  echo "::error title=Empty version file::Version file '$VERSION_FILE' is empty. Expected '<prefix><major>.<minor>', e.g. 'v1.2'."
  exit 1
fi

# Prefix = leading non-digit characters (unless overridden); number = the rest.
FILE_PREFIX="$(printf '%s' "$RAW" | sed -E 's/^([^0-9]*).*/\1/')"
NUM="$(printf '%s' "$RAW" | sed -E 's/^[^0-9]*//')"

if [ -n "$PREFIX_OVERRIDE" ]; then
  PREFIX="$PREFIX_OVERRIDE"
else
  PREFIX="$FILE_PREFIX"
fi

if ! printf '%s' "$NUM" | grep -Eq '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
  echo "::error title=Malformed version file::Expected '<prefix><major>.<minor>' (e.g. 'v1.2'), got '$RAW'."
  exit 1
fi
FMAJ="$(printf '%s' "$NUM" | cut -d. -f1)"
FMIN="$(printf '%s' "$NUM" | cut -d. -f2)"
echo "Version-line floor: ${PREFIX}${FMAJ}.${FMIN}"

# ---- Validate version-level ------------------------------------------------
if [[ ! "$LEVEL" =~ ^(patch|minor|major)$ ]]; then
  echo "::error title=Invalid version-level::version-level must be 'patch', 'minor', or 'major' (got '$LEVEL')."
  exit 1
fi

# ---- Find the latest matching RELEASE tag ----------------------------------
# Only release tags (no pre-release suffix) with this exact prefix are considered.
git fetch --tags --quiet 2>/dev/null || true
# substr(...)==p (not index) so an empty prefix matches every tag on all awk variants.
LATEST_TAG="$(git tag --sort=-version:refname | awk -v p="$PREFIX" '
  { t=$0
    if (substr(t, 1, length(p)) == p) {
      v = substr(t, length(p) + 1)
      if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) { print t; exit }
    } }')"

if [ -n "$LATEST_TAG" ]; then
  TV="${LATEST_TAG#"$PREFIX"}"
  TMAJ="$(printf '%s' "$TV" | cut -d. -f1)"
  TMIN="$(printf '%s' "$TV" | cut -d. -f2)"
  TPATCH="$(printf '%s' "$TV" | cut -d. -f3)"
  echo "Latest release tag: $LATEST_TAG"
else
  TMAJ=0; TMIN=0; TPATCH=0
  echo "Latest release tag: (none)"
fi

# ---- Bump from the latest tag, then clamp up to the file floor -------------
case "$LEVEL" in
  major) NMAJ=$((TMAJ + 1)); NMIN=0;            NPATCH=0 ;;
  minor) NMAJ=$TMAJ;         NMIN=$((TMIN + 1)); NPATCH=0 ;;
  patch) NMAJ=$TMAJ;         NMIN=$TMIN;         NPATCH=$((TPATCH + 1)) ;;
esac

# If the file's line leapfrogs the tag-derived bump, honor it and reset patch.
if [ "$FMAJ" -gt "$NMAJ" ] || { [ "$FMAJ" -eq "$NMAJ" ] && [ "$FMIN" -gt "$NMIN" ]; }; then
  NMAJ=$FMAJ; NMIN=$FMIN; NPATCH=0
fi

BASE_VERSION="${NMAJ}.${NMIN}.${NPATCH}"

# ---- Apply pre-release suffix if requested ---------------------------------
if [ "$PRE_RELEASE" = "true" ]; then
  TS="$(date -u +%s)"
  VERSION="${BASE_VERSION}-${TS}"
  IS_PRE_RELEASE="true"
else
  VERSION="$BASE_VERSION"
  IS_PRE_RELEASE="false"
fi

TAG="${PREFIX}${VERSION}"
echo "Next version: $VERSION"
echo "Next tag:     $TAG"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "::error title=Tag already exists::Tag '$TAG' already exists."
  exit 1
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "version=$VERSION"
    echo "base-version=$BASE_VERSION"
    echo "tag=$TAG"
    echo "is-pre-release=$IS_PRE_RELEASE"
  } >> "$GITHUB_OUTPUT"
fi

# ---- Ensure a tagger identity for the annotated tag ------------------------
if [ -z "$(git config user.email || true)" ]; then
  git config user.email "github-actions[bot]@users.noreply.github.com"
  git config user.name "github-actions[bot]"
fi

# ---- Create and push the annotated tag -------------------------------------
git tag -a "$TAG" -m "Release $TAG"
echo "Created tag: $TAG"

if [ "$SKIP_PUSH" != "true" ]; then
  git push origin "$TAG"
  echo "Pushed $TAG to origin"
else
  echo "Skipping push (skip-push=true)"
fi
