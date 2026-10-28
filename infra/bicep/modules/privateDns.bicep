// Private DNS zones for every Private Endpoint, linked to the VNet so the host
// (and the microVMs, which resolve through it) get private IPs for the model,
// registry and monitoring endpoints.
param vnetId string
param tags object

var foundryZones = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
]

var monitorZones = [
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  'privatelink.blob.${environment().suffixes.storage}'
]

var acrZone = 'privatelink.azurecr.io'

var allZones = concat(foundryZones, monitorZones, [
  acrZone
])

resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in allZones: {
  name: zone
  location: 'global'
  tags: tags
}]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zone, i) in allZones: {
  parent: zones[i]
  name: 'link-sandbox-vnet'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}]

output foundryZoneIds array = [for (zone, i) in foundryZones: zones[i].id]
output monitorZoneIds array = [for (zone, i) in monitorZones: zones[length(foundryZones) + i].id]
output acrZoneId string = zones[length(allZones) - 1].id
