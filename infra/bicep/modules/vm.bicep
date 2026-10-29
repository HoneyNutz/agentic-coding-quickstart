// RHEL 9 sandbox host. No public IP; operators reach it through Bastion with
// Entra ID. cloud-init runs host/bootstrap-host.sh, which installs acq at a
// pinned commit, hardens the host, and locks the throwaway local admin.
param prefix string
param location string
param vmSize string
param securityType string
param subnetId string
param adminSshPublicKey string
param acqRepoUrl string
param acqCommitSha string
param maxSandboxes int
param operatorsGroupObjectId string
param dataCollectionRuleId string
param dataCollectionEndpointId string
param autoShutdownTime string
param autoShutdownTimeZone string
param tags object

@description('Name of the required local admin. The bootstrap locks it; operators sign in with Entra ID.')
param adminUsername string = 'breakglass'

var vmName = '${prefix}-host'

// Built-in role definition IDs.
var vmUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'

// Render host/cloud-init.yaml: embed the host files and fill in the settings.
var ci0 = loadTextContent('../../host/cloud-init.yaml')
var ci1 = replace(ci0, '__BOOTSTRAP_B64__', loadFileAsBase64('../../host/bootstrap-host.sh'))
var ci2 = replace(ci1, '__SANDBOX_RUN_B64__', loadFileAsBase64('../../host/sandbox-run'))
var ci3 = replace(ci2, '__AUDIT_RULES_B64__', loadFileAsBase64('../../host/audit.rules'))
var ci4 = replace(ci3, '__ACQ_REPO_URL__', acqRepoUrl)
var ci5 = replace(ci4, '__ACQ_COMMIT_SHA__', acqCommitSha)
var ci6 = replace(ci5, '__MAX_SANDBOXES__', string(maxSandboxes))
var cloudInit = replace(ci6, '__ADMIN_USER__', adminUsername)

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: subnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    securityProfile: securityType == 'TrustedLaunch' ? {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    } : null
    storageProfile: {
      imageReference: {
        publisher: 'RedHat'
        offer: 'RHEL'
        sku: '9-lvm-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 256
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInit)
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
        patchSettings: {
          patchMode: 'ImageDefault'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AADSSHLoginForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

resource monitorAgent 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  scope: vm
  name: 'host-syslog'
  properties: {
    dataCollectionRuleId: dataCollectionRuleId
  }
}

// The AMA reads its configuration through this well-known association name.
resource dceAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  scope: vm
  name: 'configurationAccessEndpoint'
  properties: {
    dataCollectionEndpointId: dataCollectionEndpointId
  }
}

// Standing access is "User Login" only (no sudo). "Administrator Login" is
// granted just-in-time through PIM; see docs/ARCHITECTURE.md.
resource operatorsLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vm
  name: guid(vm.id, operatorsGroupObjectId, vmUserLoginRoleId)
  properties: {
    principalId: operatorsGroupObjectId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmUserLoginRoleId)
  }
}

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: autoShutdownTimeZone
    targetResourceId: vm.id
  }
}

output vmName string = vm.name
output vmId string = vm.id
