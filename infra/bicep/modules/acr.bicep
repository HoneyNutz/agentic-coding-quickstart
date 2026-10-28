// Private registry for digest-pinned agent images, so the host never pulls
// from Docker Hub. Premium is required for Private Endpoints. Anonymous pull
// lets msb pull without registry credentials on the host; it is safe because
// the registry is reachable only from inside the VNet.
param name string
param location string
param privateEndpointSubnetId string
param dnsZoneId string
param tags object

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Premium'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: true
    publicNetworkAccess: 'Disabled'
    networkRuleBypassOptions: 'AzureServices'
    dataEndpointEnabled: false
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${name}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'registry'
        properties: {
          privateLinkServiceId: registry.id
          groupIds: [
            'registry'
          ]
        }
      }
    ]
  }
}

resource peDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'acr'
        properties: {
          privateDnsZoneId: dnsZoneId
        }
      }
    ]
  }
}

output name string = registry.name
output loginServer string = registry.properties.loginServer
