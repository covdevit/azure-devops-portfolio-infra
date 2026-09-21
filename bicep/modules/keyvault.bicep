// keyvault.bicep
// Key Vault dostępny wyłącznie przez RBAC (nie legacy access policies) —
// zgodnie z obecnymi rekomendacjami Azure i tym, co jest testowane na AZ-104
// (domena: Manage Azure identities and governance).
//
// Sekrety NIE są tu tworzone z poziomu Bicep (nie chcemy kluczy API w stanie
// deploymentu / w historii Git). Jeśli strategia będzie potrzebować kluczy,
// wrzuca się je ręcznie (`az keyvault secret set`) PO wdrożeniu, jednorazowo,
// z lokalnej maszyny administratora — patrz docs/RUNBOOK.md.

@description('Region wdrożenia')
param location string

@description('Prefiks nazw zasobów')
param namePrefix string

@description('Principal ID tożsamości zarządzanej VM, która ma dostęp do odczytu sekretów')
param vmPrincipalId string

@description('Tagi wspólne')
param tags object

// Nazwa Key Vault musi być globalnie unikalna w Azure — dorzucamy unikalny
// sufiks wyliczony z resource group ID, żeby powtórne deploye (deploy →
// teardown → deploy) nie kolidowały z nazwą "zarezerwowaną" po usuniętym
// vaultcie (Key Vault ma soft-delete domyślnie na 90 dni).
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
    softDeleteRetentionInDays: 7 // minimum — to jest infra deploy-on-demand, nie produkcja
    enablePurgeProtection: false // celowo false: musimy móc `az keyvault purge` przy szybkich iteracjach teardown/deploy
    networkAcls: {
      defaultAction: 'Allow' // uproszczenie na start; patrz docs/ARCHITECTURE.md "możliwe rozszerzenia" dla private endpoint
      bypass: 'AzureServices'
    }
  }
}

// Rola "Key Vault Secrets User" (czytanie sekretów) dla Managed Identity VM.
// Built-in role ID jest stały w całym Azure: 4633458b-17de-408a-b874-0445c86b69e6
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
