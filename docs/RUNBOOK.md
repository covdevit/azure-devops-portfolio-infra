# Runbook

## 0. One-time setup (do this once, at the very start)

1. Create an Azure account (if you don't have one) — 30 days / $200 in
   credit, then 12 months of Always Free on selected resources (see
   `README.md`).
2. Install `az cli` locally and log in: `az login`.
3. Generate an SSH key pair if you don't already have one: `ssh-keygen -t
   ed25519 -C "azure-trading-vm"`.
4. Create two repos on GitHub: public `azure-devops-portfolio-infra`
   (contents of this directory) and private `trading-strategy-azure`
   (empty stub for now — see `strategy-private-stub/` in the delivered
   package).
5. Run `scripts/bootstrap-oidc.sh` (first edit the `GITHUB_ORG`/
   `GITHUB_REPO` variables at the top of the file).
6. In the public repo's settings (Settings → Secrets and variables →
   Actions):
   - **Variables**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
     `AZURE_SUBSCRIPTION_ID` (from the bootstrap script), `ADMIN_SOURCE_IP`
     (your public IP in `x.x.x.x/32` format — check with e.g. `curl
     ifconfig.me`), `ADMIN_SSH_PUBLIC_KEY` (contents of
     `~/.ssh/id_ed25519.pub`), `STRATEGY_REPO` (e.g.
     `your-user/trading-strategy-azure`).
   - **Secrets**: `STRATEGY_REPO_PAT` (fine-grained PAT with "Contents:
     Read" on the strategy repo ONLY), `VM_SSH_PRIVATE_KEY` (contents of
     `~/.ssh/id_ed25519`, the **private** key).

## 1. Deploy the infrastructure

GitHub UI: **Actions → Deploy infrastructure → Run workflow**.

Manually (locally, for debugging):

```bash
az deployment sub create \
  --location polandcentral \
  --template-file bicep/main.bicep \
  --parameters bicep/parameters/main.parameters.json \
  --parameters adminSourceIp="$(curl -s ifconfig.me)/32" \
  --parameters adminSshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

Once it's done, note the IP address from the output (`vmPublicIp`) — you
need it for step 3 and for SSH.

```bash
az deployment sub show --name <deploymentName> --query properties.outputs
```

## 2. Verify after deployment

```bash
# SSH into the VM (wait ~1-2 minutes after deployment for cloud-init)
ssh azadmin@<vmPublicIp>

# On the VM: check that cloud-init finished and the venv exists
cloud-init status --wait
ls -la /opt/trading-strategy
```

## 3. Deploy the strategy code

Requires the code to already be ready in the private repo
`trading-strategy-azure` (a `strategy.py` file + `requirements.txt`, see
the contract in `strategy-private-stub/README.md`).

GitHub UI: **Actions → Deploy strategy code → Run workflow**, supplying
`vmIp` (from step 1).

Once it finishes:

```bash
ssh azadmin@<vmPublicIp> "systemctl status trading-strategy.service --no-pager"
```

## 4. Viewing logs in Log Analytics (instead of tail -f)

Azure portal → Log Analytics workspace (`tradingvm-dev-law`) → Logs.
Example KQL queries:

```kusto
// Recent service logs (from syslog, facility=daemon/user)
Syslog
| where SyslogMessage contains "trading-strategy"
| order by TimeGenerated desc
| take 100
```

```kusto
// Detecting service restarts (systemd logs start/stop events)
Syslog
| where ProcessName == "systemd" and SyslogMessage contains "trading-strategy"
| order by TimeGenerated desc
```

```kusto
// CPU/RAM usage over time (to correlate with any issues)
Perf
| where ObjectName == "Processor" or ObjectName == "Memory"
| order by TimeGenerated desc
| take 200
```

The `tradingvm-dev-low-cpu-alert` alert (defined in `monitor.bicep`) fires
if CPU drops below 1% for 30 minutes — a signal that the process has died
and isn't coming back up despite `Restart=always`. Set up an action group
(portal → alert → Add action group) to get an email notification — this is
deliberately left out of Bicep, since it requires your email address
(personal data we don't want sitting in a public repo).

## 5. Backing up the SQLite state

To be configured once the actual strategy is connected (once the real
file size/change frequency is known). Skeleton (a systemd timer, e.g.
hourly), to be added on the VM manually or via an extension to
`deploy-app.yml`:

```bash
az storage blob upload \
  --account-name <storageAccountName> \
  --container-name strategy-state-backups \
  --name "state-$(date +%Y%m%d-%H%M%S).db" \
  --file /opt/trading-strategy/data/state.db \
  --auth-mode login   # uses the VM's Managed Identity, no access key needed
```

## 6. Teardown

GitHub UI: **Actions → Teardown infrastructure → Run workflow**, and type
exactly `TEARDOWN` in the `confirm` field.

Manually:

```bash
az group delete --name tradingvm-dev-rg --yes --no-wait
```

## 7. Connecting the two repos (public infra + private strategy)

End-to-end flow once the strategy code is ready in the other chat:

1. `Deploy infrastructure` → note the `vmPublicIp` from the output.
2. Push/update the code in the private repo `trading-strategy-azure`
   (`strategy.py`, `requirements.txt`).
3. `Deploy strategy code`, supplying the `vmIp` from step 1 and
   (optionally) the branch/tag of the strategy to deploy.
4. Step 4 (Log Analytics) to confirm the process actually started and is
   logging.

Subsequent updates to just the strategy (no infrastructure changes) are
simply a repeat of step 3 — no need to redeploy Bicep.

## 8. Costs — what to watch out for

- B1S VM: free for 12 months from account creation, then roughly
  $7-8/month running 24/7 — hence the deploy-on-demand model.
- Public IP (Basic, Static): covered by Always Free for a single address.
- Log Analytics: first 5 GB/month free in most regions, then billed per
  GB — with a single small VM you're unlikely to get close to the limit,
  but keep an eye on `retentionInDays` (set to 30, a reasonable minimum for
  a portfolio project).
- Storage Account (Cool tier, LRS): pennies for small backup files.
- Key Vault: standard tier, billed per operation (pennies for occasional use).

After each teardown, check **Cost Management** in the portal to confirm
the resource group has actually disappeared (`--no-wait` deletes in the
background, which can take a few minutes).
