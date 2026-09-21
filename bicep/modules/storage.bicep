// storage.bicep
// Storage Account for SQLite backups (strategy state) and log archiving —
// AZ-104 domain: Implement and manage storage. Not on the application's
// hot path (the process writes locally to SQLite on the VM disk), only a
// target for periodic backups (cron/systemd timer on the VM side, see
// RUNBOOK).

@description('Deployment region')
param location string

@description('Resource name prefix')
param namePrefix string

@description('Common tags')
param tags object

@description('Principal ID of the VM managed identity — gets permission to write backups')
param vmPrincipalId string

var uniqueSuffix = uniqueString(resourceGroup().id)
// Storage account name: lowercase letters and digits only, max 24 chars, globally unique
var storageAccountName = take(toLower('${replace(namePrefix, '-', '')}st${uniqueSuffix}'), 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS' // LRS is enough — this is a secondary backup, not the only copy of the data
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    accessTier: 'Cool' // backups are read rarely
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'strategy-state-backups'
  properties: {
    publicAccess: 'None'
  }
}

// "Storage Blob Data Contributor" role (built-in role ID constant across
// Azure: ba92f5b4-2d11-453d-a403-e96b0029c9fe) — lets the VM write/read
// backups without a storage account access key (no secret on disk at all).
resource blobContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, vmPrincipalId, 'StorageBlobDataContributor')
  scope: storageAccount
  properties: {
    principalId: vmPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
  }
}

output storageAccountName string = storageAccount.name
output backupContainerName string = backupContainer.name
