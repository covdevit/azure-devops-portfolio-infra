# Architecture

## Diagram (logical)
                     ┌─────────────────────────────────────────┐
                     │      Subscription (deploy-on-demand)     │
                     │                                           │
                     │  ┌─────────────────────────────────────┐  │
                     │  │  Resource Group: tradingvm-dev-rg    │  │
                     │  │                                       │  │
                     │  │   ┌───────────┐      ┌─────────────┐ │  │

GitHub Actions ───────┼──┼──▶│ VNet │ │ Key Vault │ │ │
(OIDC login, │ │ │ + Subnet │ │ (RBAC) │ │ │
az deployment) │ │ │ + NSG │ └──────▲──────┘ │ │
│ │ └─────┬─────┘ │ │ │
│ │ │ │ read secrets
│ │ ┌─────▼─────────────────────┴────┐ │ │
│ │ │ VM (B2s_v2, Ubuntu 22.04) │ │ │
│ │ │ - System-Assigned Managed │ │ │
│ │ │ Identity │ │ │
│ │ │ - systemd: trading-strategy │ │ │
│ │ │ (Restart=always) │ │ │
│ │ │ - SQLite (local state) │ │ │
│ │ └──────┬───────────────┬──────────┘ │ │
│ │ │ syslog/perf │ backup │ │
│ │ ┌──────▼──────┐ ┌─────▼──────────┐ │ │
│ │ │ Log Analytics│ │ Storage Account│ │ │
│ │ │ + VM Insights│ │ (Cool, LRS) │ │ │
│ │ │ + alert │ └────────────────┘ │ │
│ │ └─────────────┘ │ │
│ └───────────────────────────────────────┘ │
└─────────────────────────────────────────────┘

Outside the subscription: exchange (WebSocket, public market data) ◀── VM (outbound only)


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

### Poland Central + Standard_B2s_v2 (two rounds of real-world troubleshooting)

The first deploy attempt used `polandcentral` (geographically the obvious
choice) with `Standard_B1s` (the Always Free size). It failed at the VM
module with a preflight validation error:

SkuNotAvailable: The requested VM size for resource 'Following SKUs have
failed for Capacity Restrictions: Standard_B1s' is currently not available
in location 'PolandCentral'.


The first hypothesis was a Poland-Central-specific capacity problem, so the
region was switched to `westeurope`. That failed differently, and more
fundamentally:

RequestDisallowedByAzure: Resource 'tradingvm-dev-vnet' was disallowed by
Azure: The selected region is currently not accepting new customers:
https://aka.ms/locationineligible.


This is an account-level restriction common on new/free Azure
subscriptions: Microsoft limits which regions a given subscription may
deploy into at all, independent of any specific resource's capacity. Poland
Central passed this check (the VNet/NSG deployed there without issue); West
Europe did not. So the account is tied to Poland Central (or a similarly
narrow set of regions) — moving to a different region was not the right
fix.

Went back to `polandcentral` and instead queried exactly which VM sizes
that subscription can actually use there:

az vm list-skus --location polandcentral --size Standard_B --all --output table


The result showed a clean split: every size in the legacy "B-series"
family (`B1s`, `B1ms`, `B2s`, `B2ms`, `B4ms`, `B8ms`, ...) is
`NotAvailableForSubscription` in Poland Central for this account, while the
entire newer `_v2` burstable family (`B2s_v2`, `B4s_v2`, `B8s_v2`, ...) is
unrestricted. Switched the VM size to `Standard_B2s_v2` — the closest
modern equivalent to B2s (2 vCPU / 4 GiB RAM).

Trade-off worth being explicit about: `B2s_v2` is **not** part of the
Always Free 12-month grant (only classic `B1s` was), so this now incurs a
small real cost per hour the VM is running. Given the deploy-on-demand
model, actual spend stays minimal — you're billed only while the VM exists,
not for a full month regardless of use. See `docs/RUNBOOK.md` for cost
notes.

Lesson for anyone hitting a similar wall: `SkuNotAvailable` (a
capacity/region problem, worth trying elsewhere) and
`RequestDisallowedByAzure: ... not accepting new customers` (an
account-level region restriction, changing region is the wrong move — you
need to work within the allowed region and find a SKU that isn't
restricted there) look superficially similar but call for opposite fixes.
`az vm list-skus --location <region> --all` is the fast way to tell which
one you're dealing with.

### RBAC delegation vs. ABAC guardrails (granting the pipeline permission to create role assignments)

`keyvault.bicep` and `storage.bicep` each create a scoped RBAC role
assignment (Key Vault Secrets User, Storage Blob Data Contributor) for the
VM's managed identity. The GitHub Actions deployment identity only had
`Contributor` (from `bootstrap-oidc.sh`), and Contributor deliberately does
**not** include `Microsoft.Authorization/roleAssignments/write` — so both of
those role-assignment resources failed with `AuthorizationFailed`.

The obvious fix — grant the deployment identity `User Access Administrator`
at the subscription scope — itself failed, with a different, more
interesting error:

AuthorizationFailed: The client '<my-account>' ... has an authorization with
ABAC condition that is not fulfilled to perform action
'Microsoft.Authorization/roleAssignments/write' ...


This is an Azure ABAC (Attribute-Based Access Control) condition attached to
the account's own Owner role assignment — a guardrail (common on new/free
subscriptions) that blocks an Owner from *delegating* the most privileged
built-in roles (Owner, User Access Administrator, Role Based Access Control
Administrator) to another principal, to prevent privilege-escalation abuse.
Proof this is specifically about those three roles and not a blanket
restriction: the same account had no problem granting plain `Contributor`
to the same service principal earlier, during bootstrap.

Fix: instead of granting the built-in `User Access Administrator` role,
create a narrow **custom role** with only
`Microsoft.Authorization/roleAssignments/{read,write,delete}` and grant
*that* to the deployment identity:

```bash
az role definition create --role-definition '{
  "Name": "Portfolio Constrained Role Assignment Writer",
  "IsCustom": true,
  "Actions": [
    "Microsoft.Authorization/roleAssignments/write",
    "Microsoft.Authorization/roleAssignments/read",
    "Microsoft.Authorization/roleAssignments/delete"
  ],
  "NotActions": [],
  "AssignableScopes": ["/subscriptions/<subscription-id>"]
}'

az role assignment create \
  --assignee <deployment-identity-object-id> \
  --role "Portfolio Constrained Role Assignment Writer" \
  --scope "/subscriptions/<subscription-id>"
```

Because the ABAC condition checks the specific role *definition ID* being
granted against a fixed list of built-in privileged roles, granting a
custom role (a different, non-listed definition ID) that happens to include
the same underlying permission is not blocked — even though functionally it
grants the same capability. This is a real, useful distinction for AZ-104:
principle of least privilege in practice beats reaching for the nearest
built-in "big" role, and it's also just... how the guardrail happens to be
implemented (it checks role *identity*, not the *permissions* a role
grants).

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

One more real-world wrinkle: the first deploy attempt after fixing the RBAC
issue above failed again, this time with:

BadRequest: The property "enablePurgeProtection" cannot be set to false.
Enabling the purge protection for a vault is an irreversible action.


Azure no longer accepts an explicit `enablePurgeProtection: false` in the
template at all (since purge protection is a one-way switch, Azure treats
even *stating* "false" as suspicious/disallowed, not just "true→false").
Since disabled is already the default when the property is left out, and
disabled is what this deploy-on-demand project needs (so `az keyvault
purge` works during fast teardown/redeploy cycles instead of leaving
soft-deleted vaults blocking the name for 90 days), the fix is simply to
omit the property entirely rather than set it to any explicit value.

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

### Bicep gotcha: triple-quoted strings don't interpolate

The cloud-init script in `vm.bicep` originally referenced the admin username
inside a triple-quoted (multi-line) string using `${adminUsername}`, which
looks exactly like normal Bicep string interpolation but silently isn't:
Bicep's multi-line strings are raw/verbatim text, so the literal text
`${adminUsername}` (not the actual value `azadmin`) ended up in the
generated cloud-init `runcmd` script. The `chown` step then tried to `chown`
to a literal, nonexistent user, which cloud-init logged as a successful
step (exit code 0) despite not doing what was intended — so `/opt/
trading-strategy` was left owned by `root:root` instead of `azadmin:azadmin`,
found only by actually SSHing into a freshly deployed VM and checking.

Fixed by keeping the multi-line block as a literal template with an
explicit placeholder token, then substituting it with the `replace()`
function *after* the multi-line string, since at that point it's just an
ordinary Bicep string value:

```bicep
var cloudInitTemplate = '''#cloud-config
...
runcmd:
  - chown -R __ADMIN_USERNAME__:__ADMIN_USERNAME__ /opt/trading-strategy
'''
var cloudInit = base64(replace(cloudInitTemplate, '__ADMIN_USERNAME__', adminUsername))
```

Lesson: never assume `${...}` works the same way inside a Bicep multi-line
string as it does in a normal one — and always verify cloud-init side
effects by actually SSHing in, not just by checking that `cloud-init status`
reports `done` (a step can "succeed" and still not do what you meant).

## Mapping to AZ-104 exam domains

| AZ-104 domain | Element in this project |
|---|---|
| Manage Azure identities and governance | VM System-Assigned Managed Identity; RBAC role assignments to Key Vault and Storage Account; resource naming/tagging in `main.bicep`; OIDC federated credential instead of a client secret |
| Implement and manage storage | Storage Account (`storage.bicep`) with a blob container for SQLite state backups, `minimumTlsVersion`, no public access |
| Deploy and manage compute resources | Burstable B2s_v2 VM (`vm.bicep`), cloud-init, Bicep as IaC, deploy/teardown via GitHub Actions |
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
