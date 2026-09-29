#!/bin/bash
# Read-only: verifies the structure of the installed aggregate.
set -eu
CONF="${XDR_DUO_CONFIG:-$HOME/Library/Application Support/xdr-duo/xdr-duo.conf}"
. "$CONF"
ACTUAL=$("$TOOLS_DIR/ca_layout" "$AGG_UID" 2>&1) || {
  echo "FAIL: $AGG_NAME not available: $ACTUAL"
  exit 1
}
case "$ACTUAL" in
  *"output channels: 2"*) ;;
  *) echo "FAIL: expected 2-channel stacked multi-output, got: $ACTUAL"; exit 1 ;;
esac
"$TOOLS_DIR/ca_multioutcheck" "$AGG_UID"
