// storage.bicep
// Storage Account do backupu pliku SQLite (stan strategii) i archiwum
// logów — AZ-104 domena: Implement and manage storage. Nie jest to hot path
// aplikacji (proces pisze lokalnie do SQLite na dysku VM), tylko cel
// okresowego backupu (cron/systemd timer po stronie VM, patrz RUNBOOK).

@description('Region wdrożenia')
param location string

@description('Prefiks nazw zasobów')
param namePrefix string

@description('Tagi wspólne')
param tags object

@description('Principal ID tożsamości zarządzanej VM — dostaje uprawnienia do zapisu backupów')
param vmPrincipalId string

var uniqueSuffix = uniqueString(resourceGroup().id)
// Nazwa Storage Account: tylko małe litery i cyfry, max 24 znaki, globalnie unikalna
var storageAccountName = take(toLower('${replace(namePrefix, '-', '')}st${uniqueSuffix}'), 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS' // LRS wystarcza — to backup drugorzędny, nie jedyna kopia danych
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    accessTier: 'Cool' // backupy odczytywane rzadko
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

// Rola "Storage Blob Data Contributor" (built-in role ID stały w Azure:
// ba92f5b4-2d11-453d-a403-e96b0029c9fe) — VM może zapisywać/odczytywać
// backupy bez klucza dostępu do konta storage (żadnego sekretu na dysku).
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
