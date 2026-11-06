# Azure Front Door CDN

Azure Front Door Standard caching processed images at edge locations. A custom domain is optional; this example runs
without one, over HTTPS on the default `*.azurefd.net` hostname (see below for adding a domain). It fetches public
placeholder images, so no storage account is needed.

## Azure setup

You need an Azure subscription and the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), authenticated:

```bash
az login
az account set --subscription YOUR_SUBSCRIPTION_ID
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

## Prerequisites

Create a resource group and a Key Vault with the signing keys (see [signed](../signed/)):

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
```

Front Door takes a few minutes to propagate. Print a signed URL for a placeholder image on the CDN hostname and
request it twice:

```bash
(
URL="https://$(terraform output -raw cdn_hostname)"
KEY=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-keys --query value -o tsv)
SALT=$(az keyvault secret show --vault-name $KEY_VAULT --name imgproxy-salts --query value -o tsv)
IMG_PATH="/rs:fit:300:300/plain/https://picsum.photos/1200/800.jpg"
SIG=$( (printf '%s' "$SALT" | xxd -r -p; printf '%s' "$IMG_PATH") \
  | openssl dgst -sha256 -mac HMAC -macopt hexkey:$KEY -binary \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=' )
echo "$URL/$SIG$IMG_PATH"
)

# Repeated requests for the same URL: the second response is served from the edge cache
curl -sI "<url from above>" | grep -i -E '^(HTTP|x-cache)'
# x-cache: TCP_MISS on the first request, TCP_HIT on the next
```

## Adding a domain

In [main.tf](main.tf), uncomment `cdn_domains` and set your domain. After `terraform apply`:

1. Create a DNS CNAME record from your domain to `terraform output cdn_hostname`.
2. Create a DNS TXT record `_dnsauth.<your domain>` with the value from `terraform output cdn_validation_tokens`.

Front Door then validates the domain and provisions the managed certificate, which can take up to an hour.

## Notes

- `cdn_redirect_http_to_https = true` (default) redirects HTTP to HTTPS at Front Door.
- `secret_secret` (Bearer auth) cannot be combined with the CDN: Front Door does not forward the `Authorization` header.
- Front Door Standard keys its cache by the request headers imgproxy varies on (such as `Accept` for format detection).
- The Container App stays reachable on its own `url` output; only the `*.azurefd.net` hostname is cached.

## Cleanup

```bash
terraform destroy
```

The resource group and the Key Vault were created with `az`, so delete them separately (and remove the DNS records if
you added a domain):

```bash
az group delete --name $RESOURCE_GROUP --yes
az keyvault purge --name $KEY_VAULT
```

## Next

Continue with [pro](../pro/).
