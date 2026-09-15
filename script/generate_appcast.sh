#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 App-update.zip release-notes.md new-output-directory" >&2
  exit 2
fi
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="$1"
NOTES="$2"
OUTPUT="$3"
NAME="$(basename "$ARCHIVE" .zip)"
VERSION="${NAME#TokenTick-}"
[[ "$NAME" = "TokenTick-$VERSION" && "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Update archives must be named TokenTick-MAJOR.MINOR.PATCH.zip." >&2; exit 2;
}
test -s "$ARCHIVE"
test -s "$NOTES"
GENERATOR="$PROJECT_ROOT/.build/ReleaseDerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
test -x "$GENERATOR"
# Use a separate directory so the full CLI distribution is not treated as another app update.
mkdir "$OUTPUT"
cp "$ARCHIVE" "$OUTPUT/$NAME.zip"
cp "$NOTES" "$OUTPUT/$NAME.md"
ARGS=(--download-url-prefix "https://github.com/yeliex/tokentick/releases/download/v$VERSION/"
  --link https://github.com/yeliex/tokentick --embed-release-notes --maximum-deltas 0 "$OUTPUT")
if [ -n "${TOKENTICK_SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s\n' "$TOKENTICK_SPARKLE_PRIVATE_KEY" | "$GENERATOR" --ed-key-file - "${ARGS[@]}"
else
  "$GENERATOR" --account tokentick "${ARGS[@]}"
fi
grep -q 'sparkle:edSignature=' "$OUTPUT/appcast.xml"
grep -q '<description sparkle:format="markdown">' "$OUTPUT/appcast.xml"
echo "Signed appcast generated: $OUTPUT/appcast.xml"
