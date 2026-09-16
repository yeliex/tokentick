#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH" >&2
  exit 2
fi
VERSION="$1"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Version must be vMAJOR.MINOR.PATCH." >&2; exit 2;
}
git rev-parse --verify "refs/tags/$VERSION^{commit}" >/dev/null
REPOSITORY="${GITHUB_REPOSITORY:-yeliex/tokentick}"
URL="https://github.com/$REPOSITORY"
PREVIOUS="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$VERSION^" 2>/dev/null || true)"
RANGE="$VERSION"
if [ -n "$PREVIOUS" ]; then
  RANGE="$PREVIOUS..$VERSION"
fi

printf '## Commits\n\n'
git log --reverse --format="- %s ([%h]($URL/commit/%H))" "$RANGE" --
if [ -n "$PREVIOUS" ]; then
  printf '\n**Full Changelog**: %s/compare/%s...%s\n' "$URL" "$PREVIOUS" "$VERSION"
else
  printf '\n**Full Changelog**: %s/commits/%s\n' "$URL" "$VERSION"
fi
