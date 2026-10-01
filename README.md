# chargenet

EV charging network infrastructure.

## Layout

```
chargenet/
├── bootstrap/        # one-time setup (state storage)
├── infra/
│   └── envs/
│       └── dev/      # dev environment Terraform
├── simulator/        # charging station containers (later)
├── docs/             # diagrams, decisions, incident write-ups
└── README.md
```

## Getting started

1. Run `bootstrap/bootstrap.ps1` once to create the Terraform remote state storage.
2. Run `bootstrap/github-oidc.ps1` once per environment to create the identity GitHub Actions deploys with.
3. Set the printed values as variables on the matching GitHub environment.

## CI/CD

`.github/workflows/terraform-dev.yml` deploys `infra/envs/dev`:

- **Pull request:** format check, validate and plan. The plan is posted as a PR comment.
- **Merge to main:** the same steps, then applies exactly the plan it just made.
- **Nightly:** plans against live resources and fails if anything was changed outside Terraform (drift).

`main` is protected: changes go through a pull request, and the `terraform` check must pass before merging.

GitHub Actions logs in to Azure with OIDC federated credentials, so no client secret is stored in GitHub or anywhere else.
