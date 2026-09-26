// main.bicep
// Deployment entry point. Subscription-scope, because it creates the
// resource group ITSELF (so a single `az deployment sub create` command
// stands up everything from scratch — matching the "deploy-on-demand" model).
//
// Run with: az deployment sub create --location <region>
//   --template-file bicep/main.bicep --parameters bicep/parameters/main.parameters.json
// (see docs/RUNBOOK.md for the full command, and the deploy.yml workflow)

targetScope = 'subscription'

@description('Deployment region for all resources')
// polandcentral: West Europe was tried as an alternative, but this
// subscription is restricted at the ACCOUNT level to a small set of
// regions ("the selected region is currently not accepting new
// customers") — a common limitation on new/free Azure subscriptions,
// separate from any per-SKU capacity issue. Poland Central passed that
// check; West Europe did not. See docs/ARCHITECTURE.md for the full story
// (including why the VM size also had to change).
param location string = 'polandcentral'

@description('Environment name — used in resource names and tags, e.g. dev, portfolio')
param environmentName string = 'dev'

@description('Admin public IP allowed for SSH (CIDR, e.g. 203.0.113.4/32) — REQUIRED, no sensible default')
param adminSourceIp string

@description('Admin SSH public key (contents of the .pub file)')
param adminSshPublicKey string

@description('VM admin username')
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
