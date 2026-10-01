"""Simulated EV charging stations reporting telemetry to Azure IoT Hub over MQTT.

Each run sends one status message per station, then exits; a scheduler (Container
Apps Job) runs it every few minutes. Stations are registered in IoT Hub on first
use, so adding stations needs no manual setup.

Auth: one IoT Hub shared access policy with RegistryWrite + DeviceConnect, the
pattern used by gateways that connect on behalf of many devices.
"""

import base64
import hashlib
import hmac
import json
import os
import random
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import paho.mqtt.client as mqtt

API_VERSION = "2021-04-12"
SITES = ["ams-depot", "rtm-port", "utr-hub"]
MAX_POWER_KW = 400  # megawatt-class truck chargers run higher; 400 kW keeps numbers readable
# Chance per station per hour of an incident that lasts the rest of that hour.
# With 10 stations that's roughly one faulted and one offline station a day each.
FAULT_CHANCE = 0.005
OFFLINE_CHANCE = 0.005


def incident(station_id: str) -> str | None:
    """Faulted/Offline state that persists for the whole hour, like a real outage.

    Seeded by station and hour, so every run within the hour agrees without
    the simulator having to store any state.
    """
    hour = datetime.now(timezone.utc).strftime("%Y%m%d%H")
    roll = random.Random(f"{station_id}:{hour}").random()
    if roll < OFFLINE_CHANCE:
        return "Offline"
    if roll < OFFLINE_CHANCE + FAULT_CHANCE:
        return "Faulted"
    return None


def parse_connection_string(conn: str) -> dict:
    return dict(part.split("=", 1) for part in conn.split(";") if part)


def sas_token(uri: str, key: str, policy: str, ttl: int = 3600) -> str:
    """IoT Hub SAS token: HMAC-SHA256 over the URL-encoded resource URI and expiry."""
    expiry = int(time.time() + ttl)
    resource = urllib.parse.quote_plus(uri.lower())
    to_sign = f"{resource}\n{expiry}".encode()
    sig = base64.b64encode(hmac.new(base64.b64decode(key), to_sign, hashlib.sha256).digest())
    return (
        f"SharedAccessSignature sr={resource}&sig={urllib.parse.quote_plus(sig)}"
        f"&se={expiry}&skn={policy}"
    )


def ensure_device(host: str, key: str, policy: str, device_id: str) -> None:
    """Register the device in IoT Hub; 409 means it already exists."""
    body = json.dumps({"deviceId": device_id, "authentication": {"type": "sas"}}).encode()
    req = urllib.request.Request(
        f"https://{host}/devices/{device_id}?api-version={API_VERSION}",
        data=body,
        method="PUT",
        headers={"Authorization": sas_token(host, key, policy), "Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=15)
        print(f"registered {device_id}")
    except urllib.error.HTTPError as e:
        if e.code != 409:
            raise


def reading(station_id: str, site: str, faulted: bool) -> dict:
    status = "Faulted" if faulted else random.choice(["Available", "Charging"])
    power = round(random.uniform(50, MAX_POWER_KW), 1) if status == "Charging" else 0.0
    return {
        "stationId": station_id,
        "siteId": site,
        "status": status,
        "powerKw": power,
        # kWh delivered over the last 5-minute interval
        "energyKwh": round(power * 5 / 60, 2),
        "errorCode": "GroundFailure" if status == "Faulted" else None,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


def send(host: str, key: str, policy: str, device_id: str, payload: dict) -> None:
    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2, client_id=device_id, protocol=mqtt.MQTTv311
    )
    client.username_pw_set(
        f"{host}/{device_id}/?api-version={API_VERSION}",
        sas_token(f"{host}/devices/{device_id}", key, policy),
    )
    client.tls_set(cert_reqs=ssl.CERT_REQUIRED, tls_version=ssl.PROTOCOL_TLS_CLIENT)
    client.connect(host, 8883)
    client.loop_start()
    # Content type properties let IoT Hub routing query the JSON body
    topic = f"devices/{device_id}/messages/events/$.ct=application%2Fjson&$.ce=utf-8"
    client.publish(topic, json.dumps(payload), qos=1).wait_for_publish(timeout=15)
    client.loop_stop()
    client.disconnect()


def main() -> None:
    conn = parse_connection_string(os.environ["IOTHUB_CONNECTION_STRING"])
    host, key, policy = conn["HostName"], conn["SharedAccessKey"], conn["SharedAccessKeyName"]
    count = int(os.environ.get("STATION_COUNT", "10"))

    for i in range(1, count + 1):
        station_id = f"station-{i:03d}"
        site = SITES[(i - 1) % len(SITES)]
        state = incident(station_id)
        if state == "Offline":
            # A real offline charger sends nothing; the silent-station alert catches it
            print(f"{station_id} offline, not reporting")
            continue
        ensure_device(host, key, policy, station_id)
        payload = reading(station_id, site, faulted=state == "Faulted")
        send(host, key, policy, station_id, payload)
        print(json.dumps(payload))


if __name__ == "__main__":
    main()
