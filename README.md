# azure-devops-portfolio-infra

Reproducible Azure infrastructure (Bicep + GitHub Actions) for a trading
bot running as an I/O-bound process (WebSocket + state persistence) on a
single small VM.

Built as a DevOps portfolio project and as hands-on preparation for the
**AZ-104 (Azure Administrator Associate)** certification. See
`docs/ARCHITECTURE.md` for the mapping to exam domains and the reasoning
behind each design decision.

## Operating model: deploy-on-demand (ephemeral infra)

Unlike a "VM runs 24/7" pattern (the model used by the original project on
Oracle Cloud), this infrastructure is **designed to be stood up and torn
down on demand**:

- `deploy.yml` — provisions the entire infrastructure with a single command
  (`az deployment sub create`), with no manual clicking in the portal.
- `teardown.yml` — deletes the resource group (and therefore everything in
  it) with a single command, whenever the VM isn't currently needed.

This is a deliberate choice for two reasons:

1. **Cost** — Azure only gives away a free B1S VM for 12 months from
   account creation (unlike Oracle Always Free, which has no time limit).
   Tearing down the infrastructure when it's not in use stretches that free
   allowance further and avoids charges once it runs out.
2. **Portfolio value** — reproducible, code-driven infrastructure ("cattle,
   not pets") is exactly what demonstrates real DevOps value in an
   interview, as opposed to a machine that was clicked together once by
   hand and left running forever.

## Two repositories — why

| Repo | Visibility | Contents |
|---|---|---|
| **`azure-devops-portfolio-infra`** (this repo) | **Public** | Bicep, GitHub Actions, architecture docs, systemd unit template. Zero secrets, zero trading logic. |
| **`trading-strategy-azure`** (separate repo) | **Private** | The actual strategy code (entry/exit logic, scoring). Designed in parallel in a separate chat. |

Reasoning: the infrastructure code *is* the thing you want to show an
employer — it can be public with no risk. The strategy code only has value
if it stays unique, so it stays private, exactly like the strategy already
running on Oracle.

The two repos are wired together in the `deploy-app.yml` workflow (see
`.github/workflows/`): the public repo defines *where* and *how* to deploy
(infrastructure, target path, systemd service definition), while the
private repo supplies *what* to deploy (the actual `strategy.py` file). See
`docs/RUNBOOK.md`, section "Connecting the two repos".

## Repo layout

```
infra-public/
├── bicep/
│   ├── main.bicep              # subscription-scope, orchestrates all modules
│   ├── modules/
│   │   ├── network.bicep       # VNet, subnet, NSG
│   │   ├── vm.bicep            # VM B1S + Managed Identity + NIC
│   │   ├── keyvault.bicep      # Key Vault + RBAC for the Managed Identity
│   │   └── monitor.bicep       # Log Analytics + VM Insights + alert
│   └── parameters/
│       └── main.parameters.json
├── .github/workflows/
│   ├── deploy.yml               # workflow_dispatch: stand up the infrastructure
│   ├── teardown.yml             # workflow_dispatch: tear the infrastructure down
│   └── deploy-app.yml           # deploy the strategy code onto the existing VM
├── scripts/
│   └── bootstrap-oidc.sh        # one-time OIDC setup (no secrets stored in GH)
├── systemd/
│   └── trading-strategy.service # pattern carried over from Oracle
└── docs/
    ├── ARCHITECTURE.md          # mapping to AZ-104 exam domains
    └── RUNBOOK.md                # how to deploy / tear down / debug
```

## Quick start

1. Run `scripts/bootstrap-oidc.sh` **once**, manually, from a local `az
   cli` session (creates a federated credential for GitHub Actions — see
   the comments in the script for what and why).
2. In the repo settings (Settings → Secrets and variables → Actions) add
   three **variables** (not secrets — these aren't sensitive):
   `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
3. Run the **Deploy infrastructure** workflow (Actions → Deploy
   infrastructure → Run workflow).
4. Once the VM is no longer needed: run the **Teardown infrastructure**
   workflow.
5. Once the strategy from the other chat is ready: run the **Deploy
   strategy code** workflow.

Full details for each step, including exact `az cli` commands for manual
verification: `docs/RUNBOOK.md`.
