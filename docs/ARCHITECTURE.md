# Architektura

## Diagram (logiczny)

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
                         │  │   │   - SQLite (stan lokalny)       │ │  │
                         │  │   └──────┬───────────────┬──────────┘ │  │
                         │  │          │ syslog/perf   │ backup      │  │
                         │  │   ┌──────▼──────┐  ┌─────▼──────────┐ │  │
                         │  │   │ Log Analytics│  │ Storage Account│ │  │
                         │  │   │ + VM Insights│  │ (Cool, LRS)    │ │  │
                         │  │   │ + alert      │  └────────────────┘ │  │
                         │  │   └─────────────┘                      │  │
                         │  └───────────────────────────────────────┘  │
                         └─────────────────────────────────────────────┘

   Poza subskrypcją:  exchange (WebSocket, publiczne dane rynkowe) ◀── VM (outbound only)
```

## Decyzje i ich uzasadnienie

### Deploy-on-demand zamiast 24/7

Zdecydowano (patrz sekcja 3 konspektu wyjściowego) na model, w którym
infrastruktura jest stawiana i zdejmowana komendą, a nie stoi cały czas.
Powody:

- Azure daje VM B1S za darmo tylko przez 12 miesięcy od założenia konta —
  w przeciwieństwie do Oracle Always Free, które nie ma limitu czasowego.
  Trzymanie VM 24/7 przez cały rok zużywa ten limit bezpowrotnie; deploy-on-
  demand pozwala rozciągnąć darmowy okres na dłużej realnego użytkowania.
- Odtwarzalna infrastruktura sterowana z kodu jest właśnie tym, co ma
  wartość w portfolio DevOps — VM postawiona ręcznie i zostawiona na stałe
  tego nie pokazuje.
- Koszt uboczny: trzeba pamiętać o teardown i re-deployu, adres IP VM
  zmienia się przy każdym cyklu (public IP jest tworzony na nowo). To
  świadomy kompromis — `deploy-app.yml` przyjmuje adres IP jako input, a nie
  odczytuje go automatycznie.

### Bicep zamiast Terraform/ARM JSON

Bicep jest natywny dla Azure i bezpośrednio pokrywa się z materiałem AZ-104
(egzamin zakłada znajomość ARM templates/Bicep, nie Terraformu). Subscription-
scope (`targetScope = 'subscription'`) w `main.bicep` pozwala jednej komendzie
stworzyć samą resource group i wszystko w środku — bez wcześniejszego
ręcznego kroku "najpierw stwórz RG w portalu".

### Key Vault + Managed Identity zamiast .env

Obecna strategia w Oracle nie używa żadnych kluczy API (tylko publiczne dane
rynkowe przez WebSocket), więc VM na Azure też może startować bez żadnych
sekretów. Mimo to Key Vault jest częścią infrastruktury od początku, bo:

1. AZ-104 wprost testuje Key Vault + Managed Identity + RBAC.
2. Jeśli DRUGA strategia (projektowana równolegle) będzie jednak potrzebować
   kluczy do innego dostawcy danych, infrastruktura jest już gotowa — dodanie
   sekretu to `az keyvault secret set`, zero zmian w Bicep.
3. RBAC (`enableRbacAuthorization: true`), nie legacy access policies — to
   aktualna rekomendowana praktyka i to, co powinno się umieć na egzaminie.

Sekrety **nie** są tworzone przez Bicep — deployment nie zna żadnych
wartości sekretnych, więc nic wrażliwego nie trafia do stanu deploymentu ani
historii repo (nawet gdyby repo było prywatne).

### NSG: brak inbound poza SSH z jednego IP

Proces strategii nie nasłuchuje niczego — łączy się tylko wychodząco. Jedyny
potrzebny ruch przychodzący to SSH administratora, zawężony do jednego
adresu IP (parametr `adminSourceIp`). Jawna reguła `Deny-All-Inbound-Internet`
o niskim priorytecie dokumentuje intencję, nawet jeśli domyślne reguły Azure
i tak by to zablokowały.

### Log Analytics + syslog zamiast tail -f

`journald` procesu (przez `StandardOutput=journal` w unit systemd) trafia do
syslog, który Azure Monitor Agent wysyła do Log Analytics przez Data
Collection Rule zdefiniowaną w `monitor.bicep`. Zapytania KQL zamiast SSH +
tail -f — przykłady w `RUNBOOK.md`.

### Storage Account jako backup, nie hot path

SQLite zostaje lokalnie na dysku VM (proces musi mieć do niego szybki,
lokalny dostęp — sieciowy system plików byłby niepotrzebnym ryzykiem
opóźnień/blokad). Storage Account służy wyłącznie do okresowego backupu
(cron/systemd timer po stronie VM — do skonfigurowania po podłączeniu
właściwej strategii, gdy znany będzie realny rozmiar/częstotliwość zmian
pliku stanu).

## Mapowanie na domeny egzaminu AZ-104

| Domena AZ-104 | Element w tym projekcie |
|---|---|
| Manage Azure identities and governance | System-Assigned Managed Identity VM; role assignments (RBAC) do Key Vault i Storage Account; tagi i nazewnictwo zasobów w `main.bicep`; OIDC federated credential zamiast client secret |
| Implement and manage storage | Storage Account (`storage.bicep`) z kontenerem blob do backupu stanu SQLite, `minimumTlsVersion`, brak publicznego dostępu |
| Deploy and manage compute resources | VM B1S (`vm.bicep`), cloud-init, Bicep jako IaC, deploy/teardown przez GitHub Actions |
| Configure and manage virtual networking | VNet + subnet + NSG (`network.bicep`), zasady inbound/outbound, Public IP |
| Monitor and back up Azure resources | Log Analytics Workspace, Azure Monitor Agent + VM Insights, Data Collection Rule, metric alert (`monitor.bicep`); Storage Account jako backup stanu |

## Możliwe rozszerzenia (świadomie odłożone)

- **Private Endpoint dla Key Vault** — obecnie `networkAcls.defaultAction:
  Allow` dla prostoty. Do rozważenia, gdy VM będzie faktycznie przechowywać
  sekrety produkcyjne.
- **Zawężenie outbound NSG do adresów IP giełdy** — odłożone, bo adresy IP
  exchange bywają niestabilne (CDN/load balancing); zawężenie groziłoby
  przerwami w działaniu strategii bez realnego zysku bezpieczeństwa (proces
  i tak nie ma nic wrażliwego do stracenia bez kluczy API).
- **Azure Backup dla VM** (formalna usługa backupu, nie tylko blob z SQLite)
  — pominięte, bo VM jest z założenia efemeryczna (deploy-on-demand); backup
  całej maszyny nie ma sensu, gdy maszyna i tak jest odtwarzana z Bicep.
