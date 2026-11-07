# Azure Blob Storage source

imgproxy reading source images from a private Blob Storage container via the `abs://` URL scheme. The module grants
`Storage Blob Data Reader` to the imgproxy managed identity, so the container stays private.

## Azure setup

You need an Azure subscription and the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), authenticated (the [permissions](../../README.md#permissions) the module needs are described in the repository root):

```bash
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

## Prerequisites

Create a resource group, a Key Vault with the signing keys (see [signed](../signed/)) and a private storage account
for source images:

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

az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-keys --value "$(openssl rand -hex 64)" -o none
az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-salts --value "$(openssl rand -hex 64)" -o none

STORAGE_ACCOUNT=imgproxyimages$RANDOM

az storage account create --name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --location $LOCATION \
  --sku Standard_LRS --allow-blob-public-access false
az role assignment create --role "Storage Blob Data Contributor" --assignee $USER_ID \
  --scope $(az storage account show --name $STORAGE_ACCOUNT --query id -o tsv)

az storage container create --name images --account-name $STORAGE_ACCOUNT --auth-mode login
```

Role assignments take a minute or two to propagate; if `az keyvault secret set` fails with a permission error, wait and retry.

## Deploy

```bash
cat > terraform.tfvars <<EOF
resource_group_name = "$RESOURCE_GROUP"
key_vault_name = "$KEY_VAULT"
storage_account_name = "$STORAGE_ACCOUNT"
EOF

terraform init
terraform plan
terraform apply

az storage blob upload --account-name $STORAGE_ACCOUNT --container-name images \
  --name photo.jpg --file photo.jpg --auth-mode login
```

Sign the request as in [signed](../signed/), with `IMG_PATH` pointing at the blob (`abs://<container>/<blob>`):

```bash
(
URL=$(terraform output -raw url)
KEY=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-keys --query value -o tsv)
SALT=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-salts --query value -o tsv)
IMG_PATH="/rs:fit:300:200/plain/abs://images/photo.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

The module does not create storage accounts: it only grants the imgproxy managed identity read access to the ones you
list in `source_storage_accounts`. imgproxy reads from a single account at a time (`IMGPROXY_ABS_NAME`, set to the first
one listed).

## Cleanup

```bash
terraform destroy
```

The resource group, the Key Vault and the storage account were created with `az`, so delete them separately:

```bash
az group delete --name $RESOURCE_GROUP --yes
az keyvault purge --name $KEY_VAULT
```

## Next

Continue with [cdn](../cdn/).
