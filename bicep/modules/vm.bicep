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
//
// Initial provisioning is handled by cloud-init: it installs Python,
// creates the application directory and REGISTERS the systemd service, but
// does NOT yet start any strategy code — that's the job of the separate
// `deploy-app.yml` workflow, run once the strategy code is ready (see
// section 8 of the original outline: "build the infrastructure now, the
// strategy is just a file to be swapped in later").

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
    // Standard, not Basic: Azure retired the ability to create Basic SKU
    // public IPs entirely (retirement completed 30 Sept 2025) — any
    // subscription now gets IPv4BasicSkuPublicIpCountLimitReached with a
    // quota of 0 if it tries. Standard is the only option going forward,
    // and it is NOT covered by the Always Free grant (Basic was), so this
    // is a small real cost — same reasoning as the VM size change above:
    // acceptable under the deploy-on-demand model. See docs/ARCHITECTURE.md.
    name: 'Standard'
  }
  properties: {
    // Static, not Dynamic: we want to know the IP address right after
    // deployment (needed in the output and in the RUNBOOK for `ssh`),
    // rather than only after the VM has started. Standard SKU only
    // supports Static anyway (Dynamic isn't an option for it).
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
//
// IMPORTANT Bicep gotcha: triple-quoted (multi-line) strings are RAW/VERBATIM
// text — unlike normal Bicep strings, they do NOT support ${...}
// interpolation at all. A first version of this file wrote
// `chown -R ${adminUsername}:${adminUsername} ...` here, which looked like
// interpolation but was silently emitted into the actual cloud-init script
// as the literal, un-substituted text `${adminUsername}` — so cloud-init ran
// `chown -R ${adminUsername}:${adminUsername} /opt/trading-strategy` as a
// literal (nonexistent) username, which failed silently (chown on an
// unresolvable name doesn't fail the runcmd script's exit code in a way
// that surfaces here) and left the directory owned by root. Discovered by
// SSHing in after a real deploy and finding root:root instead of
// azadmin:azadmin.
//
// Workaround: keep the multi-line template literal (no interpolation
// attempted inside it) with an explicit placeholder token, then substitute
// it with `replace()` — a normal Bicep function call works fine, since the
// text it operates on is just a regular Bicep string value by that point.
var cloudInitTemplate = '''#cloud-config
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
  - chown -R __ADMIN_USERNAME__:__ADMIN_USERNAME__ /opt/trading-strategy
'''
var cloudInit = base64(replace(cloudInitTemplate, '__ADMIN_USERNAME__', adminUsername))

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
