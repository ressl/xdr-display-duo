#!/bin/bash
# Read-only: exercises the media-key decoder without generating keyboard events.
set -eu
CONF="${XDR_DUO_CONFIG:-$HOME/Library/Application Support/xdr-duo/xdr-duo.conf}"
[ -r "$CONF" ] && . "$CONF"
BIN="${XDR_VOLUME:-${TOOLS_DIR:-$HOME/Library/Application Support/xdr-duo/bin}/xdr-volume}"
# assert_decode <data1> [subtype] <expected>
assert_decode() {
  EXPECTED="${!#}"
  set -- "${@:1:$#-1}"
  ACTUAL=$("$BIN" decode "$@" 2>/dev/null || true)
  [ "$ACTUAL" = "$EXPECTED" ] || { echo "FAIL: decode $* expected $EXPECTED, got ${ACTUAL:-<none>}"; exit 1; }
}

# NSEvent systemDefined data1: media-key type in high 16 bits,
# key state 0x0a (down) or 0x0b (up) in bits 8...15. Only subtype 8 carries media keys.
assert_decode 2560 up         # NX_KEYTYPE_SOUND_UP (0) + key-down
assert_decode 68096 down      # NX_KEYTYPE_SOUND_DOWN (1) + key-down
assert_decode 461312 mute     # NX_KEYTYPE_MUTE (7) + key-down
assert_decode 2816 ignore     # sound-up key-up event
assert_decode 133632 ignore   # unrelated media key type 2
assert_decode 2560 8 up       # explicit aux-control-buttons subtype
assert_decode 2560 7 ignore   # aux mouse buttons with the same data1 bits

echo "PASS: media-key data1 decoding"
