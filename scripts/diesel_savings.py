#!/usr/bin/env python3
"""Monthly comparison: energy charged in the EV (kWh) converted into the diesel
price it would have cost. Run daily from cron, e.g. at 06:10.

Rule of thumb used here: 1 l diesel ~ 3 kWh of EV energy (5 l per 100 km at 15 kWh per 100 km).
Writes the result as measurement `diesel_ersparnis` into the bucket `heizung_tage`.
"""
import csv
import io
import os
import subprocess
import urllib.request
from datetime import datetime, timezone

BASE = os.environ.get("BASE", "/opt/heating")
INFLUX_URL = os.environ.get("INFLUX_URL", "http://127.0.0.1:8086")
ITOK = open(os.path.join(BASE, "influx_token")).read().strip()
KWH_PER_LITER = 3.0


def flux_query(flux):
    """Run a Flux query inside the influxdb container and return rows as dicts."""
    out = subprocess.run(
        ["docker", "exec", "influxdb", "influx", "query", "--raw", flux],
        capture_output=True, text=True,
    ).stdout
    rows, header = [], None
    for r in csv.reader(io.StringIO(out)):
        if not r or r[0].startswith("#"):
            continue
        if "_time" in r and "_value" in r:
            header = r
            continue
        if header:
            rows.append(dict(zip(header, r)))
    return rows


kwh_rows = flux_query(
    'from(bucket: "homeassistant") |> range(start: -400d) '
    '|> filter(fn: (r) => r._measurement == "wallbox_session" and r._field == "energy_kwh") '
    '|> aggregateWindow(every: 1mo, fn: sum, createEmpty: false)'
)
price_rows = flux_query(
    'from(bucket: "heizung_tage") |> range(start: -400d) '
    '|> filter(fn: (r) => r._measurement == "diesel_preis" and r._field == "preis_eur_l") '
    '|> aggregateWindow(every: 1mo, fn: mean, createEmpty: false)'
)

kwh_by_month, price_by_month = {}, {}
for r in kwh_rows:
    m = r["_time"][:7]
    kwh_by_month[m] = kwh_by_month.get(m, 0.0) + float(r["_value"])
for r in price_rows:
    price_by_month[r["_time"][:7]] = float(r["_value"])

lines = []
for month in sorted(kwh_by_month):
    if month not in price_by_month:
        continue
    kwh = kwh_by_month[month]
    price = price_by_month[month]
    liters = kwh / KWH_PER_LITER
    eur = liters * price
    ts = int(datetime.strptime(month + "-01", "%Y-%m-%d").replace(tzinfo=timezone.utc).timestamp())
    lines.append(
        f"diesel_ersparnis kwh={kwh:.3f},preis_eur_l={price:.4f},eur={eur:.2f},liter={liters:.2f} {ts}"
    )

req = urllib.request.Request(
    f"{INFLUX_URL}/api/v2/write?org=home&bucket=heizung_tage&precision=s",
    data="\n".join(lines).encode(),
    headers={"Authorization": f"Token {ITOK}"},
    method="POST",
)
urllib.request.urlopen(req, timeout=60)
print("Months written:", len(lines))
