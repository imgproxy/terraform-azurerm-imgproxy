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

variable "storage_account_name" {
  description = "Existing storage account that holds the source images (see README)"
  type        = string
}

data "azurerm_storage_account" "images" {
  name                = var.storage_account_name
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

  # Testing opt-in: the module is private by default (reachable only inside the Container Apps
  # Environment). This example has no private network or CDN, so public access is enabled here.
  allow_unauthenticated = true
  service_name          = "imgproxy"
  tag                   = "v4"

  key_vault_id = data.azurerm_key_vault.main.id
  keys_secret = {
    id = "${local.secrets_uri}/imgproxy-keys"
  }
  salts_secret = {
    id = "${local.secrets_uri}/imgproxy-salts"
  }

  # Existing storage account (see README): grants Storage Blob Data Reader, enables the abs:// URL scheme
  # and sets IMGPROXY_ABS_NAME to the account name
  source_storage_accounts = [data.azurerm_storage_account.images.id]
}

output "url" {
  value = module.imgproxy.url
}
