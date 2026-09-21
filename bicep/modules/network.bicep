// network.bicep
// VNet + subnet + Network Security Group — the equivalent of Oracle Cloud's VCN.
//
// NSG rules (AZ-104 domain: Configure and manage virtual networking):
//   - No inbound traffic from the Internet except SSH, and only from one
//     allow-listed IP address (parameter `adminSourceIp`) — never
//     0.0.0.0/0 on port 22.
//   - No other inbound ports — the strategy process doesn't listen on
//     anything, it only makes outbound connections (exchange WebSocket).
//   - Outbound: Azure's default rules (Allow VNet, Allow Internet) stay in
//     place, because the process MUST be able to make outbound requests to
//     the exchange / Key Vault / Log Analytics. Restricting outbound to
//     specific exchange IPs is left as a deliberate future enhancement
//     (exchange IP addresses tend to be unstable, so tightening this via
//     the NSG would risk interrupting the strategy).

@description('Deployment region, inherited from main.bicep')
param location string

@description('Resource name prefix, e.g. tradingvm-dev')
param namePrefix string

@description('Admin public IP allowed for SSH (CIDR, e.g. 203.0.113.4/32)')
param adminSourceIp string

@description('Common tags for all resources')
param tags object

var vnetAddressPrefix = '10.20.0.0/24'
var subnetAddressPrefix = '10.20.0.0/26'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${namePrefix}-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-SSH-From-Admin'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: adminSourceIp
          destinationAddressPrefix: '*'
        }
      }
      {
        // Explicit Deny-All rule for inbound Internet traffic, priority
        // just below Azure's default rules (65000) — documents the intent
        // "nothing else gets in", even though the default rules would
        // already block it.
        name: 'Deny-All-Inbound-Internet'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${namePrefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: subnetAddressPrefix
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output subnetId string = vnet.properties.subnets[0].id
output nsgId string = nsg.id
