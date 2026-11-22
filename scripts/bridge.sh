#!/bin/bash
# Reads heating values read-only via vcontrold (Viessmann Optolink) and writes them to
# InfluxDB (time series) and Homebridge via MQTT (Apple Home).
#
# All heating values come from ONE vclient batch query, because each Optolink
# connection takes several seconds regardless of how many commands it contains.
#
# Run every minute from cron, e.g.:
#   * * * * * flock -n /tmp/bridge.lock timeout 55 /opt/heating/bridge.sh
#
# Secrets are read from files with mode 600 in $BASE (never hard-coded here).

BASE="${BASE:-/opt/heating}"
VCONTROLD_HOST="${VCONTROLD_HOST:-127.0.0.1:3002}"
INFLUX_URL="${INFLUX_URL:-http://127.0.0.1:8086}"
INFLUX_ORG="${INFLUX_ORG:-home}"
INFLUX_BUCKET="${INFLUX_BUCKET:-heizung}"
HA_URL="${HA_URL:-http://homeassistant.local:8123}"
MQTT_USER="${MQTT_USER:-hb}"
LOG="$BASE/bridge.log"

PW=$(cat "$BASE/mqtt.pass")
ITOK=$(cat "$BASE/influx_token")
HATOK=$(cat "$BASE/ha_token")

CMDS="getTempA,getTempVListM1,getTempWWist,getTempWWsoll,getStatusStoerung,getTempKist,getTempRaumNorSollM1,getTempRaumRedSollM1,getBrennerStunden1,getBrennerStarts,getError0,getError1,getError2,getBetriebArt,getBetriebPartyM1,getBetriebSparM1,getPumpeStatusM1,getStatusFrostM1,getBrennerStatus2,getTempVLsollM1,getNeigungM1,getNiveauM1"

RAW=$(timeout 30 vclient -h "$VCONTROLD_HOST" -c "$CMDS" 2>/dev/null | tr -d '\r')

# Value for a command: the line after "command:" in the batch output
val() { printf '%s\n' "$RAW" | awk -v k="$1:" 'index($0,k)==1 {getline; print; exit}'; }
num() { awk '{print $1}' | grep -E '^-?[0-9]+(\.[0-9]+)?$' | sed 's/\.0*$//'; }
err() { grep -E '^[0-9]{4}-'; }

# Publish a command to Homebridge through the MQTT broker running in the mosquitto container
hb() {
  timeout 10 docker exec mosquitto mosquitto_pub -h 127.0.0.1 -u "$MQTT_USER" -P "$PW" \
    -t "homebridge/$1" -m "$2" >/dev/null 2>&1
}

set_val() {
  hb to/set "{\"name\":\"$1\",\"service_name\":\"$2\",\"characteristic\":\"$3\",\"value\":$4}"
}

# Read a room temperature from Home Assistant (state only, never writes)
ha_temp() {
  timeout 6 curl -s -H "Authorization: Bearer $HATOK" \
    "$HA_URL/api/states/$1" \
    | sed -n 's/.*"state": *"\(-\{0,1\}[0-9.]*\)".*/\1/p'
}

# --- Values from the batch query ---
aussen=$(val getTempA | num)
vorlauf=$(val getTempVListM1 | num)
ww_ist=$(val getTempWWist | num)
ww_soll=$(val getTempWWsoll | num)
stoerung=$(val getStatusStoerung | num)
kessel=$(val getTempKist | num)
raum_normal=$(val getTempRaumNorSollM1 | num)
raum_reduziert=$(val getTempRaumRedSollM1 | num)
brennerstunden=$(val getBrennerStunden1 | num)
brennerstarts=$(val getBrennerStarts | num)
letzte=$(val getError0 | err)
betrieb=$(val getBetriebArt)
party=$(val getBetriebPartyM1 | num)
spar_m1=$(val getBetriebSparM1 | num)
pumpe_m1=$(val getPumpeStatusM1 | num)
frost_m1=$(val getStatusFrostM1 | num)
stufe2=$(val getBrennerStatus2 | num)
stoerung_2=$(val getError1 | err)
stoerung_3=$(val getError2 | err)

# Heating curve
vorlauf_soll=$(val getTempVLsollM1 | num)
neigung=$(val getNeigungM1 | num)
niveau=$(val getNiveauM1 | num)

# Room temperatures from Home Assistant (replace with your own entity IDs)
raum_bad=$(ha_temp "${ENTITY_RAUM_BAD:-sensor.bathroom_temperature}")
raum_kueche=$(ha_temp "${ENTITY_RAUM_KUECHE:-sensor.kitchen_temperature}")
raum_wc=$(ha_temp "${ENTITY_RAUM_WC:-sensor.wc_temperature}")
raum_schlafen=$(ha_temp "${ENTITY_RAUM_SCHLAFEN:-sensor.bedroom_temperature}")

case "$betrieb" in
  "H+WW") betrieb_code=1 ;;
  "WW") betrieb_code=2 ;;
  "RED") betrieb_code=3 ;;
  "NORM") betrieb_code=4 ;;
  "H+WW FS") betrieb_code=5 ;;
  "ABSCHALT") betrieb_code=6 ;;
  *) betrieb_code=0 ;;
esac

# --- Homebridge: register accessories (idempotent) and update values ---
hb to/add '{"name":"Heizung Aussentemperatur","service_name":"temperature","service":"TemperatureSensor"}'
hb to/add '{"name":"Heizung Vorlauf","service_name":"temperature","service":"TemperatureSensor"}'
hb to/add '{"name":"Warmwasser Ist","service_name":"temperature","service":"TemperatureSensor"}'
hb to/add '{"name":"Warmwasser Soll","service_name":"temperature","service":"TemperatureSensor"}'
hb to/add '{"name":"Heizung Stoerung","service_name":"contact","service":"ContactSensor"}'

[ -n "$aussen" ] && set_val "Heizung Aussentemperatur" temperature CurrentTemperature "$aussen"
[ -n "$vorlauf" ] && set_val "Heizung Vorlauf" temperature CurrentTemperature "$vorlauf"
[ -n "$ww_ist" ] && set_val "Warmwasser Ist" temperature CurrentTemperature "$ww_ist"
[ -n "$ww_soll" ] && set_val "Warmwasser Soll" temperature CurrentTemperature "$ww_soll"
[ -n "$stoerung" ] && set_val "Heizung Stoerung" contact ContactSensorState "$stoerung"

# --- InfluxDB: build a line-protocol record ---
fields=""
add() {
  [ -n "$2" ] && fields="${fields:+$fields,}$1=$2"
}
add aussen "$aussen"
add vorlauf "$vorlauf"
add ww_ist "$ww_ist"
add ww_soll "$ww_soll"
add kessel "$kessel"
add raum_normal "$raum_normal"
add raum_reduziert "$raum_reduziert"
add brennerstunden "$brennerstunden"
add brennerstarts "$brennerstarts"
[ -n "$stoerung" ] && fields="${fields:+$fields,}stoerung=${stoerung}i"
[ -n "$letzte" ] && fields="${fields:+$fields,}letzte_stoerung=\"$letzte\""
[ -n "$stoerung_2" ] && fields="${fields:+$fields,}stoerung_2=\"$stoerung_2\""
[ -n "$stoerung_3" ] && fields="${fields:+$fields,}stoerung_3=\"$stoerung_3\""
[ -n "$betrieb" ] && fields="${fields:+$fields,}betriebsart=\"$betrieb\",betriebsart_code=${betrieb_code}i"
[ -n "$party" ] && fields="${fields:+$fields,}party=${party}i"
add spar_m1 "$spar_m1"
add pumpe_m1 "$pumpe_m1"
add frost_m1 "$frost_m1"
add stufe2 "$stufe2"
add vorlauf_soll "$vorlauf_soll"
add neigung "$neigung"
add niveau "$niveau"
add raum_bad "$raum_bad"
add raum_kueche "$raum_kueche"
add raum_wc "$raum_wc"
add raum_schlafen "$raum_schlafen"

if [ -n "$fields" ]; then
  code=$(timeout 15 curl -s -o "$BASE/bridge_write.txt" -w '%{http_code}' -X POST \
    "$INFLUX_URL/api/v2/write?org=$INFLUX_ORG&bucket=$INFLUX_BUCKET&precision=s" \
    -H "Authorization: Token $ITOK" --data-binary "heizung $fields")
  if [ "$code" != "204" ]; then
    echo "$(date -Iseconds) Error HTTP $code: $(head -c 200 "$BASE/bridge_write.txt")" >> "$LOG"
  else
    echo "$(date -Iseconds) influx HTTP 204" >> "$LOG"
  fi
else
  echo "$(date -Iseconds) no values read (vcontrold down?)" >> "$LOG"
fi
