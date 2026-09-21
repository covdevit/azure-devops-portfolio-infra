// keyvault.bicep
// Key Vault accessible exclusively via RBAC (not legacy access policies) —
// matching current Azure best practice and what's tested on AZ-104
// (domain: Manage Azure identities and governance).
//
// Secrets are NOT created here in Bicep (we don't want API keys sitting in
// deployment state or Git history). If the strategy ends up needing keys,
// they're added manually (`az keyvault secret set`) AFTER deployment, once,
// from the administrator's local machine — see docs/RUNBOOK.md.

@description('Deployment region')
param location string

@description('Resource name prefix')
param namePrefix string

@description('Principal ID of the VM managed identity that gets read access to secrets')
param vmPrincipalId string

@description('Common tags')
param tags object

// Key Vault names must be globally unique across Azure — we append a
// unique suffix derived from the resource group ID, so that repeated
// deploys (deploy → teardown → deploy) don't collide with a name "reserved"
// by a deleted vault (Key Vault soft-deletes by default for 90 days).
var uniqueSuffix = uniqueString(resourceGroup().id)
var keyVaultName = take('${namePrefix}-kv-${uniqueSuffix}', 24)

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7 // minimum allowed — this is deploy-on-demand infra, not production
    enablePurgeProtection: false // deliberately false: we need to be able to `az keyvault purge` during fast teardown/deploy cycles
    networkAcls: {
      defaultAction: 'Allow' // simplification for now; see docs/ARCHITECTURE.md "possible extensions" for a private endpoint
      bypass: 'AzureServices'
    }
  }
}

// "Key Vault Secrets User" role (read secrets) for the VM's managed
// identity. Built-in role ID is constant across all of Azure:
// 4633458b-17de-408a-b874-0445c86b69e6
resource secretsUserRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, vmPrincipalId, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    principalId: vmPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
  }
}

output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
