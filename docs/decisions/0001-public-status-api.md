# 0001: Exposing the status API to the internet

**Status:** accepted · **Date:** 2026-10-01

## Context

The platform needs a public, read-only status page and JSON API for the station network. Subscription policy denies public IP addresses, so anything internet-facing has to be a deliberate decision rather than an accident.

The API reads the latest reading per station from Log Analytics. The data is simulated and non-sensitive, but the endpoint is still a public attack surface and a potential cost driver.

## Options

| Option | How it works | Approx. cost/month | Notes |
|---|---|---|---|
| Application Gateway (WAF v2) in the hub | Public IP on a gateway in the hub, forwarding to an internal, VNet-integrated app | €150+ | Common enterprise pattern. Needs a policy exemption for the public IP. |
| Front Door Premium + Private Link | Global edge with WAF, private connection to an internal app | €300+ | Best fit for production: no public origin at all. |
| Container Apps built-in ingress | HTTPS endpoint on Azure's shared ingress; no public IP resource in the subscription | ~€0 | Origin is public, protected only by app-level controls. |

## Decision

Use **Container Apps built-in ingress** for the dev environment, with these controls:

- **Read-only identity:** the app runs as its own managed identity with only Log Analytics Reader. It does not share the processor's identity, which can write.
- **Bounded cost:** at most one replica; scales to zero when idle.
- **Bounded load:** query results are cached for 60 seconds, so traffic volume never drives query volume.
- **HTTPS only,** with security headers (no framing, no sniffing, strict content security policy on the status page).
- **Reviewed in code:** exposure is defined in `infra/envs/dev/api.tf` and changes only through a pull request.

## Consequences

- The deny-public-IP policy does not catch this endpoint, because the address belongs to Azure's shared ingress, not the subscription. The control is this decision plus code review, not the policy. A policy-only view of exposure would miss it, and that's worth knowing when auditing.
- There is no WAF. Acceptable for simulated, read-only data; not for production.
- Cold starts take a few seconds after idle periods.

## Revisit when

- The API serves real or customer data, or anything that writes.
- Acceptance and production environments are added: production should move to an internal, VNet-integrated Container Apps environment behind **Front Door Premium with Private Link**, with WAF rules and the policy exemption, if any, recorded here.
