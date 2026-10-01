# One-time setup: Entra identity that GitHub Actions uses to deploy an environment.
# Uses OIDC federated credentials, so no client secret exists anywhere.
param(
    [string]$env = "dev",
    [string]$repo = "watavares/chargenet",
    [string]$sa = "sttfstateat1234",
    [string]$stateRg = "rg-tfstate",
    # Subscription-level roles. Platform also needs "Resource Policy Contributor".
    [string[]]$roles = @("Contributor"),
    # Platform only: may assign roles to environment identities, but never privileged ones
    [switch]$allowRoleAssignments
)

$appName = "sp-chargenet-github-$env"
$sub = az account show --query id -o tsv

# App registration + service principal (reuse if they already exist)
$appId = az ad app list --display-name $appName --query "[0].appId" -o tsv
if (-not $appId) { $appId = az ad app create --display-name $appName --query appId -o tsv }
$spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $spId) { $spId = az ad sp create --id $appId --query id -o tsv }

# Trust tokens from GitHub jobs that target this repo's environment.
# GitHub puts immutable owner/repo IDs in the subject, so look them up.
$ids = gh api "repos/$repo" -q '"\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"'
$credName = "github-env-$env"
$existing = az ad app federated-credential list --id $appId --query "[?name=='$credName'].name" -o tsv
if (-not $existing) {
    $cred = @{
        name      = $credName
        issuer    = "https://token.actions.githubusercontent.com"
        subject   = "repo:${ids}:environment:$env"
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $cred
    az ad app federated-credential create --id $appId --parameters "@$tmp" | Out-Null
    Remove-Item $tmp
}

# Deploy rights on the subscription, data access to the state container
foreach ($role in $roles) {
    az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
      --role $role --scope "/subscriptions/$sub" | Out-Null
}
if ($allowRoleAssignments) {
    # Owner, User Access Administrator, RBAC Administrator: can't be granted or removed,
    # so this identity can never escalate itself or anyone else to admin
    $privileged = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, f58310d9-a9f6-439a-9e8d-f62e7b41a168"
    $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {$privileged})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {$privileged}))"
    az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
      --role "Role Based Access Control Administrator" --scope "/subscriptions/$sub" `
      --condition $condition --condition-version "2.0" | Out-Null
}

$saScope = az storage account show -n $sa -g $stateRg --query id -o tsv
az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
  --role "Storage Blob Data Contributor" --scope $saScope | Out-Null

Write-Host "Set these as variables on the GitHub environment '$env':"
Write-Host "  AZURE_CLIENT_ID       = $appId"
Write-Host "  AZURE_TENANT_ID       = $(az account show --query tenantId -o tsv)"
Write-Host "  AZURE_SUBSCRIPTION_ID = $sub"
