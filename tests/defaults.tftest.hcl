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

run "default_name" {
  command = plan

  assert {
    condition     = azurerm_container_app.main.name == "imgproxy"
    error_message = "Container App name must equal name default"
  }
}

run "community_image_url" {
  command = plan

  variables {
    tag = "v3.27.0"
  }

  assert {
    condition     = strcontains(azurerm_container_app.main.template[0].container[0].image, "ghcr.io/imgproxy/imgproxy:v3.27.0")
    error_message = "Community mode must use ghcr.io image"
  }
}

run "pro_image_url" {
  command = plan

  variables {
    tag = "v3.27.0"
    pro = true
    pro_license_key_secret = {
      id      = "https://test-kv.vault.azure.net/secrets/imgproxy-license"
      version = ""
    }
    repo_password_secret = {
      id      = "https://test-kv.vault.azure.net/secrets/docker-password"
      version = ""
    }
  }

  assert {
    condition     = strcontains(azurerm_container_app.main.template[0].container[0].image, "docker.imgproxy.pro/imgproxy:v3.27.0")
    error_message = "Pro mode must use docker.imgproxy.pro image"
  }

  assert {
    condition     = length(azurerm_container_app.main.registry) == 1
    error_message = "Pro mode must configure registry authentication"
  }
}

run "custom_prefix_propagates" {
  command = plan

  variables {
    service_name = "myapp"
  }

  assert {
    condition     = azurerm_container_app.main.name == "myapp"
    error_message = "Container App name must reflect service_name variable"
  }

  assert {
    condition     = azurerm_user_assigned_identity.imgproxy[0].name == "myapp-identity"
    error_message = "Identity name must use service_name prefix"
  }
}

run "custom_identity_skips_creation" {
  command = plan

  variables {
    identity_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
    identity_principal_id = "00000000-0000-0000-0000-000000000001"
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.imgproxy) == 0
    error_message = "Providing identity_id must skip identity creation"
  }
}

run "custom_image_override" {
  command = plan

  variables {
    repo = "mycr.azurecr.io/custom-imgproxy"
    tag  = "v1.0.0"
  }

  assert {
    condition     = azurerm_container_app.main.template[0].container[0].image == "mycr.azurecr.io/custom-imgproxy:v1.0.0"
    error_message = "Custom repo should be used in image reference"
  }
}

run "cdn_disabled_by_default" {
  command = plan

  assert {
    condition     = length(azurerm_cdn_frontdoor_profile.main) == 0
    error_message = "CDN must not create resources when disabled"
  }
}

run "cdn_with_domains" {
  command = plan

  variables {
    enable_cdn  = true
    cdn_domains = ["cdn.example.com"]
  }

  assert {
    condition     = length(azurerm_cdn_frontdoor_profile.main) == 1
    error_message = "CDN must create Front Door profile"
  }

  assert {
    condition     = azurerm_cdn_frontdoor_profile.main[0].name == "imgproxy-afd"
    error_message = "Front Door profile name must use name prefix"
  }

  assert {
    condition     = length(azurerm_cdn_frontdoor_custom_domain.main) == 1
    error_message = "CDN must create custom domain"
  }

  assert {
    condition     = azurerm_container_app.main.ingress[0].external_enabled == true
    error_message = "CDN must set external_enabled to true"
  }
}

run "timeout_sets_env_var_and_cdn" {
  command = apply

  variables {
    timeout     = 120
    enable_cdn  = true
    cdn_domains = ["cdn.example.com"]
  }

  assert {
    condition     = length([for e in azurerm_container_app.main.template[0].container[0].env : e if e.name == "IMGPROXY_TIMEOUT" && e.value == "120"]) == 1
    error_message = "IMGPROXY_TIMEOUT must be set to the timeout value"
  }
}

run "timeout_null_no_env_var" {
  command = apply

  assert {
    condition     = length([for e in azurerm_container_app.main.template[0].container[0].env : e if e.name == "IMGPROXY_TIMEOUT"]) == 0
    error_message = "IMGPROXY_TIMEOUT must not be set when timeout is null"
  }
}

run "workers_calculation" {
  command = apply

  variables {
    cpu = 0.75
  }

  assert {
    condition     = length([for e in azurerm_container_app.main.template[0].container[0].env : e if e.name == "IMGPROXY_WORKERS" && e.value == "2"]) == 1
    error_message = "IMGPROXY_WORKERS must be ceil(cpu * 2) = ceil(1.5) = 2"
  }
}

run "custom_workers_override" {
  command = apply

  variables {
    cpu     = 1
    workers = 4
  }

  assert {
    condition     = length([for e in azurerm_container_app.main.template[0].container[0].env : e if e.name == "IMGPROXY_WORKERS" && e.value == "4"]) == 1
    error_message = "Custom workers value must override calculated value"
  }
}

run "private_by_default" {
  command = plan

  assert {
    condition     = azurerm_container_app.main.ingress[0].external_enabled == false
    error_message = "Ingress must be internal unless allow_unauthenticated = true"
  }
}

run "public_opt_in" {
  command = plan

  variables {
    allow_unauthenticated = true
  }

  assert {
    condition     = azurerm_container_app.main.ingress[0].external_enabled == true
    error_message = "allow_unauthenticated = true must expose the ingress"
  }
}

run "cdn_forces_external_ingress" {
  command = plan

  variables {
    enable_cdn  = true
    cdn_domains = ["cdn.example.com"]
  }

  assert {
    condition     = azurerm_container_app.main.ingress[0].external_enabled == true
    error_message = "Front Door needs an externally reachable origin"
  }
}

run "key_vault_access_is_per_secret" {
  command = plan

  assert {
    condition = (
      length(azurerm_role_assignment.key_vault) == 2 &&
      toset([for r in azurerm_role_assignment.key_vault : r.scope]) == toset([
        "${var.key_vault_id}/secrets/imgproxy-key",
        "${var.key_vault_id}/secrets/imgproxy-salt",
      ])
    )
    error_message = "Key Vault Secrets User must be scoped to each secret, not the vault"
  }
}

run "custom_registry_uses_credentials" {
  command = plan

  variables {
    repo          = "registry.example.com/imgproxy"
    repo_username = "deploy"
    repo_password_secret = {
      id = "https://test-kv.vault.azure.net/secrets/registry-password"
    }
  }

  assert {
    condition     = azurerm_container_app.main.registry[0].server == "registry.example.com"
    error_message = "The registry server must be the host of repo"
  }

  assert {
    condition     = azurerm_container_app.main.registry[0].username == "deploy"
    error_message = "The registry must use repo_username"
  }
}

run "pro_registry_defaults_username" {
  command = plan

  variables {
    pro = true
    repo_password_secret = {
      id = "https://test-kv.vault.azure.net/secrets/docker-password"
    }
  }

  assert {
    condition     = azurerm_container_app.main.registry[0].server == "docker.imgproxy.pro" && azurerm_container_app.main.registry[0].username == "imgproxy"
    error_message = "Pro must authenticate to docker.imgproxy.pro as imgproxy"
  }
}

run "custom_registry_requires_username" {
  command = plan

  variables {
    repo = "registry.example.com/imgproxy"
    repo_password_secret = {
      id = "https://test-kv.vault.azure.net/secrets/registry-password"
    }
  }

  expect_failures = [azurerm_user_assigned_identity.imgproxy]
}
