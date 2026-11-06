# Complete imgproxy Deployment Example

This example demonstrates a full-featured imgproxy deployment with all available features:

- imgproxy Pro with license key
- Request signing with configurable key size
- Source URL encryption
- Authorization token (Bearer auth)
- OpenTelemetry-based monitoring to Azure Monitor
- Blob Storage integration for source images and result cache
- Azure Front Door CDN
- Additional secrets for third-party integrations
- Custom resource limits, concurrency, and scaling
- Resource tags

## Azure setup

You need an Azure subscription and the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), authenticated:

```bash
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

## Prerequisites

**Create a resource group, Key Vault secrets and storage accounts:**

```bash
RESOURCE_GROUP=imgproxy-example
LOCATION=germanywestcentral

az group create --name $RESOURCE_GROUP --location $LOCATION

KEY_VAULT=imgproxy-kv-$RANDOM
USER_ID=$(az ad signed-in-user show --query id -o tsv)

az keyvault create --name $KEY_VAULT --resource-group $RESOURCE_GROUP --location $LOCATION \
  --enable-rbac-authorization true
az role assignment create --role "Key Vault Secrets Officer" --assignee $USER_ID \
  --scope $(az keyvault show --name $KEY_VAULT --query id -o tsv)

# Signing keys (required)
az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-keys --value "$(openssl rand -hex 64)" -o none
az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-salts --value "$(openssl rand -hex 64)" -o none

# imgproxy Pro (if using pro = true); the password is for docker.imgproxy.pro, or for your own registry set via repo
az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-pro-license --value "your-license-key" -o none
az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-pro-password --value "your-registry-password" -o none

# Optional: authorization token (Bearer auth)
az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-secret --value "$(openssl rand -hex 32)" -o none

# Optional: source URL encryption key
az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-source-url-key --value "$(openssl rand -hex 16)" -o none

# Storage accounts for source images and the result cache (not managed by Terraform)
STORAGE_ACCOUNT=imgproxyimages$RANDOM

az storage account create --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --location $LOCATION \
  --sku Standard_LRS --allow-blob-public-access false
az role assignment create --role "Storage Blob Data Contributor" --assignee $USER_ID \
  --scope $(az storage account show --name $STORAGE_ACCOUNT --query id -o tsv)

az storage container create --name images --account-name $STORAGE_ACCOUNT --auth-mode login

CACHE_ACCOUNT=imgproxycache$RANDOM

az storage account create --name $CACHE_ACCOUNT --resource-group $RESOURCE_GROUP --location $LOCATION \
  --sku Standard_LRS --allow-blob-public-access false
az role assignment create --role "Storage Blob Data Contributor" --assignee $USER_ID \
  --scope $(az storage account show --name $CACHE_ACCOUNT --query id -o tsv)

az storage container create --name cache --account-name $CACHE_ACCOUNT --auth-mode login
```

Role assignments take a minute or two to propagate; if `az keyvault secret set` fails with a permission error, wait and retry.

## Deploy

Everything is configured in [main.tf](main.tf); edit it to enable the commented-out options (Bearer auth, source URL
encryption, trusted signatures, extra secrets, CDN).

1. **Deploy:**

```bash
cat > terraform.tfvars <<EOF
resource_group_name = "$RESOURCE_GROUP"
key_vault_name = "$KEY_VAULT"
source_storage_account_name = "$STORAGE_ACCOUNT"
cache_storage_account_name = "$CACHE_ACCOUNT"
EOF

terraform init
terraform plan
terraform apply
```

2. **Access the service:**

```bash
terraform output url
```

3. **If CDN is enabled, point DNS:**

```bash
# Get the Front Door hostname
terraform output cdn_hostname

# Create a CNAME record pointing cdn.example.com to this hostname, plus the _dnsauth TXT record
# from `terraform output module.imgproxy.cdn_custom_domain_validation_tokens`
# Azure provisions a managed TLS certificate automatically once the domain validates
```

## Testing Blob Storage Integration

Upload a test image to the source container:

```bash
az storage blob upload --account-name $STORAGE_ACCOUNT --container-name images \
  --name photo.jpg --file test-image.jpg --auth-mode login
```

Then access it via imgproxy using a signed URL:

```bash
(
URL=$(terraform output -raw url)
KEY=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-keys --query value -o tsv)
SALT=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-salts --query value -o tsv)
IMG_PATH="/plain/abs://images/photo.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

## Verifying Monitoring

After deployment with `enable_monitoring = true`, verify telemetry is flowing:

1. Go to Azure Portal → Application Insights → `imgproxy-monitoring` → Transaction search and confirm new traces appear for imgproxy requests
2. Go to Application Insights → Metrics and pick the custom metrics namespace; imgproxy metrics such as `requests_total`, `request_duration_seconds`, `status_codes_total` and `workers_utilization` appear within a few minutes of the first requests
3. Go to the Log Analytics workspace `imgproxy-logs` → Logs and query `ContainerAppConsoleLogs_CL` filtered by your Container App name

## Cleanup

```bash
terraform destroy
```

The resource group, the Key Vault and the storage accounts were created with `az`, so delete them separately (and remove
the DNS records if you added a domain):

```bash
az group delete --name $RESOURCE_GROUP --yes
az keyvault purge --name $KEY_VAULT
```
