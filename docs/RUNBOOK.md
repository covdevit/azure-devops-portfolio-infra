# Runbook

## 0. Jednorazowy setup (zrób raz, na samym początku)

1. Załóż konto Azure (jeśli jeszcze nie masz) — 30 dni / $200 kredytu, potem
   12 miesięcy Always Free na wybrane zasoby (patrz `README.md`).
2. Zainstaluj lokalnie `az cli` i zaloguj się: `az login`.
3. Wygeneruj parę kluczy SSH, jeśli nie masz: `ssh-keygen -t ed25519 -C
   "azure-trading-vm"`.
4. Utwórz dwa repozytoria na GitHub: publiczne `azure-devops-portfolio-infra`
   (zawartość tego katalogu) i prywatne `trading-strategy-azure` (na razie
   pusty stub — patrz `strategy-private-stub/` w dostarczonej paczce).
5. Uruchom `scripts/bootstrap-oidc.sh` (edytuj najpierw zmienne
   `GITHUB_ORG`/`GITHUB_REPO` na górze pliku).
6. W ustawieniach publicznego repo (Settings → Secrets and variables →
   Actions):
   - **Variables**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
     `AZURE_SUBSCRIPTION_ID` (ze skryptu bootstrap), `ADMIN_SOURCE_IP`
     (twój publiczny IP w formacie `x.x.x.x/32` — sprawdź np. `curl
     ifconfig.me`), `ADMIN_SSH_PUBLIC_KEY` (zawartość `~/.ssh/id_ed25519.pub`),
     `STRATEGY_REPO` (np. `twoj-user/trading-strategy-azure`).
   - **Secrets**: `STRATEGY_REPO_PAT` (fine-grained PAT z uprawnieniem
     "Contents: Read" TYLKO do repo strategii), `VM_SSH_PRIVATE_KEY`
     (zawartość `~/.ssh/id_ed25519`, **prywatny** klucz).

## 1. Deploy infrastruktury

GitHub UI: **Actions → Deploy infrastructure → Run workflow**.

Ręcznie (lokalnie, do debugowania):

```bash
az deployment sub create \
  --location polandcentral \
  --template-file bicep/main.bicep \
  --parameters bicep/parameters/main.parameters.json \
  --parameters adminSourceIp="$(curl -s ifconfig.me)/32" \
  --parameters adminSshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

Po zakończeniu zapisz adres IP z outputu (`vmPublicIp`) — potrzebny do
kroku 3 i do SSH.

```bash
az deployment sub show --name <deploymentName> --query properties.outputs
```

## 2. Weryfikacja po deployu

```bash
# SSH do VM (poczekaj ~1-2 min po deployu na cloud-init)
ssh azadmin@<vmPublicIp>

# Na VM: sprawdź czy cloud-init się zakończył i czy venv istnieje
cloud-init status --wait
ls -la /opt/trading-strategy
```

## 3. Wdrożenie kodu strategii

Wymaga gotowego kodu w prywatnym repo `trading-strategy-azure` (plik
`strategy.py` + `requirements.txt`, patrz kontrakt w
`strategy-private-stub/README.md`).

GitHub UI: **Actions → Deploy strategy code → Run workflow**, podaj
`vmIp` (z kroku 1).

Po zakończeniu:

```bash
ssh azadmin@<vmPublicIp> "systemctl status trading-strategy.service --no-pager"
```

## 4. Podgląd logów w Log Analytics (zamiast tail -f)

Portal Azure → Log Analytics workspace (`tradingvm-dev-law`) → Logs.
Przykładowe zapytania KQL:

```kusto
// Ostatnie logi usługi (z syslog, facility=daemon/user)
Syslog
| where SyslogMessage contains "trading-strategy"
| order by TimeGenerated desc
| take 100
```

```kusto
// Wykrycie restartów usługi (systemd loguje start/stop)
Syslog
| where ProcessName == "systemd" and SyslogMessage contains "trading-strategy"
| order by TimeGenerated desc
```

```kusto
// Wykorzystanie CPU/RAM w czasie (do korelacji z ewentualnymi problemami)
Perf
| where ObjectName == "Processor" or ObjectName == "Memory"
| order by TimeGenerated desc
| take 200
```

Alert `tradingvm-dev-low-cpu-alert` (zdefiniowany w `monitor.bicep`) odpali
się, jeśli CPU spadnie poniżej 1% przez 30 minut — sygnał, że proces padł i
nie wstaje mimo `Restart=always`. Skonfiguruj action group (portal → alert
→ Add action group) żeby dostawać powiadomienie e-mail — to celowo zostawione
poza Bicep, bo wymaga podania Twojego adresu e-mail (dane osobowe, nie
trzymamy w publicznym repo).

## 5. Backup stanu SQLite

Do skonfigurowania po podłączeniu właściwej strategii (gdy znany będzie
rozmiar/częstotliwość zmian pliku). Szkielet (systemd timer, uruchamiany np.
co godzinę), do dodania na VM ręcznie lub przez rozszerzenie
`deploy-app.yml`:

```bash
az storage blob upload \
  --account-name <storageAccountName> \
  --container-name strategy-state-backups \
  --name "state-$(date +%Y%m%d-%H%M%S).db" \
  --file /opt/trading-strategy/data/state.db \
  --auth-mode login   # korzysta z Managed Identity VM, bez klucza dostępu
```

## 6. Teardown

GitHub UI: **Actions → Teardown infrastructure → Run workflow**, w polu
`confirm` wpisz dokładnie `TEARDOWN`.

Ręcznie:

```bash
az group delete --name tradingvm-dev-rg --yes --no-wait
```

## 7. Łączenie repo (infra publiczne + strategia prywatna)

Przepływ end-to-end po tym, jak kod strategii będzie gotowy w drugim
czacie:

1. `Deploy infrastructure` → zapisz `vmPublicIp` z outputu.
2. Wrzuć/zaktualizuj kod w prywatnym repo `trading-strategy-azure`
   (`strategy.py`, `requirements.txt`).
3. `Deploy strategy code`, podając `vmIp` z kroku 1 i (opcjonalnie) branch/
   tag strategii do wdrożenia.
4. Krok 4 (Log Analytics) do weryfikacji, że proces faktycznie wstał i
   loguje.

Kolejne aktualizacje samej strategii (bez zmiany infrastruktury) to tylko
powtórzenie kroku 3 — nie trzeba re-deployować Bicep.

## 8. Koszty — na co uważać

- VM B1S: darmowa przez 12 mies. od założenia konta, potem ok. $7-8/mies.
  przy pracy 24/7 — stąd model deploy-on-demand.
- Public IP (Basic, Static): w ramach Always Free przy jednym adresie.
- Log Analytics: pierwsze 5 GB/miesiąc darmowe w większości regionów,
  potem płatne per GB — przy jednej małej VM raczej się nie zbliżysz do
  limitu, ale warto pilnować `retentionInDays` (ustawione na 30, minimum
  rozsądne dla portfolio).
- Storage Account (Cool tier, LRS): grosze przy małych plikach backupu.
- Key Vault: standard tier, opłata per operację (grosze przy sporadycznym
  użyciu).

Po każdym teardown sprawdź w portalu **Cost Management** czy resource group
faktycznie zniknęła (usunięcie `--no-wait` działa w tle, może potrwać kilka
minut).
