// vm.bicep
// Pojedyncza VM B1S (Always Free tier przez pierwsze 12 miesięcy), Ubuntu
// 22.04 LTS, z System-Assigned Managed Identity — bez pliku .env z
// sekretami na dysku (AZ-104 domena: Manage Azure identities).
//
// Provisioning startowy robi cloud-init: instaluje Pythona, tworzy katalog
// aplikacji i REJESTRUJE usługę systemd, ale NIE uruchamia jeszcze żadnego
// kodu strategii — to zadanie workflow `deploy-app.yml`, uruchamianego
// osobno, gdy kod strategii jest gotowy (patrz sekcja 8 konspektu: "budować
// infrastrukturę już teraz, strategia to plik do podmiany później").

@description('Region wdrożenia')
param location string

@description('Prefiks nazw zasobów')
param namePrefix string

@description('ID subnetu, do którego podłączona jest VM')
param subnetId string

@description('Publiczny klucz SSH administratora (zawartość pliku .pub)')
param adminSshPublicKey string

@description('Nazwa użytkownika administratora VM')
param adminUsername string = 'azadmin'

@description('Tagi wspólne')
param tags object

var vmSize = 'Standard_B1s'

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${namePrefix}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Basic' // Basic SKU wystarcza i mieści się w Always Free; Standard SKU jest płatny per godzina
  }
  properties: {
    // Static, nie Dynamic: chcemy znać adres IP od razu po deploymencie
    // (potrzebny w output i w RUNBOOK do `ssh`), a nie dopiero po starcie VM.
    // Basic SKU obsługuje Static i mieści się w Always Free.
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

// cloud-init: przygotowuje maszynę, ale nie startuje strategii.
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
          storageAccountType: 'Standard_LRS' // Always Free obejmuje dysk Standard HDD/SSD do 64 GB — patrz docs/ARCHITECTURE.md
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
