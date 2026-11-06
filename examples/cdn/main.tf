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

  key_vault_id = data.azurerm_key_vault.main.id
  keys_secret = {
    id = "${local.secrets_uri}/imgproxy-keys"
  }
  salts_secret = {
    id = "${local.secrets_uri}/imgproxy-salts"
  }

  enable_cdn = true

  # With a domain, Front Door provisions a managed TLS certificate for it:
  # cdn_domains = ["cdn.example.com"]

  cdn_default_ttl            = 3600
  cdn_redirect_http_to_https = true
}

output "url" {
  value = module.imgproxy.url
}

output "cdn_hostname" {
  value       = module.imgproxy.cdn_endpoint_hostname
  description = "Front Door endpoint hostname (*.azurefd.net); point a CNAME here when using a custom domain"
}

output "cdn_validation_tokens" {
  value       = module.imgproxy.cdn_custom_domain_validation_tokens
  description = "DNS TXT validation tokens for custom domains"
}
