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

1. Run `bootstrap/` once to create the Terraform remote state storage.
2. Apply `infra/envs/dev/` for the dev environment.
