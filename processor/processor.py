"""Moves station telemetry from IoT Hub into Log Analytics.

Each run reads every message received since the last checkpoint, writes them as
rows to the StationTelemetry_CL table (Logs Ingestion API), checkpoints, and exits
once all partitions are idle. A scheduler (Container Apps Job) runs it every few
minutes.

Auth: IoT Hub's Event Hub-compatible endpoint only supports shared access keys,
so that's a secret. Checkpoint storage and Log Analytics use the workload's
managed identity, so there are no other secrets.
"""

import os
import sys
import threading

from azure.eventhub import EventHubConsumerClient
from azure.eventhub.extensions.checkpointstoreblob import BlobCheckpointStore
from azure.identity import ManagedIdentityCredential
from azure.monitor.ingestion import LogsIngestionClient

HARD_STOP_SECONDS = 90  # finish well inside the job's 120 s timeout


def to_row(event) -> dict | None:
    try:
        body = event.body_as_json()
        return {
            "TimeGenerated": body["timestamp"],
            "StationId": body["stationId"],
            "SiteId": body["siteId"],
            "Status": body["status"],
            "PowerKw": body["powerKw"],
            "EnergyKwh": body["energyKwh"],
            "ErrorCode": body.get("errorCode"),
            "EnqueuedTime": event.enqueued_time.isoformat(),
        }
    except (ValueError, KeyError, TypeError) as e:
        print(f"skipping malformed message: {e}")
        return None


def main() -> int:
    credential = ManagedIdentityCredential(client_id=os.environ["AZURE_CLIENT_ID"])
    consumer = EventHubConsumerClient.from_connection_string(
        os.environ["EVENTHUB_CONNECTION_STRING"],
        consumer_group=os.environ["CONSUMER_GROUP"],
        checkpoint_store=BlobCheckpointStore(
            blob_account_url=os.environ["CHECKPOINT_ACCOUNT_URL"],
            container_name=os.environ["CHECKPOINT_CONTAINER"],
            credential=credential,
        ),
    )
    logs = LogsIngestionClient(endpoint=os.environ["DCE_ENDPOINT"], credential=credential)
    rule_id, stream = os.environ["DCR_IMMUTABLE_ID"], os.environ["DCR_STREAM"]

    partitions = consumer.get_partition_ids()
    idle: dict[str, bool] = {}
    stats = {"rows": 0, "errors": 0}
    lock = threading.Lock()

    def stop() -> None:
        threading.Thread(target=consumer.close, daemon=True).start()

    def on_event_batch(ctx, events) -> None:
        if events:
            rows = [r for r in (to_row(e) for e in events) if r]
            if rows:
                logs.upload(rule_id=rule_id, stream_name=stream, logs=rows)
            # Only after a successful upload, so a failed run re-reads the same messages
            ctx.update_checkpoint()
            with lock:
                stats["rows"] += len(rows)
                idle[ctx.partition_id] = False
            return
        # An empty batch means the partition has nothing new: stop once all are idle
        with lock:
            idle[ctx.partition_id] = True
            if len(idle) == len(partitions) and all(idle.values()):
                stop()

    def on_error(ctx, error) -> None:
        with lock:
            stats["errors"] += 1
        print(f"error on partition {getattr(ctx, 'partition_id', '?')}: {error}")

    timer = threading.Timer(HARD_STOP_SECONDS, stop)
    timer.daemon = True  # don't keep the process alive once work is done
    timer.start()
    with consumer:
        consumer.receive_batch(
            on_event_batch=on_event_batch,
            on_error=on_error,
            max_batch_size=500,
            max_wait_time=5,
            starting_position="-1",  # first run: everything IoT Hub still retains
        )

    print(f"ingested {stats['rows']} rows, {stats['errors']} errors")
    # A non-zero exit marks the job execution as Failed, so problems are visible
    return 1 if stats["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
