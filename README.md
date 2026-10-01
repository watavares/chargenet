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

## Getting started

1. Run `bootstrap/bootstrap.ps1` once to create the Terraform remote state storage.
2. Run `bootstrap/github-oidc.ps1` once per environment to create the identity GitHub Actions deploys with. The platform identity also needs `-roles Contributor,"Resource Policy Contributor"`.
3. Set the printed values as variables on the matching GitHub environment. The `platform` environment also needs `BUDGET_EMAIL`.

## CI/CD

`.github/workflows/terraform.yml` deploys `platform`, then `dev`, using the reusable `_terraform.yml`:

- **Pull request:** format check, validate and plan for each layer. Each plan is posted as a PR comment.
- **Merge to main:** the same steps, then applies exactly the plan it just made, platform first.
- **Nightly:** plans against live resources and fails if anything was changed outside Terraform (drift).

`main` is protected: changes go through a pull request, and both checks must pass before merging.

Each layer has its own deploy identity and state file. GitHub Actions logs in to Azure with OIDC federated credentials, so no client secret is stored in GitHub or anywhere else.
