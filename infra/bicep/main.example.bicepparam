using './main.bicep'

param prefix = 'aicyber'
param location = 'eastus2'

// Full 40-character commit SHA of acq to install (never a branch or tag).
param acqCommitSha = '0000000000000000000000000000000000000000'

// Throwaway key; the bootstrap locks this account. See README step 2.
param adminSshPublicKey = 'ssh-ed25519 AAAA... breakglass'

// Object ID of the Entra ID group of operators.
param operatorsGroupObjectId = '00000000-0000-0000-0000-000000000000'

param monthlyBudget = 1500
param budgetStartDate = '2026-11-01'
param budgetContactEmails = [
  'security-team@example.com'
]
