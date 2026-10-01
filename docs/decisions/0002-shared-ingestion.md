# 0002: One shared ingestion point for all environments

**Status:** accepted · **Date:** 2026-10-02

## Context

The platform is growing from one environment to three: dev, acceptance and production. Each needs station telemetry to test the processor, API, dashboard and alerts.

There is one fleet of stations. Real chargers don't come in dev and production versions: they report to one place. IoT Hub's Free tier also allows only one hub per subscription; a paid hub per environment would cost about €9–22 a month each.

## Options

| Option | Cost/month | Notes |
|---|---|---|
| A hub per environment (Basic/Standard tier for acc and prod) | €18–44 | Full isolation, but non-production needs its own simulated fleet anyway. |
| A subscription per environment, each with a free hub | €0 | The enterprise landing-zone pattern, but needs subscription vending and management groups: out of scope for now. |
| **One shared hub; each environment reads through its own consumer group** | €0 | Mirrors reality: one fleet, one ingestion point, several independent readers. |

## Decision

One IoT Hub in a shared **field** layer (`rg-chargenet-field`, owned by `infra/platform`), together with the station simulator. For each environment, the platform vends:

- a **consumer group**, so each environment has its own independent read position in the stream
- a **read-only key** (ServiceConnect) scoped to that environment's reader policy

Environments read their connection details from the platform's Terraform state.

## Consequences

- **No cross-environment impact:** a consumer group only reads. A bug in dev cannot consume, delete or delay production's messages.
- **Non-production sees production telemetry.** Fine for simulated data. With real data this would need a data-handling sign-off, or anonymised or synthetic data for non-production.
- **Shared fate for ingestion:** an IoT Hub outage affects every environment. Acceptable for a platform service, the same way all environments share DNS.
- **Secrets travel through Terraform state.** Each environment's reader key is a sensitive output of the platform state. Today every pipeline identity can read and write the whole state container, so the dev pipeline could, in principle, read or tamper with platform state. **Follow-up:** split state into one container per layer and scope each pipeline identity's Storage Blob Data role to its own container (read-only on the platform's).

## Revisit when

- Real customer data flows through the hub.
- Environments move to separate subscriptions.
- Message volume outgrows the Free tier (8,000 messages/day).
