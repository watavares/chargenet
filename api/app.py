"""Public, read-only status API for the station network.

Serves a status page at / and JSON at /api/*. Reads the latest reading per
station from Log Analytics with the app's managed identity (Log Analytics Reader
only). Results are cached, so traffic volume never drives query volume.
"""

import html
import os
import threading
import time
from datetime import datetime, timedelta, timezone

from azure.identity import ManagedIdentityCredential
from azure.monitor.query import LogsQueryClient, LogsQueryStatus
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse

CACHE_SECONDS = 60
SILENT_AFTER_MINUTES = 20

# Latest reading per station; a station that stopped reporting shows as Silent
QUERY = f"""
StationTelemetry_CL
| summarize arg_max(TimeGenerated, *) by StationId
| extend Status = iff(TimeGenerated < ago({SILENT_AFTER_MINUTES}m), "Silent", Status)
| project StationId, SiteId, Status, PowerKw, ErrorCode, LastSeen = TimeGenerated
| order by StationId asc
"""

app = FastAPI(title="ChargeNet status API", docs_url="/api/docs", redoc_url=None)
client = LogsQueryClient(ManagedIdentityCredential(client_id=os.environ["AZURE_CLIENT_ID"]))
workspace_id = os.environ["WORKSPACE_ID"]

_cache: dict = {"at": 0.0, "stations": []}
_lock = threading.Lock()


def stations() -> list[dict]:
    """Latest status per station, cached for CACHE_SECONDS."""
    with _lock:
        if time.monotonic() - _cache["at"] < CACHE_SECONDS:
            return _cache["stations"]
        result = client.query_workspace(workspace_id, QUERY, timespan=timedelta(days=1))
        if result.status != LogsQueryStatus.SUCCESS:
            raise HTTPException(503, "Telemetry store unavailable")
        table = result.tables[0]
        rows = [dict(zip(table.columns, row)) for row in table.rows]
        for r in rows:
            r["LastSeen"] = r["LastSeen"].isoformat()
        _cache.update(at=time.monotonic(), stations=rows)
        return rows


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    # The status page needs nothing external; the docs page loads Swagger UI from a CDN
    if request.url.path == "/":
        response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
    return response


@app.get("/healthz", include_in_schema=False)
def healthz() -> dict:
    return {"status": "ok"}


@app.get("/api/stations")
def list_stations() -> list[dict]:
    return stations()


@app.get("/api/stations/{station_id}")
def get_station(station_id: str) -> dict:
    for s in stations():
        if s["StationId"] == station_id:
            return s
    raise HTTPException(404, "Unknown station")


@app.get("/api/sites")
def list_sites() -> list[dict]:
    sites: dict[str, dict] = {}
    for s in stations():
        site = sites.setdefault(
            s["SiteId"],
            {"SiteId": s["SiteId"], "Stations": 0, "Charging": 0, "Available": 0,
             "Faulted": 0, "Silent": 0, "PowerKw": 0.0},
        )
        site["Stations"] += 1
        site[s["Status"]] = site.get(s["Status"], 0) + 1
        site["PowerKw"] = round(site["PowerKw"] + (s["PowerKw"] or 0), 1)
    return sorted(sites.values(), key=lambda x: x["SiteId"])


STATUS_COLOURS = {"Available": "#1a7f37", "Charging": "#0969da", "Faulted": "#cf222e", "Silent": "#57606a"}


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
def status_page() -> str:
    rows = stations()
    counts = {k: sum(1 for r in rows if r["Status"] == k) for k in STATUS_COLOURS}
    power_mw = sum(r["PowerKw"] or 0 for r in rows) / 1000
    tiles = "".join(
        f'<div class="tile"><b style="color:{c}">{counts[k]}</b><span>{k}</span></div>'
        for k, c in STATUS_COLOURS.items()
    )
    body = "".join(
        "<tr>"
        f"<td>{html.escape(r['StationId'])}</td>"
        f"<td>{html.escape(r['SiteId'])}</td>"
        f'<td><span class="dot" style="background:{STATUS_COLOURS.get(r["Status"], "#57606a")}"></span>'
        f"{html.escape(r['Status'])}</td>"
        f"<td class=num>{r['PowerKw'] or 0:.1f}</td>"
        f"<td>{html.escape(r['ErrorCode'] or '')}</td>"
        f"<td>{html.escape(r['LastSeen'][11:16])} UTC</td>"
        "</tr>"
        for r in rows
    )
    updated = datetime.now(timezone.utc).strftime("%H:%M UTC")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>ChargeNet status</title>
<style>
  body {{ font: 15px/1.5 system-ui, sans-serif; margin: 0 auto; max-width: 860px; padding: 24px 16px; color: #1f2328; }}
  h1 {{ font-size: 22px; margin: 0 0 4px; }}
  p.sub {{ color: #57606a; margin: 0 0 20px; }}
  .tiles {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(120px, 1fr)); gap: 12px; margin-bottom: 20px; }}
  .tile {{ border: 1px solid #d0d7de; border-radius: 8px; padding: 12px; }}
  .tile b {{ display: block; font-size: 28px; }}
  .tile span {{ color: #57606a; }}
  .wrap {{ overflow-x: auto; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ text-align: left; padding: 8px; border-bottom: 1px solid #d0d7de; white-space: nowrap; }}
  th {{ font-weight: 600; color: #57606a; }}
  .num {{ text-align: right; font-variant-numeric: tabular-nums; }}
  .dot {{ display: inline-block; width: 9px; height: 9px; border-radius: 50%; margin-right: 6px; }}
  footer {{ color: #57606a; margin-top: 20px; font-size: 13px; }}
</style></head><body>
<h1>ChargeNet station network</h1>
<p class="sub">{len(rows)} stations · {power_mw:.2f} MW drawn now · updated {updated}</p>
<div class="tiles">{tiles}</div>
<div class="wrap"><table>
<thead><tr><th>Station</th><th>Site</th><th>Status</th><th class=num>Power (kW)</th><th>Error</th><th>Last report</th></tr></thead>
<tbody>{body}</tbody></table></div>
<footer>Simulated telemetry. JSON: <a href="/api/stations">/api/stations</a> · <a href="/api/sites">/api/sites</a> · <a href="/api/docs">API docs</a></footer>
</body></html>"""
