// One Foundry (AIServices) account per agent. An account has only two keys, so
// a separate account is what gives each agent its own revocable key. Public
// network access is off: the account is reachable only via its Private Endpoint.
// Each deployment's capacity is its tokens-per-minute quota (in thousands).
param name string
param location string
param deployments array
param privateEndpointSubnetId string
param dnsZoneIds array
param tags object

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: name
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
    }
    // API keys stay enabled: acq injects the key on the host, so the guest
    // never holds it. Entra tokens would expire hourly and need an identity.
    disableLocalAuth: false
  }
}

@batchSize(1)
resource modelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [for d in deployments: {
  parent: account
  name: d.name
  sku: {
    name: d.skuName
    capacity: d.capacityKTpm
  }
  properties: {
    model: {
      format: d.format
      name: d.model
      version: d.version
    }
  }
}]

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
        name: 'account'
        properties: {
          privateLinkServiceId: account.id
          groupIds: [
            'account'
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
    privateDnsZoneConfigs: [for (zoneId, i) in dnsZoneIds: {
      name: 'zone${i}'
      properties: {
        privateDnsZoneId: zoneId
      }
    }]
  }
}

output name string = account.name
output customSubdomain string = name
