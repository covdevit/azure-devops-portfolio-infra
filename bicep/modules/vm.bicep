// vm.bicep
// A single small burstable VM, Ubuntu 22.04 LTS, with a System-Assigned
// Managed Identity — no .env file with secrets on disk (AZ-104 domain:
// Manage Azure identities).
//
// VM size: originally Standard_B1s (the Always Free tier size). Querying
// `az vm list-skus --location polandcentral --size Standard_B --all` showed
// that the ENTIRE legacy "B-series" family (B1s, B1ms, B2s, B2ms, B4ms,
// B8ms, ...) is NotAvailableForSubscription for this account in Poland
// Central, while the whole newer "_v2" burstable family (B2s_v2, B4s_v2,
// ...) is unrestricted. Switched to Standard_B2s_v2 — the closest modern
// equivalent (2 vCPU / 4 GiB RAM). Trade-off: B2s_v2 is not part of the
// Always Free 12-month grant (only classic B1s was), so this now incurs a
// small real cost — acceptable given the deploy-on-demand model, since
// you're only billed while the VM actually exists. See docs/ARCHITECTURE.md.

@description('Deployment region')
param location string

@description('Resource name prefix')
param namePrefix string

@description('ID of the subnet the VM attaches to')
param subnetId string

@description('Admin SSH public key (contents of the .pub file)')
param adminSshPublicKey string

@description('VM admin username')
param adminUsername string = 'azadmin'

@description('Common tags')
param tags object

var vmSize = 'Standard_B2s_v2'

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${namePrefix}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Basic' // Basic SKU is enough and falls within Always Free; Standard SKU is billed per hour
  }
  properties: {
    // Static, not Dynamic: we want to know the IP address right after
    // deployment (needed in the output and in the RUNBOOK for `ssh`),
    // rather than only after the VM has started.
    // Basic SKU supports Static and stays within Always Free.
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${namePrefix}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

// cloud-init: prepares the machine but does not start the strategy.
var cloudInit = base64('''#cloud-config
package_update: true
package_upgrade: false
packages:
  - python3
  - python3-pip
  - python3-venv
  - git
runcmd:
  - mkdir -p /opt/trading-strategy/data
  - python3 -m venv /opt/trading-strategy/venv
  - chown -R ${adminUsername}:${adminUsername} /opt/trading-strategy
''')

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${namePrefix}-vm'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: '${namePrefix}-vm'
      adminUsername: adminUsername
      customData: cloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS' // Always Free covers a Standard HDD/SSD disk up to 64 GB — see docs/ARCHITECTURE.md
        }
        diskSizeGB: 30
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
output vmPrincipalId string = vm.identity.principalId
output publicIpAddress string = publicIp.properties.ipAddress
