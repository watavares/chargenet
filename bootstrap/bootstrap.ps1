# One-time setup: Azure storage for Terraform remote state.
# Storage account name must be globally unique, lowercase, 3-24 chars.
param(
    [string]$sa = "sttfstateat1234",
    [string]$rg = "rg-tfstate",
    [string]$location = "westeurope"
)

$ErrorActionPreference = "Stop"

az group create -n $rg -l $location
az storage account create -n $sa -g $rg -l $location `
  --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false

# Give yourself data access via Entra (no storage keys)
$me = az ad signed-in-user show --query id -o tsv
$scope = az storage account show -n $sa -g $rg --query id -o tsv
az role assignment create --role "Storage Blob Data Contributor" --assignee $me --scope $scope

# Role assignments can take a minute or two to propagate, so retry
for ($i = 1; $i -le 10; $i++) {
    az storage container create -n tfstate --account-name $sa --auth-mode login
    if ($LASTEXITCODE -eq 0) { break }
    Write-Host "Container create failed (attempt $i), waiting 30s for role assignment..."
    Start-Sleep -Seconds 30
}
