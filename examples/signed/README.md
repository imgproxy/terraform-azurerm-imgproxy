# Signed URLs

Production imgproxy with request signing, so only URLs signed with your key and salt are processed.

## Azure setup

You need an Azure subscription and the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), authenticated:

```bash
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

## Prerequisites

Create a resource group and a Key Vault, then store the signing keys in it:

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
```

Role assignments take a minute or two to propagate; if `az keyvault secret set` fails with a permission error, wait and retry.

## Deploy

```bash
cat > terraform.tfvars <<EOF
resource_group_name = "$RESOURCE_GROUP"
key_vault_name = "$KEY_VAULT"
EOF

terraform init
terraform plan
terraform apply

# Unsigned requests are rejected
curl -I "$(terraform output -raw url)/insecure/plain/https://picsum.photos/200"   # 403 Forbidden
```

Print a signed URL (paste it into a browser):

```bash
(
URL=$(terraform output -raw url)
KEY=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-keys --query value -o tsv)
SALT=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-salts --query value -o tsv)
IMG_PATH="/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)
```

This assumes a single key/salt pair. See [imgproxy's signing algorithm](https://docs.imgproxy.net/usage/signing_the_url) for details.

## Cleanup

```bash
terraform destroy
```

The resource group and the Key Vault were created with `az`, so delete them separately (a deleted vault stays in a
soft-deleted state and keeps its name reserved until purged):

```bash
az group delete --name $RESOURCE_GROUP --yes
az keyvault purge --name $KEY_VAULT
```

## Next

Continue with [blob](../blob/).
