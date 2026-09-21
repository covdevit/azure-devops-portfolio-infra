# azure-devops-portfolio-infra

Odtwarzalna infrastruktura Azure (Bicep + GitHub Actions) pod trading-bota
działającego jako proces I/O-bound (WebSocket + zapis stanu) na jednej małej VM.

Projekt zbudowany jako portfolio DevOps + przygotowanie do certyfikatu
**AZ-104 (Azure Administrator Associate)**. Zobacz `docs/ARCHITECTURE.md`
dla mapowania na domeny egzaminu i uzasadnienia decyzji projektowych.

## Model działania: deploy na żądanie (ephemeral infra)

W przeciwieństwie do wzorca "VM działa 24/7" (jak w oryginalnym projekcie na
Oracle Cloud), ta infrastruktura jest **zaprojektowana do stawiania i
zdejmowania na żądanie**:

- `deploy.yml` — stawia całą infrastrukturę jedną komendą (`az deployment sub
  create`), bez ręcznego klikania w portalu.
- `teardown.yml` — usuwa resource group (a więc wszystko w środku) jedną
  komendą, gdy VM nie jest aktualnie potrzebna.

To świadomy wybór z dwóch powodów:

1. **Koszt** — Azure daje VM B1S za darmo tylko przez 12 miesięcy od
   założenia konta (nie bezterminowo jak Oracle Always Free). Zdejmowanie
   infrastruktury, gdy nieużywana, oszczędza darmowy limit i unika kosztów po
   jego wyczerpaniu.
2. **Portfolio** — odtwarzalna infrastruktura sterowana z kodu ("cattle, not
   pets") jest dokładnie tym, co pokazuje realną wartość DevOps na rozmowie
   kwalifikacyjnej, w przeciwieństwie do maszyny postawionej ręcznie i
   zostawionej na zawsze.

## Dwa repozytoria — dlaczego

| Repo | Widoczność | Zawartość |
|---|---|---|
| **`azure-devops-portfolio-infra`** (to repo) | **Publiczne** | Bicep, GitHub Actions, dokumentacja architektury, systemd unit template. Zero sekretów, zero logiki tradingowej. |
| **`trading-strategy-azure`** (osobne repo) | **Prywatne** | Właściwy kod strategii (logika wejść/wyjść, scoring). Projektowany równolegle w innym czacie. |

Powód rozdziału: kod infrastruktury *jest* tym, co chcesz pokazać
pracodawcy — może być publiczny bez ryzyka. Kod strategii ma wartość tylko
jeśli jest unikalny, więc zostaje prywatny, dokładnie jak strategia działająca
już na Oracle.

Połączenie następuje w workflow `deploy-app.yml` (patrz `.github/workflows/`):
publiczne repo definiuje *gdzie* i *jak* wdrożyć (infrastruktura, docelowa
ścieżka, definicja usługi systemd), a prywatne repo dostarcza *co* wdrożyć
(sam plik `strategy.py`). Zobacz `docs/RUNBOOK.md` sekcja "Łączenie repo".

## Struktura repo

```
infra-public/
├── bicep/
│   ├── main.bicep              # subscription-scope, orkiestruje wszystkie moduły
│   ├── modules/
│   │   ├── network.bicep       # VNet, subnet, NSG
│   │   ├── vm.bicep            # VM B1S + Managed Identity + NIC
│   │   ├── keyvault.bicep      # Key Vault + RBAC dla Managed Identity
│   │   └── monitor.bicep       # Log Analytics + VM Insights + alert
│   └── parameters/
│       └── main.parameters.json
├── .github/workflows/
│   ├── deploy.yml               # workflow_dispatch: staw infrastrukturę
│   ├── teardown.yml             # workflow_dispatch: zdejmij infrastrukturę
│   └── deploy-app.yml           # wdrożenie kodu strategii na istniejącą VM
├── scripts/
│   └── bootstrap-oidc.sh        # jednorazowy setup OIDC (bez sekretów w GH)
├── systemd/
│   └── trading-strategy.service # wzorzec z Oracle, przeniesiony na Azure
└── docs/
    ├── ARCHITECTURE.md          # mapowanie na domeny AZ-104
    └── RUNBOOK.md               # jak wdrażać / zdejmować / debugować
```

## Szybki start

1. Uruchom `scripts/bootstrap-oidc.sh` **raz**, ręcznie, z lokalnego `az cli`
   (tworzy federated credential dla GitHub Actions — patrz komentarze w
   skrypcie co i dlaczego).
2. Dodaj w ustawieniach repo (Settings → Secrets and variables → Actions)
   trzy **variables** (nie secrets — to nie są sekrety): `AZURE_CLIENT_ID`,
   `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
3. Uruchom workflow **Deploy infrastructure** (Actions → Deploy infrastructure
   → Run workflow).
4. Gdy VM już nie jest potrzebna: workflow **Teardown infrastructure**.
5. Gdy strategia z drugiego czatu będzie gotowa: workflow **Deploy strategy
   code**.

Szczegóły każdego kroku, w tym dokładne komendy `az cli` do ręcznej
weryfikacji: `docs/RUNBOOK.md`.
