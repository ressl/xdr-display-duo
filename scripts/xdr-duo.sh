#!/bin/bash
# Keeps the "XDR Display Duo" stacked multi-output aggregate intact. Started every 15 s by
# com.ressl.xdr-duo. Recreates the aggregate only when both displays are attached and the
# existing one is missing or invalid; a valid aggregate is left alone, so a default output
# the user chose deliberately is never overridden.

CONF="${XDR_DUO_CONFIG:-$HOME/Library/Application Support/xdr-duo/xdr-duo.conf}"
LOG="$HOME/Library/Logs/xdr-duo.log"
STATUS_FILE="$HOME/Library/Caches/xdr-duo.status"
mkdir -p "$(dirname "$LOG")" "$(dirname "$STATUS_FILE")"
exec >>"$LOG" 2>&1

log() { echo "$(date '+%F %T') $*"; }

# Log steady states only when they change; an idle system would otherwise add
# several lines every 15 s forever.
report() {
  [ "$1" = "$(cat "$STATUS_FILE" 2>/dev/null)" ] || log "$1"
  echo "$1" > "$STATUS_FILE"
}

[ -r "$CONF" ] || { log "config missing: $CONF"; exit 1; }
. "$CONF"

present() { "$TOOLS_DIR/ca_layout" "$1" >/dev/null 2>&1; }
if ! present "$XDR1_UID" || ! present "$XDR2_UID"; then
  report "waiting: not both configured displays attached -> nothing to do"
  exit 0
fi

if CHECK=$("$TOOLS_DIR/ca_multioutcheck" "$AGG_UID" 2>&1); then
  report "aggregate valid ($CHECK) -> no default-output change"
  exit 0
fi

rm -f "$STATUS_FILE"
log "invalid multi-output composition: $CHECK -> recreating"
if ! "$TOOLS_DIR/ca_agg"; then
  log "aggregate creation FAILED"
  exit 1
fi

# A freshly created aggregate may not accept default-output selection immediately. The
# next run sees a valid aggregate and deliberately leaves the default alone, so retry here.
for attempt in 1 2 3 4 5; do
  if "$TOOLS_DIR/ca_setout" "$AGG_UID"; then
    exit 0
  fi
  log "setting default output failed (attempt $attempt)"
  sleep 1
done
exit 1
