#!/usr/bin/env bash
# bootstrap-oidc.sh
#
# One-time setup: lets GitHub Actions log in to Azure via OIDC (OpenID
# Connect federated credential), WITHOUT storing a long-lived secret
# (client secret) in GitHub Secrets. This is Azure IAM best practice
# (AZ-104 domain: Manage Azure identities and governance) and is
# straightforwardly better than the classic
# `az ad sp create-for-rbac --sdk-auth` with a stored secret.
#
# Run MANUALLY, ONCE, from a local `az cli` session logged in as the
# subscription owner. This is not part of the automated deployment.
#
# Requires: az cli logged in (`az login`), Owner or
# User Access Administrator + Application Administrator rights on the subscription.

set -euo pipefail

# ---- fill these in before running ----
GITHUB_ORG="YOUR_GITHUB_USERNAME_OR_ORG"
GITHUB_REPO="azure-devops-portfolio-infra"
APP_NAME="gh-actions-${GITHUB_REPO}"
# ---------------------------------------

echo "==> Creating Azure AD App Registration + Service Principal: ${APP_NAME}"
APP_ID=$(az ad app create --display-name "${APP_NAME}" --query appId -o tsv)
az ad sp create --id "${APP_ID}" >/dev/null

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "==> Granting Contributor role at the subscription level"
# Note: Contributor on the whole subscription is broad. Acceptable
# simplification for a portfolio project (the subscription is dedicated to
# this project); in a corporate environment you'd scope this down to a
# specific resource group.
az role assignment create \
  --assignee "${APP_ID}" \
  --role "Contributor" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}"

echo "==> Registering federated credential for workflow_dispatch on the main branch"
az ad app federated-credential create \
  --id "${APP_ID}" \
  --parameters "{
    \"name\": \"gh-actions-main-branch\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

# Second federated credential: allows workflow_dispatch runs regardless of
# which branch triggers them (useful while iterating on a feature branch).
# Remove this if you want to hard-restrict to main only.
az ad app federated-credential create \
  --id "${APP_ID}" \
  --parameters "{
    \"name\": \"gh-actions-any-branch\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/*\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"

echo ""
echo "==> Done. Add these three VALUES (not secrets!) in GitHub:"
echo "    Settings -> Secrets and variables -> Actions -> Variables tab"
echo ""
echo "    AZURE_CLIENT_ID       = ${APP_ID}"
echo "    AZURE_TENANT_ID       = ${TENANT_ID}"
echo "    AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
echo ""
echo "    These are NOT secrets (the OIDC token is useless without the"
echo "    federated credential above, even if someone saw these values) —"
echo "    deliberately stored as repository variables, not encrypted"
echo "    secrets, so they stay visible in a public repo."
