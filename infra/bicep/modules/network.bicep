// VNet with three subnets: the sandbox host, Private Endpoints, and Bastion.
// The host NSG is the outer containment layer: it denies the Internet and the
// rest of the VNet, allowing only Private Endpoints and Entra ID (plus, during
// bootstrap only, outbound HTTP/HTTPS).
param prefix string
param location string
param setupEgressOpen bool
param tags object

var addressSpace = '10.42.0.0/24'
var vmSubnetPrefix = '10.42.0.0/27'
var privateEndpointSubnetPrefix = '10.42.0.32/27'
var bastionSubnetPrefix = '10.42.0.64/26'

var baseOutboundRules = [
  {
    name: 'AllowPrivateEndpointsHttps'
    properties: {
      priority: 100
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: vmSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: privateEndpointSubnetPrefix
      destinationPortRange: '443'
    }
  }
  {
    // Entra ID sign-in (AADSSHLoginForLinux) has no Private Link option.
    name: 'AllowEntraId'
    properties: {
      priority: 110
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: vmSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureActiveDirectory'
      destinationPortRange: '443'
    }
  }
]

var setupOutboundRules = [
  {
    name: 'SetupOnlyAllowInternetHttps'
    properties: {
      priority: 200
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: vmSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '443'
    }
  }
  {
    name: 'SetupOnlyAllowInternetHttp'
    properties: {
      priority: 210
      direction: 'Outbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: vmSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '80'
    }
  }
]

// Default-deny backstops plus the single inbound allow (SSH from Bastion).
var closingRules = [
  {
    name: 'DenyInternetOutbound'
    properties: {
      priority: 4000
      direction: 'Outbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRange: '*'
    }
  }
  {
    // Overrides the default AllowVnetOutBound so a compromised host cannot
    // reach anything else in the VNet (Bastion replies are stateful).
    name: 'DenyVnetOutbound'
    properties: {
      priority: 4010
      direction: 'Outbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRange: '*'
    }
  }
  {
    name: 'AllowSshFromBastion'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: bastionSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: vmSubnetPrefix
      destinationPortRange: '22'
    }
  }
  {
    name: 'DenyAllInbound'
    properties: {
      priority: 4096
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
]

resource hostNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-nsg-host'
  location: location
  tags: tags
  properties: {
    securityRules: concat(baseOutboundRules, setupEgressOpen ? setupOutboundRules : [], closingRules)
  }
}

resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: '${prefix}-nsg-pe'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsFromHost'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: vmSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressSpace
      ]
    }
    subnets: [
      {
        name: 'snet-host'
        properties: {
          addressPrefix: vmSubnetPrefix
          networkSecurityGroup: {
            id: hostNsg.id
          }
          natGateway: {
            id: natGateway.id
          }
          defaultOutboundAccess: false
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          networkSecurityGroup: {
            id: privateEndpointNsg.id
          }
          privateEndpointNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      }
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
    ]
  }
}

// defaultOutboundAccess=false removes implicit SNAT. The NAT gateway is the
// host's only path out; the NSG above decides what may use it (Entra ID always,
// the Internet only while setupEgressOpen is true).
resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${prefix}-pip-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: '${prefix}-nat'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natIp.id
      }
    ]
  }
}

output vnetId string = vnet.id
output vmSubnetId string = vnet.properties.subnets[0].id
output privateEndpointSubnetId string = vnet.properties.subnets[1].id
output bastionSubnetId string = vnet.properties.subnets[2].id
output hostNsgName string = hostNsg.name
