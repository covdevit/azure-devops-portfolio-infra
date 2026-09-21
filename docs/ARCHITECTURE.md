# Architecture

## Diagram (logical)

```
                         ┌─────────────────────────────────────────┐
                         │      Subscription (deploy-on-demand)     │
                         │                                           │
                         │  ┌─────────────────────────────────────┐  │
                         │  │  Resource Group: tradingvm-dev-rg    │  │
                         │  │                                       │  │
                         │  │   ┌───────────┐      ┌─────────────┐ │  │
   GitHub Actions ───────┼──┼──▶│    VNet   │      │  Key Vault  │ │  │
   (OIDC login,          │  │   │  + Subnet │      │  (RBAC)     │ │  │
    az deployment)       │  │   │  + NSG    │      └──────▲──────┘ │  │
                         │  │   └─────┬─────┘             │        │  │
                         │  │         │                    │ read secrets
                         │  │   ┌─────▼─────────────────────┴────┐ │  │
                         │  │   │   VM (B1S, Ubuntu 22.04)        │ │  │
                         │  │   │   - System-Assigned Managed     │ │  │
                         │  │   │     Identity                    │ │  │
                         │  │   │   - systemd: trading-strategy   │ │  │
                         │  │   │     (Restart=always)            │ │  │
                         │  │   │   - SQLite (local state)        │ │  │
                         │  │   └──────┬───────────────┬──────────┘ │  │
                         │  │          │ syslog/perf   │ backup      │  │
                         │  │   ┌──────▼──────┐  ┌─────▼──────────┐ │  │
                         │  │   │ Log Analytics│  │ Storage Account│ │  │
                         │  │   │ + VM Insights│  │ (Cool, LRS)    │ │  │
                         │  │   │ + alert      │  └────────────────┘ │  │
                         │  │   └─────────────┘                      │  │
                         │  └───────────────────────────────────────┘  │
                         └─────────────────────────────────────────────┘

   Outside the subscription:  exchange (WebSocket, public market data) ◀── VM (outbound only)
```

## Decisions and their reasoning

### Deploy-on-demand instead of 24/7

Chose (see section 3 of the original outline) a model where the
infrastructure is stood up and torn down by command, rather than running
continuously. Reasons:

- Azure only gives away a free B1S VM for 12 months from account creation
  — unlike Oracle Always Free, which has no time limit. Keeping a VM up
  24/7 for the whole year burns through that allowance for good;
  deploy-on-demand lets the free period stretch across more actual usage.
- Reproducible, code-driven infrastructure is exactly what has value in a
  DevOps portfolio — a VM that was clicked together by hand and left
  running forever doesn't demonstrate that.
- Side effect: you need to remember to tear down and redeploy, and the
  VM's IP address changes on every cycle (the public IP is recreated each
  time). This is a deliberate trade-off — `deploy-app.yml` takes the IP
  address as an input rather than reading it automatically.

### Bicep instead of Terraform/ARM JSON

Bicep is native to Azure and maps directly onto AZ-104 material (the exam
expects familiarity with ARM templates/Bicep, not Terraform).
Subscription-scope (`targetScope = 'subscription'`) in `main.bicep` lets a
single command create both the resource group and everything inside it —
no separate manual step to "create the RG in the portal first".

### Key Vault + Managed Identity instead of .env

The current strategy on Oracle uses no API keys at all (only public
market data over WebSocket), so the VM on Azure can also start with zero
secrets. Even so, Key Vault is part of the infrastructure from day one,
because:

1. AZ-104 directly tests Key Vault + Managed Identity + RBAC.
2. If the SECOND strategy (being designed in parallel) ends up needing
   keys for a different data provider, the infrastructure is already
   ready — adding a secret is just `az keyvault secret set`, zero Bicep
   changes.
3. RBAC (`enableRbacAuthorization: true`), not legacy access policies —
   that's the current recommended practice and what you should know for
   the exam.

Secrets are **not** created by Bicep — the deployment never sees any
sensitive values, so nothing sensitive ends up in deployment state or repo
history (even if the repo were private).

### NSG: no inbound except SSH from one IP

The strategy process doesn't listen on anything — it only makes outbound
connections. The only inbound traffic needed is admin SSH, restricted to a
single IP address (the `adminSourceIp` parameter). An explicit
`Deny-All-Inbound-Internet` rule at low priority documents the intent,
even though Azure's default rules would already block it.

### Log Analytics + syslog instead of tail -f

The process's `journald` output (via `StandardOutput=journal` in the
systemd unit) flows into syslog, which the Azure Monitor Agent forwards to
Log Analytics via a Data Collection Rule defined in `monitor.bicep`. KQL
queries instead of SSH + tail -f — examples in `RUNBOOK.md`.

### Storage Account as backup, not the hot path

SQLite stays local on the VM disk (the process needs fast, local access —
a networked filesystem would be an unnecessary source of latency/locking
risk). The Storage Account is used purely for periodic backups (a
cron/systemd timer on the VM side — to be configured once the actual
strategy is connected and its real state-file size/change-frequency is
known).

## Mapping to AZ-104 exam domains

| AZ-104 domain | Element in this project |
|---|---|
| Manage Azure identities and governance | VM System-Assigned Managed Identity; RBAC role assignments to Key Vault and Storage Account; resource naming/tagging in `main.bicep`; OIDC federated credential instead of a client secret |
| Implement and manage storage | Storage Account (`storage.bicep`) with a blob container for SQLite state backups, `minimumTlsVersion`, no public access |
| Deploy and manage compute resources | B1S VM (`vm.bicep`), cloud-init, Bicep as IaC, deploy/teardown via GitHub Actions |
| Configure and manage virtual networking | VNet + subnet + NSG (`network.bicep`), inbound/outbound rules, Public IP |
| Monitor and back up Azure resources | Log Analytics Workspace, Azure Monitor Agent + VM Insights, Data Collection Rule, metric alert (`monitor.bicep`); Storage Account as state backup |

## Possible extensions (deliberately deferred)

- **Private Endpoint for Key Vault** — currently `networkAcls.defaultAction:
  Allow` for simplicity. Worth revisiting once the VM actually stores
  production-grade secrets.
- **Restrict outbound NSG rules to the exchange's IP ranges** — deferred,
  because exchange IP addresses tend to be unstable (CDN/load balancing);
  tightening this would risk interrupting the strategy for no real
  security gain (the process has nothing sensitive to lose anyway without
  API keys).
- **Azure Backup for the VM** (the formal backup service, not just a SQLite
  blob) — skipped, because the VM is ephemeral by design (deploy-on-
  demand); backing up the whole machine doesn't make sense when the
  machine is reproduced from Bicep anyway.
