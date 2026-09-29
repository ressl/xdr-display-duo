#!/bin/bash
# Builds and installs XDR Display Duo for the current user, then (re)loads the agents.
# Keeps an existing config. A first install creates it and fills in the display UIDs
# when exactly two Studio Display XDRs are attached.
set -euo pipefail
cd "$(dirname "$0")"

CONF_DIR="$HOME/Library/Application Support/xdr-duo"
CONF="$CONF_DIR/xdr-duo.conf"
SCRIPTS="$HOME/Library/Application Scripts"
AGENTS="$HOME/Library/LaunchAgents"
APP_DEST="$HOME/Applications/XDR Volume Keys.app"
DOMAIN="gui/$(id -u)"

make all app check

mkdir -p "$CONF_DIR"
if [ ! -f "$CONF" ]; then
  cp config/xdr-duo.conf "$CONF"
  UIDS=$(build/xdr-volume list --xdr)
  if [ "$(printf '%s\n' "$UIDS" | grep -c .)" = 2 ]; then
    UID1=$(printf '%s\n' "$UIDS" | sed -n 1p)
    UID2=$(printf '%s\n' "$UIDS" | sed -n 2p)
    sed -i '' -e "s|REPLACE_WITH_XDR1_UID|$UID1|" -e "s|REPLACE_WITH_XDR2_UID|$UID2|" "$CONF"
    echo "created $CONF with the two attached displays:"
    printf '  %s\n' "$UID1" "$UID2"
  fi
fi
if grep -q REPLACE_WITH "$CONF"; then
  echo "Set XDR1_UID and XDR2_UID in $CONF, then run ./install.sh again."
  echo "Attached Studio Display XDR speakers:"
  build/xdr-volume list --xdr | sed 's/^/  /'
  exit 1
fi
. "$CONF"

mkdir -p "$TOOLS_DIR" "$SCRIPTS" "$AGENTS" "$HOME/Applications" "$HOME/Library/Logs"
for tool in ca_agg ca_setout ca_layout ca_multioutcheck ca_chanplay xdr-volume; do
  install -m 755 "build/$tool" "$TOOLS_DIR/$tool"
done
install -m 755 scripts/test_*.sh "$TOOLS_DIR/"
install -m 755 scripts/xdr-duo.sh "$SCRIPTS/xdr-duo.sh"
cdhash() { codesign -d --verbose=4 "$1" 2>&1 | sed -n 's/^CDHash=//p'; }
OLD_HASH=$([ -d "$APP_DEST" ] && cdhash "$APP_DEST" || true)
rm -rf "$APP_DEST"
ditto "build/XDR Volume Keys.app" "$APP_DEST"
# An ad-hoc signature changes with every changed binary, and the Input Monitoring grant is
# bound to it. Re-enabling the stale entry does not help; it must be removed and re-granted.
APP_CHANGED=0
if [ "$OLD_HASH" != "$(cdhash "$APP_DEST")" ]; then
  APP_CHANGED=1
  tccutil reset ListenEvent com.ressl.xdr-volume-keys >/dev/null
fi

# The polling mirror is replaced by the listener's CoreAudio notifications.
launchctl bootout "$DOMAIN/com.ressl.xdr-duo-vol" 2>/dev/null || true
rm -f "$AGENTS/com.ressl.xdr-duo-vol.plist" "$SCRIPTS/xdr-duo-vol.sh" "$SCRIPTS/xdr-duo-volume.state"

for label in com.ressl.xdr-duo com.ressl.xdr-volume-keys; do
  sed "s|__HOME__|$HOME|g" "launchd/$label.plist" > "$AGENTS/$label.plist"
  plutil -lint "$AGENTS/$label.plist" >/dev/null
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  # bootout completes asynchronously; bootstrap fails with EIO until it has.
  for attempt in 1 2 3 4 5; do
    launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist" 2>/dev/null && break
    [ "$attempt" = 5 ] && { echo "cannot load $label"; exit 1; }
    sleep 1
  done
done

echo "installed."
if [ "$APP_CHANGED" = 1 ]; then
  # --request-permission only asks and exits; it does not start a second listener.
  open -n -a "$APP_DEST" --args listen --request-permission
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
  echo "The app changed, so its Input Monitoring grant was reset: enable 'XDR Volume Keys'"
  echo "in System Settings. The listener picks it up within a minute."
fi
