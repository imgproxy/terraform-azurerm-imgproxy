# imgproxy Terraform Module for Azure Container Apps

Terraform module to deploy [imgproxy](https://imgproxy.net/) on Azure Container Apps with optional Azure Front Door CDN, Azure Blob Storage integration, OpenTelemetry monitoring to Azure Monitor, and Key Vault secrets management.

## Features

- **Azure Container Apps deployment** with configurable CPU, memory, and scaling
- **Azure Front Door Standard CDN** for global caching and low-latency image delivery
- **imgproxy Pro support** with direct docker.imgproxy.pro registry authentication
- **Azure Blob Storage integration** for source images and result cache (Pro)
- **Request signing** with configurable keys and salts
- **Azure Key Vault integration** for all sensitive configuration via Managed Identity
- **User Assigned Managed Identity** with least-privilege role assignments
- **OpenTelemetry collector sidecar** for traces, metrics, and logs exported to Azure Monitor by default
- **VNet integration** support via Container App Environment subnet

## Prerequisites

- **An Azure account and subscription** — [Create a free account](https://azure.microsoft.com/free/) if needed
- **Azure CLI** — [Install](https://docs.microsoft.com/cli/azure/install-azure-cli) and authenticate:
  ```bash
  az login
  az account set --subscription "<your-subscription-id>"
  ```
- **Terraform** — [Install](https://developer.hashicorp.com/terraform/install) (version 1.5 or later)
- **A resource group** — Create one before deploying:
  ```bash
  az group create --name imgproxy-dev --location germanywestcentral
  ```
- **A provider(s)** - Register `Microsoft.App`:
  ```bash
  az provider register --namespace Microsoft.App --wait
  ```

  If you plan to use monitoring, register `Microsoft.Insights`:
  ```bash
  az provider register --namespace Microsoft.Insights --wait
  ```

## Getting Started

```bash
mkdir imgproxy-azure
cd imgproxy-azure
# create main.tf (see examples below)
terraform init
terraform plan
terraform apply
```

## Usage Examples

Examples are ordered from simplest to most advanced.

---

### 1. Development Setup (Insecure Mode)

**⚠️ WARNING:** This configuration disables request signing. **Never use in production.**

**Create `main.tf`:**
```hcl
module "imgproxy" {
  source = "github.com/imgproxy/terraform-azurerm-imgproxy"

  resource_group_name = "imgproxy-dev"
  location            = "germanywestcentral"
  allow_unauthenticated = true # testing opt-in: expose the app publicly (see Security)

  insecure = true
}

output "url" {
  value = module.imgproxy.url
}
```

**Deploy and test:**
```bash
terraform init && terraform apply

URL=$(terraform output -raw url)
curl "$URL/health"
curl -I "$URL/insecure/plain/https://picsum.photos/200"
```

---

### 2. Production Setup with URL Signing

**First, create signing keys in Key Vault:**

```bash
# Create Key Vault
az keyvault create --name imgproxy-dev-vault --resource-group imgproxy-dev --location germanywestcentral

# Grant yourself permissios
az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee $(az ad signed-in-user show --query id -o tsv) \
  --scope $(az keyvault show --name imgproxy-dev-vault --resource-group imgproxy-dev --query id -o tsv)

# Generate and store signing key + salt
az keyvault secret set \
  --vault-name imgproxy-dev-vault \
  --name imgproxy-key \
  --value "$(openssl rand -hex 64)"

az keyvault secret set \
  --vault-name imgproxy-dev-vault \
  --name imgproxy-salt \
  --value "$(openssl rand -hex 64)"

# Get the Key Vault resource ID for key_vault_id variable
az keyvault show --name imgproxy-dev-vault --query id -o tsv
```

**Create `main.tf`:**
```hcl
variable "key_vault_id" {
  type = string
}

module "imgproxy" {
  source = "github.com/imgproxy/terraform-azurerm-imgproxy"

  resource_group_name = "imgproxy-dev"
  location            = "germanywestcentral"
  allow_unauthenticated = true # testing opt-in: expose the app publicly (see Security)

  key_vault_id = var.key_vault_id

  keys_secret = {
    id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-key"
  }
  salts_secret = {
    id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-salt"
  }
}

output "url" {
  value = module.imgproxy.url
}
```

**Deploy:**
```bash
terraform apply -var key_vault_id="$(az keyvault show --name imgproxy-dev-vault --query id -o tsv)"
```

---

### 3. Azure Blob Storage Integration

**What you get:** imgproxy reads source images directly from private Azure Blob Storage using the `abs://` URL scheme. The managed identity is granted `Storage Blob Data Reader` automatically.

**Create `main.tf`:**
```hcl
variable "key_vault_id" { type = string }

resource "azurerm_storage_account" "images" {
  name                     = "myimgproxyimages"
  resource_group_name      = "imgproxy-dev"
}

module "imgproxy" {
  source = "github.com/imgproxy/terraform-azurerm-imgproxy"

  resource_group_name = "imgproxy-dev"
  location            = "germanywestcentral"
  allow_unauthenticated = true # testing opt-in: expose the app publicly (see Security)
  key_vault_id        = var.key_vault_id

  keys_secret  = { id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-key" }
  salts_secret = { id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-salt" }

  # Grant Storage Blob Data Reader and enable abs:// URL scheme
  source_storage_accounts = [azurerm_storage_account.images.id]
}
```

**Upload and process images:**
```bash
az storage blob upload \
  --account-name myimgproxyimages \
  --container-name photos \
  --name photo.jpg \
  --file ./photo.jpg

# Use abs://container/blob in imgproxy URLs (the storage account is set via IMGPROXY_ABS_NAME)
# (requires a signed URL — see https://docs.imgproxy.net/usage/signing_the_url)
```

---

### 4. imgproxy Pro with License Key

**Store Pro secrets in Key Vault:**
```bash
az keyvault secret set --vault-name imgproxy-dev-vault \
  --name imgproxy-pro-password --value "your-registry-password"

az keyvault secret set --vault-name imgproxy-dev-vault \
  --name imgproxy-pro-license --value "your-license-key"
```

**Create `main.tf`:**
```hcl
variable "key_vault_id" { type = string }

resource "azurerm_storage_account" "source" {
  name                     = "myimgproxysrc"
  resource_group_name      = "imgproxy-dev"
}

resource "azurerm_storage_account" "cache" {
  name                     = "myimgproxycache"
  resource_group_name      = "imgproxy-dev"
}

module "imgproxy" {
  source = "github.com/imgproxy/terraform-azurerm-imgproxy"

  resource_group_name = "imgproxy-dev"
  location            = "germanywestcentral"
  allow_unauthenticated = true # testing opt-in: expose the app publicly (see Security)
  tag                 = "v4"
  key_vault_id        = var.key_vault_id

  # Enable Pro edition
  pro = true
  pro_registry_password_secret = {
    id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-pro-password"
  }
  pro_license_key_secret = {
    id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-pro-license"
  }

  # Request signing
  keys_secret  = { id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-key" }
  salts_secret = { id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-salt" }

  # Storage: source images + result cache (Pro feature)
  source_storage_accounts = [azurerm_storage_account.source.id]
  cache_storage_account   = azurerm_storage_account.cache.id

  environment = {
    IMGPROXY_CACHE_USE    = "abs"
    IMGPROXY_CACHE_BUCKET = "imgproxy-cache" # container name within the storage account
  }
}

output "url" {
  value = module.imgproxy.url
}
```

---

### 5. Custom Image Override

Use any registry instead of the defaults (`ghcr.io` for community, `docker.imgproxy.pro` for Pro):

```hcl
module "imgproxy" {
  source = "github.com/imgproxy/terraform-azurerm-imgproxy"

  resource_group_name = "imgproxy-dev"
  location            = "germanywestcentral"
  allow_unauthenticated = true # testing opt-in: expose the app publicly (see Security)

  # Pull from your own Azure Container Registry
  repo = "myregistry.azurecr.io/imgproxy"
  tag  = "v4"

  key_vault_id = var.key_vault_id
  keys_secret  = { id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-key" }
  salts_secret = { id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-salt" }
}
```

When `repo` is set, the module skips configuring registry credentials — your ACR must already be accessible from the Container App (use a system-assigned identity or an attached ACR integration at the environment level).

---

### 6. Azure Front Door CDN for Global Low-Latency Access

**What you get:** Azure Front Door Standard profiles your Container App as an origin, caches processed images at global PoPs, and provisions managed TLS certificates for your custom domains.

**Important:** You need a domain name. DNS validation is required for managed certificates.

**Create `main.tf`:**
```hcl
variable "key_vault_id" { type = string }

module "imgproxy" {
  source = "github.com/imgproxy/terraform-azurerm-imgproxy"

  resource_group_name = "imgproxy-dev"
  location            = "germanywestcentral"
  key_vault_id        = var.key_vault_id

  keys_secret  = { id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-key" }
  salts_secret = { id = "https://imgproxy-dev-vault.vault.azure.net/secrets/imgproxy-salt" }

  enable_cdn  = true
  cdn_domains = ["cdn.example.com"]

  cdn_default_ttl            = 3600    # 1 hour cache
  cdn_redirect_http_to_https = true
}

output "cdn_endpoint" {
  value       = module.imgproxy.cdn_endpoint_hostname
  description = "Create a CNAME record pointing cdn.example.com → this hostname"
}

output "validation_tokens" {
  value       = module.imgproxy.cdn_custom_domain_validation_tokens
  description = "Add these as DNS TXT records to validate managed certificates"
}
```

**Configure DNS:**
```bash
terraform apply

# 1. Create a CNAME:
#    cdn.example.com  CNAME  <cdn_endpoint hostname>

# 2. Add the TXT validation record shown in validation_tokens output.
#    Front Door auto-provisions the managed TLS certificate once validated.
```

**Note:** Unlike GCP Cloud CDN, Azure Front Door uses a CNAME target (not a static IP). The Container App origin remains public so Front Door can reach it — restrict origin access at the application level if needed.

---

### 7. Additional Secrets

Pass any extra Key Vault secrets as environment variables for third-party integrations:

```hcl
az keyvault secret set --vault-name imgproxy-dev-vault \
  --name newrelic-license --value "your-newrelic-license"

module "imgproxy" {
  source = "github.com/imgproxy/terraform-azurerm-imgproxy"
  # ... core config ...

  secrets = {
    IMGPROXY_NEW_RELIC_KEY = {
      id = "https://imgproxy-dev-vault.vault.azure.net/secrets/newrelic-license"
    }
    IMGPROXY_SENTRY_DSN = {
      id      = "https://imgproxy-dev-vault.vault.azure.net/secrets/sentry-dsn"
      version = "abc123def456"  # pin to a specific version
    }
  }
}
```

---

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5 |
| azurerm | ~> 4.0 |

## Providers

| Name | Version |
|------|---------|
| azurerm | ~> 4.0 |

## Inputs

### Core Configuration

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| resource_group_name | Azure resource group name | `string` | n/a | yes |
| location | Azure region (e.g. `"germanywestcentral"`, `"westeurope"`) | `string` | `"germanywestcentral"` | no |
| service_name | Prefix applied to every resource name | `string` | `"imgproxy"` | no |
| tag | imgproxy image tag or digest (e.g. `v4`, `sha256:...`) | `string` | `"v4"` | no |
| repo | Custom container repository, overrides the default | `string` | `null` | no |
| pro | Use imgproxy Pro instead of community image | `bool` | `false` | no |
| environment | Additional environment variables for imgproxy | `map(string)` | `{}` | no |
| secrets | Map of env var names to Key Vault secret objects | `map(object({ id, version }))` | `{}` | no |
| tags | Azure resource tags applied to all resources | `map(string)` | `{}` | no |

### Security & Signing

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| key_vault_id | Resource ID of the Azure Key Vault holding secrets. Grants `Key Vault Secrets User` to the managed identity, scoped to each secret the module uses (not the whole vault). | `string` | `null` | yes (if secrets used) |
| insecure | Disable URL signature checks (development only) | `bool` | `false` | no |
| keys_secret | Key Vault secret URI for signing keys ([`IMGPROXY_KEY`](https://docs.imgproxy.net/configuration/options#IMGPROXY_KEY)) | `object({ id, version? })` | `null` | yes (unless insecure) |
| salts_secret | Key Vault secret URI for signing salts ([`IMGPROXY_SALT`](https://docs.imgproxy.net/configuration/options#IMGPROXY_SALT)) | `object({ id, version? })` | `null` | yes (unless insecure) |
| signature_size | Number of bytes from key/salt used for signing ([`IMGPROXY_SIGNATURE_SIZE`](https://docs.imgproxy.net/configuration/options#IMGPROXY_SIGNATURE_SIZE)) | `number` | `32` | no |
| secret_secret | Key Vault secret URI for authorization token ([`IMGPROXY_SECRET`](https://docs.imgproxy.net/configuration/options#IMGPROXY_SECRET)) | `object({ id, version? })` | `null` | no |
| trusted_signatures_secret | Key Vault secret URI for trusted signature prefixes ([`IMGPROXY_TRUSTED_SIGNATURES`](https://docs.imgproxy.net/configuration/options#IMGPROXY_TRUSTED_SIGNATURES)) (Pro only) | `object({ id, version? })` | `null` | no |
| source_url_encryption_key_secret | Key Vault secret URI for source URL encryption key ([`IMGPROXY_SOURCE_URL_ENCRYPTION_KEY`](https://docs.imgproxy.net/configuration/options#IMGPROXY_SOURCE_URL_ENCRYPTION_KEY)) | `object({ id, version? })` | `null` | no |

### imgproxy Pro Configuration

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| pro_registry_password_secret | Key Vault secret URI for docker.imgproxy.pro registry password | `object({ id, version? })` | `null` | yes (if pro = true) |
| pro_license_key_secret | Key Vault secret URI for Pro license key ([`IMGPROXY_LICENSE_KEY`](https://docs.imgproxy.net/configuration/options#IMGPROXY_LICENSE_KEY)) | `object({ id, version? })` | `null` | no |

### Observability

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| enable_monitoring | Enable the OpenTelemetry collector sidecar and export traces, metrics, and logs to Azure Monitor by default. Automatically configures imgproxy OTEL environment variables. | `bool` | `false` | no |
| otel_collector_config | OpenTelemetry collector config passed to the OTEL sidecar when monitoring is enabled. Supports collector environment variable expansion such as `$${env:APPLICATIONINSIGHTS_CONNECTION_STRING}`. | `string` | built-in OTLP to Azure Monitor config | no |

### Storage Integration

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| source_storage_accounts | Resource IDs of Azure Storage Accounts for source images. Grants `Storage Blob Data Reader`. Enables [`IMGPROXY_USE_ABS`](https://docs.imgproxy.net/configuration/options#IMGPROXY_USE_ABS). Sets `AZURE_CLIENT_ID` for identity disambiguation. | `list(string)` | `[]` | no |
| cache_storage_account | Resource ID of an Azure Storage Account for result cache (Pro only). Grants `Storage Blob Data Contributor`. Must not also be listed in `source_storage_accounts`. | `string` | `null` | no |

### Compute Resources

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| cpu | CPU cores for the container (valid Container Apps values: 0.25–4.0) | `number` | `1.0` | no |
| memory | Memory limit, must pair with cpu (e.g. `"2Gi"` for 1 CPU) | `string` | `"2Gi"` | no |
| workers | Concurrent requests per replica ([`IMGPROXY_WORKERS`](https://docs.imgproxy.net/configuration/options#IMGPROXY_WORKERS)). Defaults to `cpu × 2`. | `number` | `null` | no |
| timeout | Request timeout in seconds ([`IMGPROXY_TIMEOUT`](https://docs.imgproxy.net/configuration/options#IMGPROXY_TIMEOUT)) | `number` | `null` | no |

### Scaling & Networking

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| min_replicas | Minimum number of Container App replicas | `number` | `1` | no |
| max_replicas | Maximum number of Container App replicas | `number` | `10` | no |
| allow_unauthenticated | Allow public internet access. When `false` (default), app is internal-only within the Container App Environment. Forced to `true` when `enable_cdn = true`. | `bool` | `false` | no |
| subnet_id | Subnet resource ID for Container App Environment VNet integration (used only when a new environment is created) | `string` | `null` | no |

### Azure Front Door (CDN)

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| enable_cdn | Enable Azure Front Door Standard | `bool` | `false` | no |
| cdn_domains | Custom domain hostnames for the Front Door endpoint. Optional: the default `*.azurefd.net` hostname always works | `list(string)` | `[]` | no |
| cdn_default_ttl | Cache TTL in seconds applied via Front Door rule set. Set to `0` to let the origin `Cache-Control` header control caching | `number` | `2628000` | no |
| cdn_max_ttl | Maximum TTL (advisory — enforce via origin `Cache-Control`) | `number` | `31556926` | no |
| cdn_client_ttl | Client TTL (advisory — enforce via origin `Cache-Control`) | `number` | `3600` | no |
| cdn_negative_caching | Informational only — error response caching is not configurable in Front Door Standard | `bool` | `true` | no |
| cdn_redirect_http_to_https | Redirect HTTP to HTTPS at Front Door level | `bool` | `true` | no |

### Infrastructure

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| container_app_environment_id | Resource ID of an existing Container App Environment. When null, a Consumption environment and Log Analytics workspace are created. | `string` | `null` | no |
| identity_id | Resource ID of an existing User Assigned Managed Identity. When null, a dedicated identity is created. | `string` | `null` | no |
| identity_principal_id | Principal ID of the existing identity. Required when `identity_id` is set. | `string` | `null` | no |
| identity_client_id | Client ID of the existing identity. Required when `identity_id` is set and storage is configured. | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| url | HTTPS URL of the imgproxy Container App |
| name | Container App name |
| identity_id | Resource ID of the User Assigned Managed Identity |
| location | Azure region of the deployment |
| cdn_endpoint_hostname | Front Door endpoint hostname — create a CNAME to this (when CDN enabled) |
| cdn_custom_domain_validation_tokens | Map of `domain → TXT validation token` for managed TLS certificate provisioning |
| monitoring_workspace_id | Resource ID of the Log Analytics workspace used by Azure Monitor for OTEL data |
| monitoring_application_insights_id | Resource ID of the Application Insights resource receiving OTEL data |

## Architecture

### Secrets

All secrets are stored in Azure Key Vault and injected at runtime via Container Apps' native Key Vault reference feature. The module creates a User Assigned Managed Identity and grants it `Key Vault Secrets User` on each secret the module uses (one role assignment per secret, so the identity cannot read other secrets in the vault; pointing two environment variables at the same secret would create a duplicate assignment). Key Vault secret values never appear in Terraform state.

Key Vault secret URIs follow the format:
- Latest version: `https://<vault>.vault.azure.net/secrets/<name>`
- Pinned version: `https://<vault>.vault.azure.net/secrets/<name>/<version-guid>`

### Azure Blob Storage

When `source_storage_accounts` is non-empty:
- `IMGPROXY_USE_ABS=true` enables the `abs://` URL scheme
- `AZURE_CLIENT_ID` is set to the managed identity's client ID so the Azure SDK selects the correct identity
- `IMGPROXY_ABS_NAME` is set to the first account's name (override it in `environment` to pick another)
- Use `abs://container/blob.jpg` in imgproxy URLs

### Container App Environment

When `container_app_environment_id` is null (default), the module creates:
- A Log Analytics workspace (`<name>-logs`)
- A Consumption plan Container App Environment (`<name>-env`)

Provide `container_app_environment_id` to share an existing environment across multiple deployments.

### Monitoring

When `enable_monitoring = true`, the module creates:
- An OpenTelemetry collector sidecar in the Container App
- A workspace-based Application Insights resource
- A Log Analytics workspace for monitoring when reusing an existing Container App Environment, or it reuses the module-managed workspace when creating a new environment

imgproxy is configured automatically to emit OTLP data to `http://localhost:4318` using the sidecar.

The default collector configuration exports traces, metrics, and logs to Azure Monitor. Override `otel_collector_config` if you need custom processors or additional exporters.

### CDN (Azure Front Door Standard)

When `enable_cdn = true`, the module creates:
- A Front Door Standard profile
- A Front Door endpoint (your CNAME target)
- An origin group with health probes against `/health`
- An origin pointing to the Container App's ingress FQDN
- A rule set with cache TTL override
- Custom domains with Azure-managed TLS certificates (one per entry in `cdn_domains`)

The Container App remains internet-accessible so Front Door can reach it. For additional origin protection, configure IP restrictions or use Private Link (requires Front Door Premium).

### Health Check

```bash
curl https://<your-container-app-fqdn>/health
# imgproxy is running
```

## Security

- **Private by default.** `allow_unauthenticated = false` keeps the app reachable only inside the Container Apps Environment. Set it to `true` to expose imgproxy to the internet. The examples do this as a testing opt-in.
- **Request signing.** Leave `insecure = false` in production. Insecure mode lets anyone use your imgproxy: unlimited bandwidth costs and no control over what it processes.
- **CDN origin is public.** With `enable_cdn = true` the Container App must be reachable by Front Door, so its own URL (the `url` output) is also directly reachable and bypasses the cache. Signature checks still apply on both paths. The module does not restrict the origin by IP: the `AzureFrontDoor.Backend` service tag is shared by all Front Door tenants, so it would not isolate your profile, and its size may exceed what Container Apps accepts as ingress IP rules. Use signing, and consider `ip_security_restriction` or a Premium Front Door with Private Link if you need a locked origin.
- **Least privilege.** Key Vault access is granted per secret. Storage access is granted on the whole account (Reader for sources, Contributor for the cache): use dedicated storage accounts for imgproxy, and note that the Azure counterpart of an S3/GCS bucket is a container.
- **Secrets.** Pass sensitive values through the `*_secret` / `secrets` inputs (Key Vault), not `environment`, which is stored as plain environment variables. With monitoring enabled, the Application Insights connection string is stored as a Container App secret and also appears in Terraform state: use an encrypted remote backend.

## Examples

Start with [insecure](examples/insecure/) and follow the "Next" link at the end of each README; every step adds one feature.

- [insecure](examples/insecure/) - Minimal deployment without request signing (development only)
- [signed](examples/signed/) - Production setup with URL signing
- [blob](examples/blob/) - Private Blob Storage account as the image source
- [cdn](examples/cdn/) - Azure Front Door CDN
- [pro](examples/pro/) - imgproxy Pro with license key and Blob Storage result cache
- [complete](examples/complete/) - Full-featured deployment with Pro, monitoring, and Blob Storage

## License

MIT

## Support

For imgproxy configuration questions, see the [official documentation](https://docs.imgproxy.net/).

For Terraform module issues, please open a GitHub issue.
