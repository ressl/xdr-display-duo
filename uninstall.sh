#!/bin/bash
# Removes the agents, the helper app and the installed tools. The config is kept unless
# --purge is given. Afterwards choose a regular output in System Settings > Sound.
set -uo pipefail

CONF="$HOME/Library/Application Support/xdr-duo/xdr-duo.conf"
DOMAIN="gui/$(id -u)"
[ -r "$CONF" ] && . "$CONF"

for label in com.ressl.xdr-volume-keys com.ressl.xdr-duo com.ressl.xdr-duo-vol; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -rf "$HOME/Applications/XDR Volume Keys.app"
rm -f "$HOME/Library/Application Scripts/xdr-duo.sh" "$HOME/Library/Caches/xdr-duo.status"
tccutil reset ListenEvent com.ressl.xdr-volume-keys >/dev/null 2>&1

if [ -n "${TOOLS_DIR:-}" ]; then
  for f in ca_agg ca_setout ca_layout ca_multioutcheck ca_chanplay xdr-volume \
           test_media_key_decode.sh test_multi_output.sh test_xdr_volume.sh; do
    rm -f "$TOOLS_DIR/$f"
  done
  rmdir "$TOOLS_DIR" 2>/dev/null
fi
if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/Library/Application Support/xdr-duo"
fi
echo "uninstalled. Remove the \"${AGG_NAME:-XDR Display Duo}\" device in Audio MIDI Setup if you no longer need it."
