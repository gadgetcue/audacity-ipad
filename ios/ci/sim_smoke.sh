#!/usr/bin/env bash
# sim_smoke.sh <path/to/simulator SoundCue.app> <outdir>
# Boots one iPhone and one iPad simulator, installs and launches SoundCue, takes a
# screenshot, saves console + log output, and fails if the app is not running.
set -uo pipefail
APP="$1"
OUT="$2"
mkdir -p "$OUT"
BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

pick() {
  xcrun simctl list devices available -j | python3 "$(dirname "$0")/pick_sim.py" "$1"
}

FAIL=0
for KIND in iphone ipad; do
  UDID="$(pick "$KIND")"
  if [[ -z "$UDID" ]]; then echo "no simulator for $KIND"; FAIL=1; continue; fi
  echo "== $KIND $UDID"
  xcrun simctl boot "$UDID" 2>/dev/null
  xcrun simctl bootstatus "$UDID" -b > /dev/null
  xcrun simctl ui "$UDID" appearance dark || true
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl launch --console-pty "$UDID" "$BID" > "$OUT/$KIND-console.txt" 2>&1 &
  sleep 25
  xcrun simctl io "$UDID" screenshot "$OUT/$KIND.png"
  if xcrun simctl spawn "$UDID" launchctl list | grep -q "$BID"; then
    echo "$KIND: running OK"
  else
    echo "$KIND: NOT RUNNING after launch"
    FAIL=1
  fi
  xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'process == "SoundCue"' > "$OUT/$KIND-log.txt" 2>/dev/null || true
  xcrun simctl terminate "$UDID" "$BID" || true
  xcrun simctl shutdown "$UDID" || true
done
cp ~/Library/Logs/DiagnosticReports/*SoundCue* "$OUT/" 2>/dev/null && { echo "crash report(s) found"; FAIL=1; }
exit $FAIL
