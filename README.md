# chargenet

EV charging network infrastructure.

## Layout

```
chargenet/
├── bootstrap/        # one-time setup (state storage, deploy identities)
├── infra/
│   ├── platform/     # shared foundations: policy, budget, hub network
│   └── envs/
│       └── dev/      # dev environment Terraform
├── simulator/        # charging station containers (later)
├── docs/             # diagrams, decisions, incident write-ups
└── README.md
```

## Platform guardrails

`infra/platform` applies to the whole subscription:

- **Azure Policy (Deny):** resources only in `northeurope`, every resource group tagged with `project` and `env`, and no public IP addresses.
- **Budget:** email alerts at 50%, 80% and 100% of the monthly budget, plus a forecast alert.
- **Hub network:** `vnet-chargenet-hub` (10.0.0.0/16). Each environment's spoke VNet peers to it, and the VPN gateway goes in its `GatewaySubnet`.
- **Environment vending:** for each entry in `var.environments`, the platform creates the environment's resource group, a spoke VNet in a separate network resource group (with an NSG per subnet, peered to the hub), and gives the environment's deploy identity Contributor on its resource group only. Environment pipelines deploy workloads but can't change the network.

| Network | Address space |
|---|---|
| hub | 10.0.0.0/16 |
| dev | 10.1.0.0/16 (`snet-apps` 10.1.0.0/23, `snet-private-endpoints` 10.1.2.0/24) |

## Station simulator

`simulator/` stands in for charging stations in the field. Every 5 minutes a Container Apps Job runs it, and each of 10 stations across 3 sites sends one status message to IoT Hub over MQTT (TLS, port 8883):

```json
{"stationId": "station-004", "siteId": "ams-depot", "status": "Charging", "powerKw": 312.5, "energyKwh": 26.04, "errorCode": null, "timestamp": "..."}
```

- **Not in the VNet, on purpose:** real chargers reach IoT Hub over the internet.
- **Auth:** an IoT Hub shared access policy with RegistryWrite + DeviceConnect, the gateway pattern. Stations register themselves on first use.
- **Incidents:** a station occasionally goes Faulted or Offline for the rest of an hour, like a real outage. Offline stations send nothing at all.
- **Cost:** IoT Hub Free tier (8,000 messages/day, which caps `station_count` at 25), and Container Apps Job runtime within the monthly free grant. The image is public on GitHub Container Registry.

## Telemetry and alerts

```
stations ──► IoT Hub ──► processor (every 5 min) ──► StationTelemetry_CL ──► alert rules ──► email
                             └── checkpoints in blob storage
```

`processor/` reads new messages from IoT Hub's Event Hub-compatible endpoint, writes them to the `StationTelemetry_CL` Log Analytics table through the Logs Ingestion API, and checkpoints only after a successful write, so a failed run re-reads instead of losing messages.

- **Auth:** the IoT Hub endpoint only supports keys, so the processor gets a read-only (ServiceConnect) key. Checkpoint storage (shared keys disabled) and Log Analytics use the workload's managed identity, which the platform layer vends with exactly those two data roles.
- **Alerts** (one per station, auto-resolving, emailed to `ALERT_EMAIL`):
  - **Station faulted:** every reading for 20 minutes says Faulted.
  - **Station silent:** a station seen in the last day has sent nothing for 20 minutes. If the simulator or processor stops, every station goes silent, so this also catches pipeline failures.

Example query:

```kql
StationTelemetry_CL
| summarize arg_max(TimeGenerated, *) by StationId
| project StationId, SiteId, Status, PowerKw, LastSeen = TimeGenerated
| order by StationId asc
```

## Getting started

1. Run `bootstrap/bootstrap.ps1` once to create the Terraform remote state storage.
2. Run `bootstrap/github-oidc.ps1` once per environment to create the identity GitHub Actions deploys with. The platform identity also needs `-roles Contributor,"Resource Policy Contributor" -allowRoleAssignments`, which grants RBAC Administrator with a condition that blocks assigning Owner, User Access Administrator or RBAC Administrator.
3. Set the printed values as variables on the matching GitHub environment. The `platform` environment also needs `BUDGET_EMAIL`.

## CI/CD

`.github/workflows/terraform.yml` deploys `platform`, then `dev`, using the reusable `_terraform.yml`:

- **Pull request:** format check, validate and plan for each layer. Each plan is posted as a PR comment.
- **Merge to main:** the same steps, then applies exactly the plan it just made, platform first.
- **Nightly:** plans against live resources and fails if anything was changed outside Terraform (drift).

`main` is protected: changes go through a pull request, and both checks must pass before merging.

Each layer has its own deploy identity and state file. GitHub Actions logs in to Azure with OIDC federated credentials, so no client secret is stored in GitHub or anywhere else.
