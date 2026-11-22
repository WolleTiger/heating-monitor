#!/bin/bash
# Sends a push notification to your phone via Home Assistant when the boiler reports
# a fault (status change 0 -> 1) or a new entry appears in the boiler's fault memory.
# Run every 5 minutes from cron.
#
#   */5 * * * * flock -n /tmp/alarm.lock timeout 55 /opt/heating/alarm.sh
#
# Test: ./alarm.sh --test

BASE="${BASE:-/opt/heating}"
VCONTROLD_HOST="${VCONTROLD_HOST:-127.0.0.1:3002}"
HA_URL="${HA_URL:-http://homeassistant.local:8123}"
# Home Assistant notify service of your phone, e.g. notify/mobile_app_my_iphone
SERVICE="${HA_NOTIFY_SERVICE:-notify/mobile_app_my_iphone}"
STATE="$BASE/alarm.state"
ERR_STATE="$BASE/alarm_error.state"
LOG="$BASE/alarm.log"
TOKEN=$(cat "$BASE/ha_token")

notify() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"title\":\"$1\",\"message\":\"$2\"}" \
    "$HA_URL/api/services/$SERVICE")
  echo "$(date -Iseconds) notification: $1 | $2 | HTTP $code" >> "$LOG"
  echo "$code"
}

read_val() {
  timeout 15 vclient -h "$VCONTROLD_HOST" -c "$1" 2>/dev/null | tr -d '\r' | sed 's/vctrld>//' | grep -E "$2" | tail -n 1
}

if [ "$1" = "--test" ]; then
  echo "Test: $(notify 'Heating test' 'Test notification from the server')"
  exit 0
fi

# 1) Fault flag: only notify on the transition 0 -> 1, remember state until it clears
val=$(read_val getStatusStoerung '^[01]$')
if [ -n "$val" ]; then
  last=$(cat "$STATE" 2>/dev/null || echo 0)
  if [ "$val" = "1" ] && [ "$last" != "1" ]; then
    code=$(notify 'Heating fault' 'The boiler reports a fault. Please check.')
    [ "$code" = "200" ] && echo 1 > "$STATE"
  elif [ "$val" = "0" ] && [ "$last" = "1" ]; then
    echo 0 > "$STATE"
  fi
fi

# 2) New entry in the fault memory
err=$(read_val getError0 '^20[0-9]{2}-')
if [ -n "$err" ]; then
  if [ ! -f "$ERR_STATE" ]; then
    echo "$err" > "$ERR_STATE"
  else
    last_err=$(cat "$ERR_STATE")
    if [ "$err" != "$last_err" ]; then
      code=$(notify 'Heating fault memory' "$err")
      [ "$code" = "200" ] && echo "$err" > "$ERR_STATE"
    fi
  fi
fi
