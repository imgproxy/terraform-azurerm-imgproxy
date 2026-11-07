terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

variable "resource_group_name" {
  description = "Existing resource group (see README)"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "germanywestcentral"
}

variable "key_vault_name" {
  description = "Existing Key Vault that holds the imgproxy secrets (see README)"
  type        = string
}

data "azurerm_key_vault" "main" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

locals {
  # Versionless secret URIs: the container app always reads the latest version
  secrets_uri = "${data.azurerm_key_vault.main.vault_uri}secrets"
}

variable "source_storage_account_name" {
  description = "Existing storage account that holds the source images (see README)"
  type        = string
}

data "azurerm_storage_account" "source" {
  name                = var.source_storage_account_name
  resource_group_name = var.resource_group_name
}

variable "cache_storage_account_name" {
  description = "Existing storage account for the processed-result cache (see README)"
  type        = string
}

data "azurerm_storage_account" "cache" {
  name                = var.cache_storage_account_name
  resource_group_name = var.resource_group_name
}

# The subscription is taken from ARM_SUBSCRIPTION_ID (see README)
provider "azurerm" {
  features {}
}

module "imgproxy" {
  source  = "imgproxy/imgproxy/azurerm"
  version = "~> 0.1"

  resource_group_name = var.resource_group_name
  location            = var.location
  service_name        = "imgproxy"
  tag                 = "v4"
  tags = {
    app  = "imgproxy"
    team = "platform"
  }

  # Security: request signing
  key_vault_id = data.azurerm_key_vault.main.id
  keys_secret = {
    id = "${local.secrets_uri}/imgproxy-keys"
  }
  salts_secret = {
    id = "${local.secrets_uri}/imgproxy-salts"
  }
  signature_size = 32

  # Optional: Bearer token auth (cannot be used with enable_cdn = true)
  # secret_secret = {
  #   id = "${local.secrets_uri}/imgproxy-secret"
  # }

  # Optional: source URL encryption
  # source_url_encryption_key_secret = {
  #   id = "${local.secrets_uri}/imgproxy-source-url-key"
  # }

  # imgproxy Pro
  pro = true
  pro_license_key_secret = {
    id = "${local.secrets_uri}/imgproxy-pro-license"
  }
  repo_password_secret = {
    id = "${local.secrets_uri}/imgproxy-pro-password"
  }

  # Optional: pull from your own registry instead (pro then no longer affects the image)
  # repo = "registry.example.com/imgproxy-custom"

  # Optional: trusted signatures (Pro only)
  # trusted_signatures_secret = {
  #   id = "${local.secrets_uri}/imgproxy-trusted-sigs"
  # }

  # Optional: additional secrets for third-party integrations
  # secrets = {
  #   IMGPROXY_NEW_RELIC_KEY = { id = "${local.secrets_uri}/newrelic-license" }
  #   IMGPROXY_SENTRY_DSN    = { id = "${local.secrets_uri}/sentry-dsn", version = "3" }
  # }

  # Existing storage accounts (see README): source images and result cache (Pro)
  source_storage_accounts = [data.azurerm_storage_account.source.id]
  cache_storage_account   = data.azurerm_storage_account.cache.id

  # Monitoring (OpenTelemetry collector sidecar exporting to Azure Monitor)
  enable_monitoring = true

  # Compute resources
  cpu     = 2.0
  memory  = "4Gi"
  workers = 4
  timeout = 60

  # Scaling
  min_replicas = 2
  max_replicas = 20

  # Access control
  allow_unauthenticated = true

  # Optional: Azure Front Door CDN
  # enable_cdn                 = true
  # cdn_domains                = ["cdn.example.com"]
  # cdn_default_ttl            = 3600
  # cdn_redirect_http_to_https = true

  # Additional imgproxy configuration
  environment = {
    IMGPROXY_MAX_SRC_RESOLUTION = "50.0"
    IMGPROXY_JPEG_PROGRESSIVE   = "true"
    IMGPROXY_CACHE_USE          = "abs"
    IMGPROXY_CACHE_BUCKET       = "cache"
  }
}

output "url" {
  description = "The URL of the deployed imgproxy Container App"
  value       = module.imgproxy.url
}

output "cdn_hostname" {
  description = "Front Door endpoint hostname (when CDN enabled)"
  value       = module.imgproxy.cdn_endpoint_hostname
}

output "cdn_validation_tokens" {
  description = "DNS TXT validation tokens for custom domains (when CDN enabled)"
  value       = module.imgproxy.cdn_custom_domain_validation_tokens
}

output "monitoring_application_insights_id" {
  description = "Application Insights resource receiving the OpenTelemetry data"
  value       = module.imgproxy.monitoring_application_insights_id
}
