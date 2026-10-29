// Host-side audit pipeline: Azure Monitor Agent -> Data Collection Endpoint ->
// Log Analytics, all over an Azure Monitor Private Link Scope with ingestion set
// to PrivateOnly. Logs are collected on the host, outside the guest, so an
// adversarial model cannot tamper with them.
param prefix string
param location string
param privateEndpointSubnetId string
param dnsZoneIds array
param tags object

@description('Retention in days for the audit workspace.')
param retentionInDays int = 90

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    publicNetworkAccessForIngestion: 'Disabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: '${prefix}-dce'
  location: location
  tags: tags
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Disabled'
    }
  }
}

// Syslog facilities written by the host bootstrap:
//   auth/authpriv  - Entra ID sign-ins and sudo
//   kern/daemon    - KVM, msb, systemd
//   local5         - sandbox-run session start/stop and transcripts
//   local6         - auditd events (audisp syslog plugin)
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: '${prefix}-dcr-host'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {
      syslog: [
        {
          name: 'hostSyslog'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'authpriv'
            'kern'
            'daemon'
            'local5'
            'local6'
          ]
          logLevels: [
            'Debug'
            'Info'
            'Notice'
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'auditWorkspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'auditWorkspace'
        ]
      }
    ]
  }
}

resource ampls 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: '${prefix}-ampls'
  location: 'global'
  tags: tags
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'Open'
    }
  }
}

resource amplsWorkspace 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'workspace'
  properties: {
    linkedResourceId: workspace.id
  }
}

resource amplsDce 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-07-01-preview' = {
  parent: ampls
  name: 'dce'
  properties: {
    linkedResourceId: dce.id
  }
}

resource amplsPe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${prefix}-pe-ampls'
  location: location
  tags: tags
  dependsOn: [
    amplsWorkspace
    amplsDce
  ]
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'ampls'
        properties: {
          privateLinkServiceId: ampls.id
          groupIds: [
            'azuremonitor'
          ]
        }
      }
    ]
  }
}

resource amplsDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: amplsPe
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

output workspaceId string = workspace.id
output dataCollectionRuleId string = dcr.id
output dataCollectionEndpointId string = dce.id
