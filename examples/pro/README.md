# imgproxy Pro

imgproxy Pro with a license key and a Blob Storage result cache. It fetches public placeholder images, so no source
storage account is needed.

## Azure setup

You need an Azure subscription and the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), authenticated (the [permissions](../../README.md#permissions) the module needs are described in the repository root):

```bash
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

## Prerequisites

Create a resource group, a Key Vault with the imgproxy Pro secrets (`imgproxy-pro-password` is the
`docker.imgproxy.pro` registry password, passed as `repo_password_secret`) and the signing keys
(see [signed](../signed/)), and a private storage account for the result cache:

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

az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-pro-license --value "your-license-key" -o none
az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-pro-password --value "your-registry-password" -o none

az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-keys --value "$(openssl rand -hex 64)" -o none
az keyvault secret set --vault-name $KEY_VAULT --name imgproxy-salts --value "$(openssl rand -hex 64)" -o none

CACHE_ACCOUNT=imgproxycache$RANDOM

az storage account create --name $CACHE_ACCOUNT --resource-group $RESOURCE_GROUP --location $LOCATION \
  --sku Standard_LRS --allow-blob-public-access false
az role assignment create --role "Storage Blob Data Contributor" --assignee $USER_ID \
  --scope $(az storage account show --name $CACHE_ACCOUNT --query id -o tsv)

az storage container create --name cache --account-name $CACHE_ACCOUNT --auth-mode login
```

Role assignments take a minute or two to propagate; if `az keyvault secret set` fails with a permission error, wait and retry.

## Deploy

```bash
cat > terraform.tfvars <<EOF
resource_group_name = "$RESOURCE_GROUP"
key_vault_name = "$KEY_VAULT"
cache_storage_account_name = "$CACHE_ACCOUNT"
EOF

terraform init
terraform plan
terraform apply
```

Print a signed URL for a placeholder image (see [signed](../signed/) for how signing works) and open it:

```bash
(
URL=$(terraform output -raw url)
KEY=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-keys --query value -o tsv)
SALT=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-salts --query value -o tsv)
IMG_PATH="/rs:fit:300:200/plain/https://picsum.photos/1200/800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

imgproxy Pro caches processed results in the cache container (`cache_storage_account`, Pro only), so repeated requests
are served faster. Request the URL printed above with `curl` and look for the `X-Imgproxy-Cache` response header:

```bash
curl -s -D- -o /dev/null "<url from above>" | grep -i x-imgproxy-cache
# A request for a new URL is processed and stored; repeating it returns "x-imgproxy-cache: Hit"
```

The processed results are stored in the cache container:

```bash
az storage blob list --account-name $CACHE_ACCOUNT --container-name cache --auth-mode login --query "[].name" -o tsv
```

To pull from your own private registry instead, set `repo` (image without tag); `pro = true` then only enables Pro
features and no longer selects the image.

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

Continue with [complete](../complete/).
