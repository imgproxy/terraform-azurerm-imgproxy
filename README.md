# imgproxy Terraform Module for Azure Container Apps

Terraform module to deploy [imgproxy](https://imgproxy.net/) on Azure Container Apps with optional Azure Front Door, OpenTelemetry-based monitoring and Azure Blob Storage integration.

## Features

The module creates the required resources:

- Container App, with a Container Apps Environment and Log Analytics workspace (or use your own environment)
- User-assigned managed identity (or use your own), with role assignments for Key Vault and Blob Storage
- Azure Front Door Standard (optional)
- OpenTelemetry collector sidecar with Application Insights for Azure Monitor (optional)

Also supported: request signing, imgproxy Pro through Key Vault secrets, Blob Storage as image source and result cache (Pro). Private by default ([details](#secure-defaults)).

## Usage

```hcl
module "imgproxy" {
  source  = "imgproxy/imgproxy/azurerm"
  version = "~> 0.1"

  resource_group_name = "imgproxy"
  location            = "germanywestcentral"
  service_name        = "imgproxy"

  # Reachable from the internet (the default is internal to the Container Apps Environment)
  allow_unauthenticated = true

  key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/imgproxy/providers/Microsoft.KeyVault/vaults/my-vault"
  keys_secret  = { id = "https://my-vault.vault.azure.net/secrets/imgproxy-keys" }
  salts_secret = { id = "https://my-vault.vault.azure.net/secrets/imgproxy-salts" }
}
```

Requires Terraform >= 1.5, an authenticated Azure CLI with [sufficient permissions](#permissions), and an existing resource group and Key Vault: the module creates neither.

## Examples

Start with [insecure](examples/insecure/) and follow the "Next" link at the end of each README; every step adds one feature.

- [insecure](examples/insecure/) - Minimal deployment without request signing (development only)
- [signed](examples/signed/) - Production setup with URL signing
- [blob](examples/blob/) - Private Blob Storage account as the image source
- [cdn](examples/cdn/) - Azure Front Door in front of the Container App
- [pro](examples/pro/) - imgproxy Pro with license key and Blob Storage result cache
- [complete](examples/complete/) - Full-featured deployment with Pro, monitoring, and Blob Storage

The examples set `allow_unauthenticated = true` so that you can open them in a browser. Testing only.

## Notes

### Secure defaults

Each insecure choice is an explicit, named opt-in:

| Default | Opt-in | Acceptable for |
|---------|--------|----------------|
| The app is reachable only inside the Container Apps Environment | `allow_unauthenticated = true` | Testing, or a public deployment that relies on request signing. With `enable_cdn = true` it is forced on, see [Azure Front Door](#azure-front-door) |
| Requests must be signed | `insecure = true` | Development: anyone can use your imgproxy, with unlimited bandwidth costs and no control over what it processes |

### Permissions

The deployer needs permissions to create Container Apps, managed identities, Log Analytics and Application Insights resources, and Front Door profiles in the resource group. Because the module creates role assignments, it also needs `Microsoft.Authorization/roleAssignments/write` on the Key Vault secrets and storage accounts it grants access to (for example `Role Based Access Control Administrator` or `User Access Administrator`). Use your own identity (`identity_id`, `identity_principal_id`, `identity_client_id`) to avoid creating one.

The module reads no secret values. Key Vault secrets are referenced by URI and resolved by the Container App at runtime.

### Key Vault access

The Key Vault must use Azure RBAC authorization. The managed identity is granted `Key Vault Secrets User` on each secret the module uses, not on the whole vault, so it cannot read other secrets in the vault. Pointing two environment variables at the same secret creates a duplicate role assignment. `key_vault_id` is required when any secret is configured.

Secret URIs follow the format `https://<vault>.vault.azure.net/secrets/<name>`, optionally followed by `/<version>` to pin a version. Without a version, the latest one is used.

### Additional secrets

`secrets` maps extra environment variables (named as in [imgproxy's configuration](https://docs.imgproxy.net/configuration)) to Key Vault secrets. `version` is optional (the latest version is used by default).

```hcl
secrets = {
  IMGPROXY_SENTRY_DSN = { id = "https://my-vault.vault.azure.net/secrets/sentry-dsn" }
}
```

Do not put sensitive values in `environment`: it becomes plain environment variables on the Container App.

### Image delivery

The Container App pulls `ghcr.io/imgproxy/imgproxy`, or `docker.imgproxy.pro/imgproxy` with `pro = true`, which requires `repo_password_secret` (a Key Vault secret holding the registry password; the username defaults to `imgproxy`). For your own image, set `repo` (without tag) and `tag` (a version, or a `sha256:` digest). A private registry also needs `repo_username` and `repo_password_secret`:

```hcl
repo          = "registry.example.com/imgproxy-custom"
tag           = "my-tag"
repo_username = "deploy"
repo_password_secret = {
  id = "https://my-vault.vault.azure.net/secrets/registry-password"
}
```

`pro = true` only selects the default `repo` and enables Pro features; it has no effect on the image when `repo` is set. For docker.imgproxy.pro only `repo_password_secret` is required (the username defaults to `imgproxy`). Without `repo_password_secret` a custom `repo` must be pullable without authentication. The identity is granted read access to the secret, and the registry server is the host of `repo`.

### Azure Blob Storage

The module grants roles on existing storage accounts and does not create them. `source_storage_accounts` grants `Storage Blob Data Reader`, enables the `abs://` URL scheme and sets `IMGPROXY_ABS_NAME` to the first account's name (imgproxy reads from one account at a time; override it in `environment` to pick another). URLs look like `abs://<container>/<blob>`.

`cache_storage_account` (Pro) grants `Storage Blob Data Contributor` and sets `IMGPROXY_CACHE_ABS_NAME`. Enable the cache through `environment`:

```hcl
environment = {
  IMGPROXY_CACHE_USE    = "abs"
  IMGPROXY_CACHE_BUCKET = "cache" # container name within the storage account
}
```

Roles are assigned on the whole account, so use accounts dedicated to imgproxy. The cache account cannot also be a source account, because its write access would let imgproxy overwrite source images. The Azure counterpart of an S3 or GCS bucket is a container.

### Scaling, monitoring and logs

- The Container App scales between `min_replicas` and `max_replicas`. `cpu` and `memory` must be a valid Container Apps combination.
- `enable_monitoring = true` adds an OpenTelemetry collector sidecar (OTLP on `localhost:4318`) exporting traces, metrics and logs to Application Insights. It reserves 0.25 CPU and 0.5Gi of memory; replace its configuration with `otel_collector_config`. The Application Insights connection string is stored as a Container App secret and also appears in Terraform state, so use an encrypted remote backend.
- `/health` is served on port 8080. Container logs go to the Log Analytics workspace `<service_name>-logs` (30 days). imgproxy logs request URLs, which include signatures and source URLs, so restrict access to the workspace.

### Azure Front Door

`enable_cdn = true` puts Azure Front Door Standard in front of the Container App, on its default `*.azurefd.net` hostname (the `cdn_endpoint_hostname` output) or on your domains through `cdn_domains`. For each domain, create a DNS CNAME record to `cdn_endpoint_hostname` and a `_dnsauth` TXT record with the value from `cdn_custom_domain_validation_tokens`; Front Door then provisions a managed TLS certificate.

The Container App must be reachable by Front Door, so its own URL (the `url` output) stays public and bypasses the cache. Signature checks still apply on both paths. The module does not restrict the origin by IP: the `AzureFrontDoor.Backend` service tag is shared by all Front Door tenants, so it would not isolate your profile. If you need a locked origin, consider a Premium Front Door with Private Link.

Cache keys follow your imgproxy configuration (`Accept` with format detection, client hints, `IMGPROXY_CACHE_KEY_HEADERS` and `IMGPROXY_CACHE_KEY_COOKIES`). `secret_secret` cannot be combined with Front Door, which does not forward `Authorization`. `cdn_redirect_http_to_https = false` allows plain HTTP, which exposes signed URLs.

### Vendored module

`modules/imgproxy-common` is a generated copy of the module of the same name in `imgproxy/terraform-common`. Do not edit it here: change it upstream and run `sync.sh` from that repository.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.5 |
| azurerm | ~> 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| azurerm | ~> 4.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| imgproxy\_common | ./modules/imgproxy-common | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [azurerm_application_insights.monitoring](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights) | resource |
| [azurerm_cdn_frontdoor_custom_domain.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_custom_domain) | resource |
| [azurerm_cdn_frontdoor_custom_domain_association.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_custom_domain_association) | resource |
| [azurerm_cdn_frontdoor_endpoint.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_endpoint) | resource |
| [azurerm_cdn_frontdoor_origin.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_origin) | resource |
| [azurerm_cdn_frontdoor_origin_group.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_origin_group) | resource |
| [azurerm_cdn_frontdoor_profile.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_profile) | resource |
| [azurerm_cdn_frontdoor_route.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_route) | resource |
| [azurerm_cdn_frontdoor_rule.cache_ttl](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_rule) | resource |
| [azurerm_cdn_frontdoor_rule_set.cache](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cdn_frontdoor_rule_set) | resource |
| [azurerm_container_app.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_app) | resource |
| [azurerm_container_app_environment.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_app_environment) | resource |
| [azurerm_log_analytics_workspace.main](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace) | resource |
| [azurerm_log_analytics_workspace.monitoring](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace) | resource |
| [azurerm_role_assignment.cache_storage](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.key_vault](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_role_assignment.source_storage](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_user_assigned_identity.imgproxy](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |

## Inputs

| Name | Description | Type | Required |
| ---- | ----------- | ---- | :------: |
| resource\_group\_name | Name of the Azure resource group where all resources will be created. | `string` | yes |
| allow\_unauthenticated | Allow public internet access to the Container App. Off by default: the app is reachable only from within the Container Apps Environment network. Set to true to expose it publicly (required to reach imgproxy directly from the internet without a CDN). Note: when enable\_cdn = true this is forced to true so Front Door can reach the origin, and the origin URL is then also directly reachable (signature checks still apply). | `bool` | no |
| cache\_storage\_account | Resource ID of an Azure Storage Account for imgproxy result cache (imgproxy Pro only). The managed identity will be granted Storage Blob Data Contributor. Sets IMGPROXY\_CACHE\_ABS\_NAME to the account name; also set IMGPROXY\_CACHE\_USE = "abs" and IMGPROXY\_CACHE\_BUCKET (container name) in environment. | `string` | no |
| cdn\_client\_ttl | Client (browser) TTL in seconds. Enforce via origin Cache-Control headers; not directly configurable in Front Door Standard. | `number` | no |
| cdn\_default\_ttl | Default cache TTL in seconds applied via Front Door rule set. | `number` | no |
| cdn\_domains | Custom domain hostnames to attach to the Front Door endpoint (e.g. ["cdn.example.com"]). Azure-managed TLS certificates are provisioned automatically. Optional: the default *.azurefd.net endpoint (cdn\_endpoint\_hostname) is always available over HTTPS. | `list(string)` | no |
| cdn\_max\_ttl | Maximum cache TTL in seconds. Informational in Front Door Standard; enforce via origin Cache-Control headers. | `number` | no |
| cdn\_negative\_caching | Informational only in Azure Front Door Standard — error response caching is not configurable at this tier. | `bool` | no |
| cdn\_redirect\_http\_to\_https | Redirect HTTP traffic to HTTPS at the Front Door level. | `bool` | no |
| container\_app\_environment\_id | Resource ID of an existing Container App Environment. When null, a new Consumption environment (with Log Analytics workspace) is created. | `string` | no |
| cpu | CPU cores for the container (e.g. 0.5, 1.0, 2.0). Must be a valid Container Apps CPU value. | `number` | no |
| enable\_cdn | Enable Azure Front Door Standard for CDN caching and global distribution. | `bool` | no |
| enable\_monitoring | Enable the OpenTelemetry collector sidecar and export traces, metrics, and logs to Azure Monitor by default. Automatically configures imgproxy OTEL environment variables. | `bool` | no |
| environment | Additional environment variables passed to imgproxy (e.g. IMGPROXY\_MAX\_SRC\_RESOLUTION). | `map(string)` | no |
| identity\_client\_id | Client (application) ID of the managed identity. Used to set AZURE\_CLIENT\_ID so imgproxy picks the correct identity for Azure Blob Storage access. Required when identity\_id is set and storage is configured. | `string` | no |
| identity\_id | Resource ID of an existing User Assigned Managed Identity. When null, a dedicated identity is created automatically. | `string` | no |
| identity\_principal\_id | Principal (object) ID of the managed identity. Required when identity\_id is set so that role assignments can be created. | `string` | no |
| insecure | Disable URL signature checks. When true, key and salt are not required. | `bool` | no |
| key\_vault\_id | Resource ID of the Azure Key Vault that holds imgproxy secrets. The managed identity will be granted Key Vault Secrets User on each secret the module uses (not on the whole vault). Required when any secrets are configured. | `string` | no |
| keys\_secret | Key Vault secret URI for imgproxy signing keys (comma-separated hex-encoded values). Required when insecure = false. Generate each key: openssl rand -hex 64. Sets IMGPROXY\_KEY (https://docs.imgproxy.net/configuration/options#IMGPROXY_KEY). | ```object({ id = string version = optional(string, "") })``` | no |
| location | Azure region for all resources (e.g. "eastus", "westeurope"). | `string` | no |
| max\_replicas | Maximum number of Container App replicas. | `number` | no |
| memory | Memory limit for the container (e.g. "1Gi", "2Gi"). Must match the CPU value per Container Apps requirements. | `string` | no |
| min\_replicas | Minimum number of Container App replicas (set to 1 to avoid cold starts). | `number` | no |
| otel\_collector\_config | OpenTelemetry collector config passed to the OTEL sidecar when monitoring is enabled. Supports collector environment variable expansion such as ${env:APPLICATIONINSIGHTS\_CONNECTION\_STRING}. | `string` | no |
| pro | Use imgproxy Pro (docker.imgproxy.pro) instead of the community image (ghcr.io). | `bool` | no |
| pro\_license\_key\_secret | Key Vault secret URI for the imgproxy Pro license key. Sets IMGPROXY\_LICENSE\_KEY (https://docs.imgproxy.net/configuration/options#IMGPROXY_LICENSE_KEY). | ```object({ id = string version = optional(string, "") })``` | no |
| repo | Custom container repository to use. When set, overrides the repository constructed from 'pro'. Combined with 'tag' to form the full image reference (e.g. 'myregistry.azurecr.io/imgproxy'). For a private registry set repo\_username and repo\_password\_secret. | `string` | no |
| repo\_password\_secret | Key Vault secret URI for the registry password (for docker.imgproxy.pro, or for 'repo' when set). Required when pro = true and repo is not set. The identity is granted read access to this secret. | ```object({ id = string version = optional(string, "") })``` | no |
| repo\_username | Username for the registry in 'repo'. Defaults to 'imgproxy' for docker.imgproxy.pro when 'repo' is not set. Required with repo\_password\_secret otherwise. | `string` | no |
| salts\_secret | Key Vault secret URI for imgproxy signing salts (comma-separated hex-encoded values). Must match the number of keys. Required when insecure = false. Sets IMGPROXY\_SALT (https://docs.imgproxy.net/configuration/options#IMGPROXY_SALT). | ```object({ id = string version = optional(string, "") })``` | no |
| secret\_secret | Key Vault secret URI for the authorization token. When set, requests must include Authorization: Bearer <token>. Sets IMGPROXY\_SECRET (https://docs.imgproxy.net/configuration/options#IMGPROXY_SECRET). | ```object({ id = string version = optional(string, "") })``` | no |
| secrets | Map of environment variable names to Key Vault secret URIs. Example: {IMGPROXY\_NEW\_RELIC\_KEY = { id = "https://vault.vault.azure.net/secrets/newrelic-key" }}. | ```map(object({ id = string version = optional(string, "") }))``` | no |
| service\_name | Prefix applied to every resource name. | `string` | no |
| signature\_size | Number of bytes from the key/salt used for signing. Sets IMGPROXY\_SIGNATURE\_SIZE (https://docs.imgproxy.net/configuration/options#IMGPROXY_SIGNATURE_SIZE). | `number` | no |
| source\_storage\_accounts | Resource IDs of Azure Storage Accounts containing source images. The managed identity will be granted Storage Blob Data Reader on each. When non-empty, enables IMGPROXY\_USE\_ABS (https://docs.imgproxy.net/configuration/options#IMGPROXY_USE_ABS) and sets IMGPROXY\_ABS\_NAME to the first account's name (imgproxy reads from a single account; override IMGPROXY\_ABS\_NAME in environment to pick another). | `list(string)` | no |
| source\_url\_encryption\_key\_secret | Key Vault secret URI for the source URL encryption key. Sets IMGPROXY\_SOURCE\_URL\_ENCRYPTION\_KEY (https://docs.imgproxy.net/configuration/options#IMGPROXY_SOURCE_URL_ENCRYPTION_KEY). | ```object({ id = string version = optional(string, "") })``` | no |
| subnet\_id | Resource ID of the subnet for Container App Environment VNet integration. Only used when container\_app\_environment\_id is null (a new environment is being created). | `string` | no |
| tag | imgproxy image tag (version). | `string` | no |
| tags | Azure resource tags applied to all created resources. | `map(string)` | no |
| timeout | Request timeout in seconds. Sets IMGPROXY\_TIMEOUT (https://docs.imgproxy.net/configuration/options#IMGPROXY_TIMEOUT). | `number` | no |
| trusted\_signatures\_secret | Key Vault secret URI for trusted signature prefixes. imgproxy Pro only. Sets IMGPROXY\_TRUSTED\_SIGNATURES (https://docs.imgproxy.net/configuration/options#IMGPROXY_TRUSTED_SIGNATURES). | ```object({ id = string version = optional(string, "") })``` | no |
| workers | Number of concurrent requests per replica. Sets IMGPROXY\_WORKERS (https://docs.imgproxy.net/configuration/options#IMGPROXY_WORKERS). Defaults to cpu × 2. | `number` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| cdn\_custom\_domain\_validation\_tokens | Map of domain → DNS TXT validation token required to activate managed TLS certificates for custom domains. |
| cdn\_endpoint\_hostname | Hostname of the Front Door endpoint. Create a CNAME record pointing your domain to this hostname. Null when CDN is disabled. |
| identity\_id | Resource ID of the User Assigned Managed Identity used by the Container App. |
| location | The Azure region where the Container App is deployed. |
| monitoring\_application\_insights\_id | Resource ID of the Application Insights resource receiving OTEL data. Null when monitoring is disabled. |
| monitoring\_workspace\_id | Resource ID of the Log Analytics workspace used by Azure Monitor for OTEL data. Null when monitoring is disabled. |
| name | The Container App name. |
| url | The HTTPS URL of the imgproxy Container App. |
<!-- END_TF_DOCS -->

## License

MIT
