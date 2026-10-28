// Azure Bastion is the only way in. Standard SKU enables native-client
// tunnelling, so operators can `az network bastion ssh --auth-type AAD`.
param prefix string
param location string
param bastionSubnetId string
param tags object

resource bastionIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-pip-bastion'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: '${prefix}-bastion'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    disableCopyPaste: true
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: bastionIp.id
          }
        }
      }
    ]
  }
}

output bastionName string = bastion.name
