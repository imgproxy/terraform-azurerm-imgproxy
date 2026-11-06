# ── Basic Configuration ───────────────────────────────────────────────────────

variable "resource_group_name" {
  type        = string
  description = "Name of the Azure resource group where all resources will be created."
}

variable "location" {
  type        = string
  default     = "germanywestcentral"
  description = "Azure region for all resources (e.g. \"eastus\", \"westeurope\")."
}

variable "service_name" {
  type        = string
  default     = "imgproxy"
  description = "Prefix applied to every resource name."
}

variable "tag" {
  type        = string
  default     = "v4"
  description = "imgproxy image tag (version)."
}

variable "repo" {
  type        = string
  default     = null
  description = "Custom container repository to use. When set, overrides the repository constructed from 'pro'. Combined with 'tag' to form the full image reference (e.g. 'myregistry.azurecr.io/imgproxy')."
}

variable "environment" {
  type        = map(string)
  default     = {}
  description = "Additional environment variables passed to imgproxy (e.g. IMGPROXY_MAX_SRC_RESOLUTION)."
}

variable "secrets" {
  type = map(object({
    id      = string
    version = optional(string, "")
  }))
  default     = {}
  description = "Map of environment variable names to Key Vault secret URIs. Example: {IMGPROXY_NEW_RELIC_KEY = { id = \"https://vault.vault.azure.net/secrets/newrelic-key\" }}."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Azure resource tags applied to all created resources."
}

# ── Security & Signing ────────────────────────────────────────────────────────

variable "keys_secret" {
  type = object({
    id      = string
    version = optional(string, "")
  })
  default     = null
  description = "Key Vault secret URI for imgproxy signing keys (comma-separated hex-encoded values). Required when insecure = false. Generate each key: openssl rand -hex 64. Sets IMGPROXY_KEY (https://docs.imgproxy.net/configuration/options#IMGPROXY_KEY)."
}

variable "salts_secret" {
  type = object({
    id      = string
    version = optional(string, "")
  })
  default     = null
  description = "Key Vault secret URI for imgproxy signing salts (comma-separated hex-encoded values). Must match the number of keys. Required when insecure = false. Sets IMGPROXY_SALT (https://docs.imgproxy.net/configuration/options#IMGPROXY_SALT)."
}

variable "insecure" {
  type        = bool
  default     = false
  description = "Disable URL signature checks. When true, key and salt are not required."
}

variable "secret_secret" {
  type = object({
    id      = string
    version = optional(string, "")
  })
  default     = null
  description = "Key Vault secret URI for the authorization token. When set, requests must include Authorization: Bearer <token>. Sets IMGPROXY_SECRET (https://docs.imgproxy.net/configuration/options#IMGPROXY_SECRET)."
}

variable "signature_size" {
  type        = number
  default     = 32
  description = "Number of bytes from the key/salt used for signing. Sets IMGPROXY_SIGNATURE_SIZE (https://docs.imgproxy.net/configuration/options#IMGPROXY_SIGNATURE_SIZE)."
}

variable "trusted_signatures_secret" {
  type = object({
    id      = string
    version = optional(string, "")
  })
  default     = null
  description = "Key Vault secret URI for trusted signature prefixes. imgproxy Pro only. Sets IMGPROXY_TRUSTED_SIGNATURES (https://docs.imgproxy.net/configuration/options#IMGPROXY_TRUSTED_SIGNATURES)."
}

variable "source_url_encryption_key_secret" {
  type = object({
    id      = string
    version = optional(string, "")
  })
  default     = null
  description = "Key Vault secret URI for the source URL encryption key. Sets IMGPROXY_SOURCE_URL_ENCRYPTION_KEY (https://docs.imgproxy.net/configuration/options#IMGPROXY_SOURCE_URL_ENCRYPTION_KEY)."
}

# ── Key Vault ─────────────────────────────────────────────────────────────────

variable "key_vault_id" {
  type        = string
  default     = null
  description = "Resource ID of the Azure Key Vault that holds imgproxy secrets. The managed identity will be granted Key Vault Secrets User on this vault. Required when any secrets are configured."
}

# ── Compute Resources ─────────────────────────────────────────────────────────

variable "cpu" {
  type        = number
  default     = 1.0
  description = "CPU cores for the container (e.g. 0.5, 1.0, 2.0). Must be a valid Container Apps CPU value."
}

variable "memory" {
  type        = string
  default     = "2Gi"
  description = "Memory limit for the container (e.g. \"1Gi\", \"2Gi\"). Must match the CPU value per Container Apps requirements."
}

variable "workers" {
  type        = number
  default     = null
  description = "Number of concurrent requests per replica. Sets IMGPROXY_WORKERS (https://docs.imgproxy.net/configuration/options#IMGPROXY_WORKERS). Defaults to cpu × 2."
}

variable "timeout" {
  type        = number
  default     = null
  description = "Request timeout in seconds. Sets IMGPROXY_TIMEOUT (https://docs.imgproxy.net/configuration/options#IMGPROXY_TIMEOUT)."
}

# ── Storage Integration ───────────────────────────────────────────────────────

variable "source_storage_accounts" {
  type        = list(string)
  default     = []
  description = "Resource IDs of Azure Storage Accounts containing source images. The managed identity will be granted Storage Blob Data Reader on each. When non-empty, enables IMGPROXY_USE_ABS (https://docs.imgproxy.net/configuration/options#IMGPROXY_USE_ABS) and sets IMGPROXY_ABS_NAME to the first account's name (imgproxy reads from a single account; override IMGPROXY_ABS_NAME in environment to pick another)."
}

variable "cache_storage_account" {
  type        = string
  default     = null
  description = "Resource ID of an Azure Storage Account for imgproxy result cache (imgproxy Pro only). The managed identity will be granted Storage Blob Data Contributor. Sets IMGPROXY_CACHE_ABS_NAME to the account name; also set IMGPROXY_CACHE_USE = \"abs\" and IMGPROXY_CACHE_BUCKET (container name) in environment."
}

# ── Scaling ───────────────────────────────────────────────────────────────────

variable "min_replicas" {
  type        = number
  default     = 1
  description = "Minimum number of Container App replicas (set to 1 to avoid cold starts)."
}

variable "max_replicas" {
  type        = number
  default     = 10
  description = "Maximum number of Container App replicas."
}

# ── imgproxy Pro ──────────────────────────────────────────────────────────────

variable "pro" {
  type        = bool
  default     = false
  description = "Use imgproxy Pro (docker.imgproxy.pro) instead of the community image (ghcr.io)."
}

variable "pro_registry_password_secret" {
  type = object({
    id      = string
    version = optional(string, "")
  })
  default     = null
  description = "Key Vault secret URI for the docker.imgproxy.pro registry password. Required when pro = true and repo = null."
}

variable "pro_license_key_secret" {
  type = object({
    id      = string
    version = optional(string, "")
  })
  default     = null
  description = "Key Vault secret URI for the imgproxy Pro license key. Sets IMGPROXY_LICENSE_KEY (https://docs.imgproxy.net/configuration/options#IMGPROXY_LICENSE_KEY)."
}

# ── Observability ─────────────────────────────────────────────────────────────

variable "enable_monitoring" {
  type        = bool
  default     = false
  description = "Enable the OpenTelemetry collector sidecar and export traces, metrics, and logs to Azure Monitor by default. Automatically configures imgproxy OTEL environment variables."
}

variable "otel_collector_config" {
  type        = string
  default     = <<-EOT
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 0.0.0.0:4318
          grpc:
            endpoint: 0.0.0.0:4317

    processors:
      batch:

    exporters:
      azure_monitor:
        connection_string: $${env:APPLICATIONINSIGHTS_CONNECTION_STRING}

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [azure_monitor]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [azure_monitor]
        logs:
          receivers: [otlp]
          processors: [batch]
          exporters: [azure_monitor]
  EOT
  description = "OpenTelemetry collector config passed to the OTEL sidecar when monitoring is enabled. Supports collector environment variable expansion such as $${env:APPLICATIONINSIGHTS_CONNECTION_STRING}."
}

# ── Networking ────────────────────────────────────────────────────────────────

variable "allow_unauthenticated" {
  type        = bool
  default     = false
  description = "Allow public internet access to the Container App. Off by default: the app is reachable only from within the Container Apps Environment network. Set to true to expose it publicly (required to reach imgproxy directly from the internet without a CDN). Note: when enable_cdn = true this is forced to true so Front Door can reach the origin, and the origin URL is then also directly reachable (signature checks still apply)."
}

variable "subnet_id" {
  type        = string
  default     = null
  description = "Resource ID of the subnet for Container App Environment VNet integration. Only used when container_app_environment_id is null (a new environment is being created)."
}

# ── Azure Front Door (CDN) ────────────────────────────────────────────────────

variable "enable_cdn" {
  type        = bool
  default     = false
  description = "Enable Azure Front Door Standard for CDN caching and global distribution."
}

variable "cdn_domains" {
  type        = list(string)
  default     = []
  description = "Custom domain hostnames to attach to the Front Door endpoint (e.g. [\"cdn.example.com\"]). Azure-managed TLS certificates are provisioned automatically. Optional: the default *.azurefd.net endpoint (cdn_endpoint_hostname) is always available over HTTPS."
}

variable "cdn_default_ttl" {
  type        = number
  default     = 2628000
  description = "Default cache TTL in seconds applied via Front Door rule set."
}

variable "cdn_max_ttl" {
  type        = number
  default     = 31556926
  description = "Maximum cache TTL in seconds. Informational in Front Door Standard; enforce via origin Cache-Control headers."
}

variable "cdn_client_ttl" {
  type        = number
  default     = 3600
  description = "Client (browser) TTL in seconds. Enforce via origin Cache-Control headers; not directly configurable in Front Door Standard."
}

variable "cdn_negative_caching" {
  type        = bool
  default     = true
  description = "Informational only in Azure Front Door Standard — error response caching is not configurable at this tier."
}

variable "cdn_redirect_http_to_https" {
  type        = bool
  default     = true
  description = "Redirect HTTP traffic to HTTPS at the Front Door level."
}

# ── Infrastructure ────────────────────────────────────────────────────────────

variable "container_app_environment_id" {
  type        = string
  default     = null
  description = "Resource ID of an existing Container App Environment. When null, a new Consumption environment (with Log Analytics workspace) is created."
}

variable "identity_id" {
  type        = string
  default     = null
  description = "Resource ID of an existing User Assigned Managed Identity. When null, a dedicated identity is created automatically."
}

variable "identity_principal_id" {
  type        = string
  default     = null
  description = "Principal (object) ID of the managed identity. Required when identity_id is set so that role assignments can be created."
}

variable "identity_client_id" {
  type        = string
  default     = null
  description = "Client (application) ID of the managed identity. Used to set AZURE_CLIENT_ID so imgproxy picks the correct identity for Azure Blob Storage access. Required when identity_id is set and storage is configured."
}
