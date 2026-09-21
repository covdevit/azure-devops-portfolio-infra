// network.bicep
// VNet + subnet + Network Security Group — odpowiednik VCN z Oracle Cloud.
//
// Zasady NSG (AZ-104 domena: Configure and manage virtual networking):
//   - Brak inbound z Internetu poza SSH, i to tylko z jednego dopuszczonego
//     adresu IP (parametr `adminSourceIp`) — nigdy 0.0.0.0/0 na port 22.
//   - Brak innych portów inbound — proces strategii nie nasłuchuje niczego,
//     tylko łączy się wychodząco (WebSocket giełdy).
//   - Outbound: domyślne reguły Azure (Allow VNet, Allow Internet) pozostają,
//     bo proces MUSI móc wystawić żądania wychodzące do exchange/Key Vault/
//     Log Analytics. Zawężanie outbound do konkretnych adresów exchange
//     zostawione jako świadome rozszerzenie na przyszłość (adresy IP giełd
//     bywają niestabilne — zawężenie przez NSG groziłoby przerwami w
//     działaniu strategii).

@description('Region wdrożenia, dziedziczony z main.bicep')
param location string

@description('Prefiks nazw zasobów, np. tradingvm-dev')
param namePrefix string

@description('Publiczny adres IP administratora dopuszczony do SSH (CIDR, np. 203.0.113.4/32)')
param adminSourceIp string

@description('Tagi wspólne dla wszystkich zasobów')
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
        // Jawna reguła Deny-All na inbound z Internetu, z priorytetem tuż
        // poniżej reguł domyślnych Azure (65000) — dokumentuje intencję
        // "nic więcej nie wchodzi", nawet jeśli domyślne reguły i tak by to
        // zablokowały.
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
