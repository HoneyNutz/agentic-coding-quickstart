// Hardened Azure host for adversarial AI cyber-testing with acq + msb microVMs.
// Deploy twice: first with setupEgressOpen=true (bootstrap needs RHUI, GitHub,
// the msb release bundle), then again with setupEgressOpen=false to lock the
// host down to Private Endpoints and Entra ID. See docs/ARCHITECTURE.md.
targetScope = 'resourceGroup'

@description('Short prefix for every resource name (3-10 lowercase letters/digits).')
@minLength(3)
@maxLength(10)
param prefix string

param location string = resourceGroup().location

@description('True only for the first (bootstrap) deployment. Redeploy with false to lock egress.')
param setupEgressOpen bool = true

@description('VM size. Must support nested virtualization (Dsv5/Ddsv5/Esv5 families).')
param vmSize string = 'Standard_D8s_v5'

@description('Standard or TrustedLaunch. Never a Confidential VM type: those do not expose nested virtualization.')
@allowed([
  'Standard'
  'TrustedLaunch'
])
param securityType string = 'TrustedLaunch'

@description('Throwaway SSH public key for the required local admin. The bootstrap locks this account; operators sign in with Entra ID.')
param adminSshPublicKey string

@description('Repository the host installs acq from.')
param acqRepoUrl string = 'https://github.com/HoneyNutz/agentic-coding-quickstart.git'

@description('Full 40-character commit SHA of acq to install. Never a branch or tag.')
@minLength(40)
@maxLength(40)
param acqCommitSha string

@description('Maximum concurrent sandboxes on the host.')
@minValue(1)
@maxValue(16)
param maxSandboxes int = 4

@description('Entra ID group object ID granted standing "Virtual Machine User Login" (no sudo).')
param operatorsGroupObjectId string

@description('Daily auto-shutdown time, HHmm, in autoShutdownTimeZone.')
param autoShutdownTime string = '1900'
param autoShutdownTimeZone string = 'Eastern Standard Time'

@description('Monthly budget for the resource group, in the billing currency.')
param monthlyBudget int = 1500

@description('First day of the current month, yyyy-MM-01. Budgets cannot start in the past or mid-month.')
param budgetStartDate string

param budgetContactEmails array

@description('One Foundry account per agent so every agent has its own revocable key and quota. Model names and versions vary by region: check availability before deploying.')
param foundryAccounts array = [
  {
    agent: 'opencode'
    deployments: [
      {
        name: 'gpt-opencode'
        format: 'OpenAI'
        model: 'gpt-4.1'
        version: '2025-04-14'
        skuName: 'GlobalStandard'
        capacityKTpm: 50
      }
    ]
  }
  {
    agent: 'codex'
    deployments: [
      {
        name: 'gpt-codex'
        format: 'OpenAI'
        model: 'gpt-4.1'
        version: '2025-04-14'
        skuName: 'GlobalStandard'
        capacityKTpm: 50
      }
    ]
  }
  {
    agent: 'claude'
    deployments: [
      {
        name: 'claude-sonnet'
        format: 'Anthropic'
        model: 'claude-sonnet-4-5'
        version: '1'
        skuName: 'GlobalStandard'
        capacityKTpm: 50
      }
    ]
  }
]

var tags = {
  workload: 'ai-cyber-sandbox'
  prefix: prefix
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    prefix: prefix
    location: location
    setupEgressOpen: setupEgressOpen
    tags: tags
  }
}

module dns 'modules/privateDns.bicep' = {
  name: 'privateDns'
  params: {
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

module bastion 'modules/bastion.bicep' = {
  name: 'bastion'
  params: {
    prefix: prefix
    location: location
    bastionSubnetId: network.outputs.bastionSubnetId
    tags: tags
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    prefix: prefix
    location: location
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    dnsZoneIds: dns.outputs.monitorZoneIds
    tags: tags
  }
}

@batchSize(1)
module foundry 'modules/foundry.bicep' = [for acct in foundryAccounts: {
  name: 'foundry-${acct.agent}'
  params: {
    name: '${prefix}-ai-${acct.agent}-${uniqueString(resourceGroup().id, acct.agent)}'
    location: location
    deployments: acct.deployments
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    dnsZoneIds: dns.outputs.foundryZoneIds
    tags: union(tags, { agent: acct.agent })
  }
}]

module acr 'modules/acr.bicep' = {
  name: 'acr'
  params: {
    name: '${prefix}acr${uniqueString(resourceGroup().id)}'
    location: location
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    dnsZoneId: dns.outputs.acrZoneId
    tags: tags
  }
}

module vm 'modules/vm.bicep' = {
  name: 'vm'
  params: {
    prefix: prefix
    location: location
    vmSize: vmSize
    securityType: securityType
    subnetId: network.outputs.vmSubnetId
    adminSshPublicKey: adminSshPublicKey
    acqRepoUrl: acqRepoUrl
    acqCommitSha: acqCommitSha
    maxSandboxes: maxSandboxes
    operatorsGroupObjectId: operatorsGroupObjectId
    dataCollectionRuleId: monitoring.outputs.dataCollectionRuleId
    dataCollectionEndpointId: monitoring.outputs.dataCollectionEndpointId
    autoShutdownTime: autoShutdownTime
    autoShutdownTimeZone: autoShutdownTimeZone
    tags: tags
  }
}

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: '${prefix}-budget'
  properties: {
    category: 'Cost'
    amount: monthlyBudget
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
    }
    notifications: {
      actual80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: budgetContactEmails
      }
      forecast100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: budgetContactEmails
      }
    }
  }
}

output vmName string = vm.outputs.vmName
output vmResourceId string = vm.outputs.vmId
output bastionName string = bastion.outputs.bastionName
output hostNsgName string = network.outputs.hostNsgName
output acrLoginServer string = acr.outputs.loginServer
output acrName string = acr.outputs.name
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceId
output foundryEndpoints array = [for (acct, i) in foundryAccounts: {
  agent: acct.agent
  accountName: foundry[i].outputs.name
  customSubdomain: foundry[i].outputs.customSubdomain
  deployments: map(acct.deployments, d => d.name)
}]
