#!/usr/bin/env bash
# package_ipa.sh <path/to/SoundCue.app> <out.ipa>
set -euo pipefail
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUTDIR="$(mkdir -p "$(dirname "$2")" && cd "$(dirname "$2")" && pwd)"
OUT="$OUTDIR/$(basename "$2")"
WORK="$(mktemp -d)"
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
rm -f "$OUT"
(cd "$WORK" && /usr/bin/zip -qry "$OUT" Payload)
rm -rf "$WORK"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
