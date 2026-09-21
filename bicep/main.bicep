// main.bicep
// Punkt wejścia deploymentu. Subscription-scope, bo SAM tworzy resource
// group (żeby jedna komenda `az deployment sub create` postawiła
// wszystko od zera — zgodnie z modelem "deploy na żądanie").
//
// Uruchamiane przez: az deployment sub create --location <region>
//   --template-file bicep/main.bicep --parameters bicep/parameters/main.parameters.json
// (patrz docs/RUNBOOK.md dla pełnej komendy i przez workflow deploy.yml)

targetScope = 'subscription'

@description('Region wdrożenia wszystkich zasobów')
param location string = 'polandcentral'

@description('Nazwa środowiska — trafia do nazw zasobów i tagów, np. dev, portfolio')
param environmentName string = 'dev'

@description('Publiczny adres IP administratora dopuszczony do SSH (CIDR, np. 203.0.113.4/32) — WYMAGANE, brak sensownego default')
param adminSourceIp string

@description('Publiczny klucz SSH administratora (zawartość pliku .pub)')
param adminSshPublicKey string

@description('Nazwa użytkownika administratora VM')
param adminUsername string = 'azadmin'

var namePrefix = 'tradingvm-${environmentName}'

var tags = {
  project: 'azure-devops-portfolio'
  purpose: 'az104-prep-and-trading-strategy'
  managedBy: 'bicep'
  lifecycle: 'ephemeral-deploy-on-demand'
}

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: '${namePrefix}-rg'
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  name: 'networkDeployment'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    adminSourceIp: adminSourceIp
    tags: tags
  }
}

module vm 'modules/vm.bicep' = {
  name: 'vmDeployment'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    subnetId: network.outputs.subnetId
    adminSshPublicKey: adminSshPublicKey
    adminUsername: adminUsername
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyVaultDeployment'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    vmPrincipalId: vm.outputs.vmPrincipalId
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storageDeployment'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    vmPrincipalId: vm.outputs.vmPrincipalId
    tags: tags
  }
}

module monitor 'modules/monitor.bicep' = {
  name: 'monitorDeployment'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    vmId: vm.outputs.vmId
    vmName: vm.outputs.vmName
    tags: tags
  }
}

output resourceGroupName string = rg.name
output vmPublicIp string = vm.outputs.publicIpAddress
output vmName string = vm.outputs.vmName
output keyVaultName string = keyVault.outputs.keyVaultName
output keyVaultUri string = keyVault.outputs.keyVaultUri
output storageAccountName string = storage.outputs.storageAccountName
output logAnalyticsWorkspaceName string = monitor.outputs.logAnalyticsWorkspaceName
