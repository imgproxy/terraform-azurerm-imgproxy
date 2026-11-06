mock_provider "azurerm" {}

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

run "rejects_pro_without_registry_password" {
  command = plan

  variables {
    pro = true
    pro_license_key_secret = {
      id      = "https://test-kv.vault.azure.net/secrets/license"
      version = ""
    }
  }

  expect_failures = [azurerm_user_assigned_identity.imgproxy]
}

run "rejects_secure_mode_without_keys" {
  command = plan

  variables {
    keys_secret  = null
    salts_secret = null
  }

  # The common module repeats this check; mock it so only the root precondition is evaluated.
  override_module {
    target = module.imgproxy_common
    outputs = {
      image             = "mock"
      workers           = 1
      env_vars          = {}
      env_secret_vars   = {}
      cdn_cache_headers = []
      cdn_cache_cookies = []
    }
  }

  expect_failures = [azurerm_user_assigned_identity.imgproxy]
}

run "rejects_secure_mode_without_salts" {
  command = plan

  variables {
    salts_secret = null
  }

  # The common module repeats this check; mock it so only the root precondition is evaluated.
  override_module {
    target = module.imgproxy_common
    outputs = {
      image             = "mock"
      workers           = 1
      env_vars          = {}
      env_secret_vars   = {}
      cdn_cache_headers = []
      cdn_cache_cookies = []
    }
  }

  expect_failures = [azurerm_user_assigned_identity.imgproxy]
}

run "rejects_secrets_without_key_vault" {
  command = plan

  variables {
    key_vault_id = null
    secret_secret = {
      id      = "https://test-kv.vault.azure.net/secrets/secret"
      version = ""
    }
  }

  expect_failures = [azurerm_container_app.main]
}

run "accepts_cdn_without_domains" {
  command = plan

  variables {
    enable_cdn = true
  }

  assert {
    condition     = length(azurerm_cdn_frontdoor_endpoint.main) == 1 && length(azurerm_cdn_frontdoor_custom_domain.main) == 0
    error_message = "CDN without custom domains must still create the default *.azurefd.net endpoint"
  }
}

run "rejects_cdn_with_secret_secret" {
  command = plan

  variables {
    enable_cdn  = true
    cdn_domains = ["cdn.example.com"]
    secret_secret = {
      id      = "https://test-kv.vault.azure.net/secrets/secret"
      version = ""
    }
  }

  expect_failures = [azurerm_container_app.main]
}

run "rejects_cache_account_that_is_also_a_source" {
  command = plan

  variables {
    source_storage_accounts = ["/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/shared"]
    cache_storage_account   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Storage/storageAccounts/shared"
  }

  expect_failures = [azurerm_user_assigned_identity.imgproxy]
}
