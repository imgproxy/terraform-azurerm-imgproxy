mock_provider "azurerm" {
  mock_resource "azurerm_log_analytics_workspace" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.OperationalInsights/workspaces/ws" }
  }
  mock_resource "azurerm_cdn_frontdoor_profile" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.Cdn/profiles/profile" }
  }
  mock_resource "azurerm_cdn_frontdoor_endpoint" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.Cdn/profiles/profile/afdEndpoints/ep" }
  }
  mock_resource "azurerm_cdn_frontdoor_origin_group" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.Cdn/profiles/profile/originGroups/og" }
  }
  mock_resource "azurerm_cdn_frontdoor_rule_set" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.Cdn/profiles/profile/ruleSets/rs" }
  }
  mock_resource "azurerm_container_app_environment" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.App/managedEnvironments/env" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id"
      principal_id = "00000000-0000-0000-0000-000000000001"
      client_id    = "00000000-0000-0000-0000-000000000002"
    }
  }
  mock_resource "azurerm_cdn_frontdoor_origin" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.Cdn/profiles/profile/originGroups/og/origins/o" }
  }
  mock_resource "azurerm_cdn_frontdoor_custom_domain" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.Cdn/profiles/profile/customDomains/cd" }
  }
  mock_resource "azurerm_cdn_frontdoor_rule" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.Cdn/profiles/profile/ruleSets/rs/rules/r" }
  }
  mock_resource "azurerm_cdn_frontdoor_route" {
    defaults = { id = "/subscriptions/12345678-1234-9876-4563-123456789012/resourceGroups/test-rg/providers/Microsoft.Cdn/profiles/profile/afdEndpoints/ep/routes/rt" }
  }
}

variables {
  resource_group_name = "test-rg"
  keys_secret = {
    id      = "https://test-kv.vault.azure.net/secrets/imgproxy-key"
    version = ""
  }
  salts_secret = {
    id      = "https://test-kv.vault.azure.net/secrets/imgproxy-salt"
    version = ""
  }
  key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.KeyVault/vaults/test-kv"
}

run "insecure_skips_key_secrets" {
  command = plan

  variables {
    insecure     = true
    keys_secret  = null
    salts_secret = null
    key_vault_id = null
  }

  assert {
    condition     = length([for s in azurerm_container_app.main.secret : s if s.name == "imgproxy-key"]) == 0
    error_message = "keys secret must not be configured in insecure mode"
  }

  assert {
    condition     = length([for s in azurerm_container_app.main.secret : s if s.name == "imgproxy-salt"]) == 0
    error_message = "salts secret must not be configured in insecure mode"
  }
}

run "secure_mode_configures_key_secrets" {
  command = plan

  assert {
    condition     = length([for s in azurerm_container_app.main.secret : s if s.name == "imgproxy-key"]) == 1
    error_message = "keys secret must be configured in secure mode"
  }

  assert {
    condition     = length([for s in azurerm_container_app.main.secret : s if s.name == "imgproxy-salt"]) == 1
    error_message = "salts secret must be configured in secure mode"
  }
}

run "key_vault_iam_granted" {
  command = plan

  assert {
    condition     = length(azurerm_role_assignment.key_vault) == 2
    error_message = "Key Vault Secrets User role must be granted to identity, once per secret"
  }

  assert {
    condition     = alltrue([for r in azurerm_role_assignment.key_vault : r.role_definition_name == "Key Vault Secrets User"])
    error_message = "Role must be Key Vault Secrets User"
  }
}

run "secrets_map_creates_container_app_secrets" {
  command = apply

  variables {
    secrets = {
      IMGPROXY_NEW_RELIC_KEY = { id = "https://test-kv.vault.azure.net/secrets/newrelic" }
    }
  }

  assert {
    condition     = length([for s in azurerm_container_app.main.secret : s if s.name == "imgproxy-new-relic-key"]) == 1
    error_message = "secrets map entries must create Container App secrets"
  }

  assert {
    condition     = length([for e in azurerm_container_app.main.template[0].container[0].env : e if e.name == "IMGPROXY_NEW_RELIC_KEY"]) == 1
    error_message = "secrets map entries must create environment variables"
  }
}

run "secrets_map_custom_version" {
  command = plan

  variables {
    secrets = {
      IMGPROXY_NEW_RELIC_KEY = { id = "https://test-kv.vault.azure.net/secrets/newrelic", version = "abc123" }
      IMGPROXY_SENTRY_DSN    = { id = "https://test-kv.vault.azure.net/secrets/sentry" }
    }
  }

  assert {
    condition     = length([for s in azurerm_container_app.main.secret : s if s.name == "imgproxy-new-relic-key" && strcontains(s.key_vault_secret_id, "/abc123")]) == 1
    error_message = "custom version must be included in Key Vault secret URI"
  }

  assert {
    condition     = length([for s in azurerm_container_app.main.secret : s if s.name == "imgproxy-sentry-dsn" && !strcontains(s.key_vault_secret_id, "/latest") && !strcontains(s.key_vault_secret_id, "/abc")]) == 1
    error_message = "empty version must use base URI without version suffix"
  }
}

run "source_storage_grants_reader" {
  command = plan

  variables {
    source_storage_accounts = [
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/storage1",
      "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/storage2"
    ]
  }

  assert {
    condition     = length(azurerm_role_assignment.source_storage) == 2
    error_message = "source_storage_accounts must create one IAM binding per account"
  }

  assert {
    condition     = azurerm_role_assignment.source_storage["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/storage1"].role_definition_name == "Storage Blob Data Reader"
    error_message = "source_storage_accounts IAM role must be Storage Blob Data Reader"
  }
}

run "cache_storage_grants_contributor" {
  command = plan

  variables {
    cache_storage_account = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/cache"
  }

  assert {
    condition     = length(azurerm_role_assignment.cache_storage) == 1
    error_message = "cache_storage_account must create an IAM binding"
  }

  assert {
    condition     = azurerm_role_assignment.cache_storage[0].role_definition_name == "Storage Blob Data Contributor"
    error_message = "cache_storage_account IAM role must be Storage Blob Data Contributor"
  }
}

run "monitoring_configures_otel" {
  command = apply

  variables {
    enable_monitoring = true
  }

  assert {
    condition     = length([for e in azurerm_container_app.main.template[0].container[0].env : e if e.name == "IMGPROXY_OPEN_TELEMETRY_ENABLE" && e.value == "true"]) == 1
    error_message = "Monitoring must enable imgproxy OpenTelemetry"
  }

  assert {
    condition     = length([for c in azurerm_container_app.main.template[0].container : c if c.name == "otel-collector"]) == 1
    error_message = "Monitoring must add the OTEL collector sidecar"
  }

  assert {
    condition     = length(azurerm_application_insights.monitoring) == 1
    error_message = "Monitoring must create an Application Insights resource"
  }
}

run "custom_environment_id_skips_creation" {
  command = plan

  variables {
    container_app_environment_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.App/managedEnvironments/existing-env"
  }

  assert {
    condition     = length(azurerm_container_app_environment.main) == 0
    error_message = "Providing container_app_environment_id must skip environment creation"
  }

  assert {
    condition     = length(azurerm_log_analytics_workspace.main) == 0
    error_message = "Providing container_app_environment_id must skip Log Analytics workspace creation"
  }
}

run "storage_account_names_from_ids" {
  command = plan

  variables {
    identity_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id"
    identity_principal_id   = "11111111-1111-1111-1111-111111111111"
    identity_client_id      = "22222222-2222-2222-2222-222222222222"
    source_storage_accounts = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/srcacct"]
    cache_storage_account   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/cacheacct"
  }

  assert {
    condition     = local.env_vars["IMGPROXY_ABS_NAME"] == "srcacct" && local.env_vars["IMGPROXY_CACHE_ABS_NAME"] == "cacheacct" && local.env_vars["IMGPROXY_USE_ABS"] == "true"
    error_message = "Storage account names must be derived from the resource IDs"
  }
}

run "environment_overrides_account_name" {
  command = plan

  variables {
    identity_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id"
    identity_principal_id   = "11111111-1111-1111-1111-111111111111"
    identity_client_id      = "22222222-2222-2222-2222-222222222222"
    source_storage_accounts = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/srcacct"]
    environment             = { IMGPROXY_ABS_NAME = "other" }
  }

  assert {
    condition     = local.env_vars["IMGPROXY_ABS_NAME"] == "other"
    error_message = "environment must override the derived account name"
  }
}
