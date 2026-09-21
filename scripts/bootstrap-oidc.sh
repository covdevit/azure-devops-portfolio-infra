#!/usr/bin/env bash
# bootstrap-oidc.sh
#
# Jednorazowy setup: pozwala GitHub Actions logować się do Azure przez OIDC
# (OpenID Connect federated credential), BEZ przechowywania długożyjącego
# sekretu (client secret) w GitHub Secrets. To najlepsza praktyka Azure IAM
# (AZ-104 domena: Manage Azure identities and governance) i jest wprost
# lepsza niż klasyczny `az ad sp create-for-rbac --sdk-auth` ze
# zdeponowanym sekretem.
#
# Uruchom RĘCZNIE, RAZ, z lokalnego `az cli` zalogowanego jako właściciel
# subskrypcji. Nie jest to część automatycznego deploymentu.
#
# Wymaga: az cli zalogowane (`az login`), uprawnienia Owner albo
# User Access Administrator + Application Administrator na subskrypcji.

set -euo pipefail

# ---- do wypełnienia przed uruchomieniem ----
GITHUB_ORG="TWOJ_GITHUB_USERNAME_LUB_ORG"
GITHUB_REPO="azure-devops-portfolio-infra"
APP_NAME="gh-actions-${GITHUB_REPO}"
# ---------------------------------------------

echo "==> Tworzę Azure AD App Registration + Service Principal: ${APP_NAME}"
APP_ID=$(az ad app create --display-name "${APP_NAME}" --query appId -o tsv)
az ad sp create --id "${APP_ID}" >/dev/null

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "==> Nadaję rolę Contributor na poziomie subskrypcji"
# Uwaga: Contributor na całej subskrypcji jest szerokie. Dla portfolio to
# akceptowalne uproszczenie (subskrypcja jest dedykowana temu projektowi);
# w środowisku firmowym zawężyłbyś scope do konkretnej resource group.
az role assignment create \
  --assignee "${APP_ID}" \
  --role "Contributor" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}"

echo "==> Rejestruję federated credential dla workflow_dispatch na branchu main"
az ad app federated-credential create \
  --id "${APP_ID}" \
  --parameters "{
    \"name\": \"gh-actions-main-branch\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

# Drugi federated credential: dopuszcza uruchamianie workflow_dispatch
# niezależnie od tego, z jakiego brancha (przydatne przy iteracji na branchu
# feature). Usuń, jeśli chcesz twardo ograniczyć do main.
az ad app federated-credential create \
  --id "${APP_ID}" \
  --parameters "{
    \"name\": \"gh-actions-any-branch\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/*\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

echo ""
echo "==> Gotowe. Dodaj te trzy WARTOŚCI (nie sekrety!) w GitHub:"
echo "    Settings -> Secrets and variables -> Actions -> Variables tab"
echo ""
echo "    AZURE_CLIENT_ID       = ${APP_ID}"
echo "    AZURE_TENANT_ID       = ${TENANT_ID}"
echo "    AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo ""
echo "    To NIE są sekrety (bez nich token OIDC i tak nic nie zdziała bez"
echo "    federated credential powyżej) — świadomie jako repository"
echo "    variables, nie encrypted secrets, żeby były widoczne w publicznym repo."
