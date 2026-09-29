#!/bin/bash
# Changes the real volume of both displays; restores the previous volume and mute at the end.
set -eu
CONF="${XDR_DUO_CONFIG:-$HOME/Library/Application Support/xdr-duo/xdr-duo.conf}"
. "$CONF"
BIN="${XDR_VOLUME:-$TOOLS_DIR/xdr-volume}"

[ -x "$BIN" ] || { echo "FAIL: $BIN missing"; exit 1; }

percent() { awk -v v="$1" 'BEGIN { printf "%d", v * 100 + 0.5 }'; }
dev_percent() { percent "$("$BIN" device "$1" getvol)"; }
assert_equal_devices() {
  V1=$(dev_percent 1); V2=$(dev_percent 2)
  M1=$("$BIN" device 1 getmute); M2=$("$BIN" device 2 getmute)
  [ "$V1" -eq "$V2" ] || { echo "FAIL: volumes differ: $V1 vs $V2"; exit 1; }
  [ "$M1" -eq "$M2" ] || { echo "FAIL: mute differs: $M1 vs $M2"; exit 1; }
}

ORIG_VOL=$(dev_percent 1)
ORIG_MUTE=$("$BIN" device 1 getmute)
restore() {
  "$BIN" set "$ORIG_VOL" >/dev/null
  if [ "$ORIG_MUTE" = 1 ]; then "$BIN" mute >/dev/null; fi
}
trap restore EXIT

"$BIN" set 50 >/dev/null
assert_equal_devices
BASE=$(dev_percent 1)
[ "$BASE" -ge 49 ] && [ "$BASE" -le 51 ] || { echo "FAIL: set 50 produced $BASE"; exit 1; }

"$BIN" up >/dev/null
assert_equal_devices
UP=$(dev_percent 1)
[ "$UP" -gt "$BASE" ] || { echo "FAIL: up did not increase volume ($BASE -> $UP)"; exit 1; }

"$BIN" down >/dev/null
assert_equal_devices
DOWN=$(dev_percent 1)
[ "$DOWN" -eq "$BASE" ] || { echo "FAIL: down did not restore previous step ($UP -> $DOWN, expected $BASE)"; exit 1; }

"$BIN" mute >/dev/null
assert_equal_devices
[ "$("$BIN" device 1 getmute)" -eq 1 ] || { echo "FAIL: mute did not mute"; exit 1; }

"$BIN" mute >/dev/null
assert_equal_devices
[ "$("$BIN" device 1 getmute)" -eq 0 ] || { echo "FAIL: second mute did not unmute"; exit 1; }

echo "PASS: dual-display set/up/down/mute commands"
