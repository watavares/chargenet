"""Public, read-only status site and API for the station network.

Serves a status page at / and JSON at /api/*. Reads from Log Analytics with the
app's managed identity (Log Analytics Reader only). All queries refresh together
at most once per CACHE_SECONDS, so traffic volume never drives query volume.
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
HISTORY_HOURS = 6
REPO_URL = "https://github.com/watavares/chargenet"

SITE_NAMES = {"ams-depot": "Amsterdam depot", "rtm-port": "Rotterdam port", "utr-hub": "Utrecht hub"}
STATUSES = ["Available", "Charging", "Faulted", "Silent"]

QUERIES = {
    # Latest reading per station; a station that stopped reporting shows as Silent
    "stations": f"""
        StationTelemetry_CL
        | summarize arg_max(TimeGenerated, *) by StationId
        | extend Status = iff(TimeGenerated < ago({SILENT_AFTER_MINUTES}m), "Silent", Status)
        | project StationId, SiteId, Status, PowerKw, ErrorCode, LastSeen = TimeGenerated
        | order by StationId asc""",
    # Each station reports once per 5 minutes, so a 5-minute sum is the site's power draw
    "history": f"""
        StationTelemetry_CL
        | where TimeGenerated > ago({HISTORY_HOURS}h)
        | summarize PowerKw = round(sum(PowerKw), 1) by SiteId, Time = bin(TimeGenerated, 5m)
        // Recent slots are still filling (processing delay); stop at the last complete one
        | where Time <= bin(ago(10m), 5m)
        | order by Time asc""",
    "today": """
        StationTelemetry_CL
        | where TimeGenerated > startofday(now())
        | summarize EnergyKwh = round(sum(EnergyKwh), 1) by SiteId""",
    # One row per station per hour with a fault: the simulator's incidents last the hour
    "incidents": """
        StationTelemetry_CL
        | where TimeGenerated > ago(24h) and Status == "Faulted"
        | summarize From = min(TimeGenerated), To = max(TimeGenerated)
            by StationId, SiteId, ErrorCode, Hour = bin(TimeGenerated, 1h)
        | project-away Hour
        | order by From desc
        | take 10""",
}

app = FastAPI(title="ChargeNet status API", docs_url="/api/docs", redoc_url=None)
client = LogsQueryClient(ManagedIdentityCredential(client_id=os.environ["AZURE_CLIENT_ID"]))
workspace_id = os.environ["WORKSPACE_ID"]

_state: dict = {"at": 0.0, "data": None}
_lock = threading.Lock()


def _rows(query: str) -> list[dict]:
    result = client.query_workspace(workspace_id, query, timespan=timedelta(days=1))
    if result.status != LogsQueryStatus.SUCCESS:
        raise HTTPException(503, "Telemetry store unavailable")
    table = result.tables[0]
    return [dict(zip(table.columns, row)) for row in table.rows]


def snapshot() -> dict:
    """All data the site needs, refreshed together at most once per CACHE_SECONDS."""
    with _lock:
        if _state["data"] is None or time.monotonic() - _state["at"] >= CACHE_SECONDS:
            data = {name: _rows(q) for name, q in QUERIES.items()}
            data["updated"] = datetime.now(timezone.utc)
            # Swap in a complete new snapshot; requests already rendering keep the old one
            _state["data"], _state["at"] = data, time.monotonic()
        return _state["data"]


def _iso(rows: list[dict], *keys: str) -> list[dict]:
    return [{k: (v.isoformat() if k in keys and v else v) for k, v in r.items()} for r in rows]


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
    """Latest status per station. Silent means no report for 20+ minutes."""
    return _iso(snapshot()["stations"], "LastSeen")


@app.get("/api/stations/{station_id}")
def get_station(station_id: str) -> dict:
    for s in list_stations():
        if s["StationId"] == station_id:
            return s
    raise HTTPException(404, "Unknown station")


@app.get("/api/sites")
def list_sites() -> list[dict]:
    """Per site: station counts by status, power now and energy delivered today."""
    data = snapshot()
    energy = {r["SiteId"]: r["EnergyKwh"] or 0.0 for r in data["today"]}
    sites: dict[str, dict] = {}
    for s in data["stations"]:
        site = sites.setdefault(
            s["SiteId"],
            {"SiteId": s["SiteId"], "Name": SITE_NAMES.get(s["SiteId"], s["SiteId"]),
             "Stations": 0, **{k: 0 for k in STATUSES}, "PowerKw": 0.0,
             "EnergyTodayKwh": energy.get(s["SiteId"], 0.0)},
        )
        site["Stations"] += 1
        site[s["Status"]] = site.get(s["Status"], 0) + 1
        site["PowerKw"] = round(site["PowerKw"] + (s["PowerKw"] or 0), 1)
    return sorted(sites.values(), key=lambda x: x["SiteId"])


@app.get("/api/history")
def history() -> list[dict]:
    """Power drawn per site in 5-minute steps over the last 6 hours."""
    return _iso(snapshot()["history"], "Time")


@app.get("/api/incidents")
def incidents() -> list[dict]:
    """Station faults in the last 24 hours, newest first (at most 10)."""
    return _iso(snapshot()["incidents"], "From", "To")


# ---------- Status page ----------

def _esc(value) -> str:
    return html.escape(str(value if value is not None else ""))


def _sparkline(points: list[float], width: int = 300, height: int = 56) -> str:
    """Inline SVG area chart; no scripts or external assets, so the CSP stays strict."""
    if len(points) < 2:
        return '<p class="muted small">Not enough data yet.</p>'
    top = max(max(points), 1.0)
    step = width / (len(points) - 1)
    coords = [(i * step, height - 4 - (p / top) * (height - 8)) for i, p in enumerate(points)]
    line = " ".join(f"{x:.1f},{y:.1f}" for x, y in coords)
    area = f"0,{height} {line} {width},{height}"
    return (
        f'<svg class="spark" viewBox="0 0 {width} {height}" preserveAspectRatio="none" role="img" '
        f'aria-label="Power over the last {HISTORY_HOURS} hours, peak {top:.0f} kW">'
        f'<polygon points="{area}" class="spark-fill"/>'
        f'<polyline points="{line}" class="spark-line"/></svg>'
    )


def _station_tile(s: dict) -> str:
    number = _esc(s["StationId"].removeprefix("station-"))
    status = _esc(s["Status"])
    detail = f'{s["PowerKw"]:.0f} kW' if s["Status"] == "Charging" else (s["ErrorCode"] or s["Status"])
    return (
        f'<li class="station st-{status.lower()}" title="{_esc(s["StationId"])}: {status}">'
        f'<span class="num">#{number}</span><span class="state">{status}</span>'
        f'<span class="detail">{_esc(detail)}</span></li>'
    )


def _site_card(site: dict, stations: list[dict], points: list[float]) -> str:
    tiles = "".join(_station_tile(s) for s in stations)
    return f"""
    <section class="card">
      <header class="card-head">
        <h2>{_esc(site["Name"])}</h2>
        <span class="muted small">{site["Stations"]} stations</span>
      </header>
      <div class="figures">
        <div><b>{site["PowerKw"]:.0f}</b><span>kW now</span></div>
        <div><b>{site["EnergyTodayKwh"]:,.0f}</b><span>kWh today</span></div>
      </div>
      {_sparkline(points)}
      <p class="muted small axis"><span>{HISTORY_HOURS}h ago</span><span>now</span></p>
      <ul class="stations">{tiles}</ul>
    </section>"""


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
def status_page() -> str:
    data = snapshot()
    stations, sites = data["stations"], list_sites()
    total = len(stations)
    online = sum(1 for s in stations if s["Status"] in ("Available", "Charging"))
    power_mw = sum(s["PowerKw"] or 0 for s in stations) / 1000
    energy_mwh = sum(r["EnergyKwh"] or 0 for r in data["today"]) / 1000
    availability = f"{online / total:.0%}" if total else "n/a"

    if online == total and total:
        banner = '<div class="banner ok">All stations operational</div>'
    else:
        down = total - online
        banner = f'<div class="banner warn">{down} station{"s" if down != 1 else ""} need attention</div>'

    cards = "".join(
        _site_card(
            site,
            [s for s in stations if s["SiteId"] == site["SiteId"]],
            [h["PowerKw"] for h in data["history"] if h["SiteId"] == site["SiteId"]],
        )
        for site in sites
    )

    if data["incidents"]:
        rows = "".join(
            "<tr>"
            f'<td>{_esc(i["StationId"])}</td>'
            f'<td>{_esc(SITE_NAMES.get(i["SiteId"], i["SiteId"]))}</td>'
            f'<td>{_esc(i["ErrorCode"])}</td>'
            f'<td>{i["From"]:%H:%M}</td><td>{i["To"]:%H:%M}</td>'
            "</tr>"
            for i in data["incidents"]
        )
        incidents_html = (
            '<div class="wrap"><table><thead><tr><th>Station</th><th>Site</th><th>Error</th>'
            f"<th>From (UTC)</th><th>Last seen (UTC)</th></tr></thead><tbody>{rows}</tbody></table></div>"
        )
    else:
        incidents_html = '<p class="muted">No faults in the last 24 hours.</p>'

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<meta name="description" content="Live status of the ChargeNet simulated truck charging network.">
<title>ChargeNet status</title>
<style>
  :root {{
    --bg: #f6f8fa; --card: #ffffff; --text: #1f2328; --muted: #59636e; --border: #d1d9e0;
    --ok: #1a7f37; --charge: #0969da; --fault: #cf222e; --silent: #59636e; --accent: #0969da;
    color-scheme: light;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #0d1117; --card: #161b22; --text: #e6edf3; --muted: #9198a1; --border: #3d444d;
      --ok: #3fb950; --charge: #4493f8; --fault: #f85149; --silent: #9198a1; --accent: #4493f8;
      color-scheme: dark;
    }}
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }}
  main {{ max-width: 1100px; margin: 0 auto; padding: 24px 16px 40px; }}
  h1 {{ font-size: 26px; margin: 0; letter-spacing: -0.01em; }}
  h2 {{ font-size: 17px; margin: 0; }}
  h3 {{ font-size: 17px; margin: 32px 0 12px; }}
  .muted {{ color: var(--muted); }}
  .small {{ font-size: 13px; }}
  .top {{ display: flex; flex-wrap: wrap; justify-content: space-between; align-items: baseline; gap: 8px; margin-bottom: 16px; }}
  .banner {{ border-radius: 8px; padding: 10px 14px; font-weight: 600; margin-bottom: 16px; border: 1px solid; }}
  .banner.ok {{ color: var(--ok); border-color: var(--ok); }}
  .banner.warn {{ color: var(--fault); border-color: var(--fault); }}
  .kpis {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-bottom: 24px; }}
  .kpi, .card {{ background: var(--card); border: 1px solid var(--border); border-radius: 10px; }}
  .kpi {{ padding: 14px 16px; }}
  .kpi b {{ display: block; font-size: 28px; font-variant-numeric: tabular-nums; }}
  .kpi span {{ color: var(--muted); font-size: 13px; }}
  .sites {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px; }}
  .card {{ padding: 16px; }}
  .card-head {{ display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 12px; }}
  .figures {{ display: flex; gap: 24px; margin-bottom: 8px; }}
  .figures b {{ font-size: 22px; font-variant-numeric: tabular-nums; margin-right: 4px; }}
  .figures span {{ color: var(--muted); font-size: 13px; }}
  .spark {{ display: block; width: 100%; height: 56px; }}
  .spark-line {{ fill: none; stroke: var(--accent); stroke-width: 2; vector-effect: non-scaling-stroke; }}
  .spark-fill {{ fill: var(--accent); opacity: 0.12; }}
  .axis {{ display: flex; justify-content: space-between; margin: 2px 0 12px; }}
  .stations {{ list-style: none; padding: 0; margin: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(84px, 1fr)); gap: 8px; }}
  .station {{ border: 1px solid var(--border); border-left: 4px solid var(--silent); border-radius: 6px; padding: 6px 8px; font-size: 12px; line-height: 1.35; }}
  .station .num {{ display: block; font-weight: 600; font-size: 13px; }}
  .station .state {{ display: block; font-weight: 600; }}
  .station .detail {{ display: block; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
  .st-available {{ border-left-color: var(--ok); }} .st-available .state {{ color: var(--ok); }}
  .st-charging {{ border-left-color: var(--charge); }} .st-charging .state {{ color: var(--charge); }}
  .st-faulted {{ border-left-color: var(--fault); }} .st-faulted .state {{ color: var(--fault); }}
  .st-silent .state {{ color: var(--silent); }}
  .wrap {{ overflow-x: auto; background: var(--card); border: 1px solid var(--border); border-radius: 10px; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--border); white-space: nowrap; }}
  tr:last-child td {{ border-bottom: 0; }}
  th {{ color: var(--muted); font-weight: 600; font-size: 13px; }}
  a {{ color: var(--accent); }}
  footer {{ margin-top: 32px; color: var(--muted); font-size: 13px; display: flex; flex-wrap: wrap; gap: 6px 16px; }}
</style></head><body><main>
<div class="top">
  <div><h1>ChargeNet</h1><span class="muted">Live status of a simulated truck charging network</span></div>
  <span class="muted small">Updated {data["updated"]:%H:%M} UTC · refreshes every minute</span>
</div>
{banner}
<div class="kpis">
  <div class="kpi"><b>{online}/{total}</b><span>stations online</span></div>
  <div class="kpi"><b>{power_mw:.2f}</b><span>MW drawn now</span></div>
  <div class="kpi"><b>{energy_mwh:.2f}</b><span>MWh delivered today</span></div>
  <div class="kpi"><b>{availability}</b><span>network availability</span></div>
</div>
<div class="sites">{cards}</div>
<h3>Recent incidents</h3>
{incidents_html}
<footer>
  <span>Simulated telemetry, Azure IoT Hub → Log Analytics</span>
  <a href="/api/stations">JSON API</a><a href="/api/docs">API docs</a><a href="{REPO_URL}">Source on GitHub</a>
</footer>
</main></body></html>"""
