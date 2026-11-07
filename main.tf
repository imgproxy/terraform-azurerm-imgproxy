locals {
  # Custom repo wins; otherwise the Pro or community image
  image_repo = var.repo != null ? var.repo : (var.pro ? "docker.imgproxy.pro/imgproxy" : "ghcr.io/imgproxy/imgproxy")
}

module "imgproxy_common" {
  source = "./modules/imgproxy-common"

  # Image config
  tag  = var.tag
  repo = local.image_repo

  # Compute
  cpu            = var.cpu
  workers        = var.workers
  timeout        = var.timeout
  signature_size = var.signature_size

  # Provider-specific
  secret_key_name   = "id"
  storage_env_key   = "IMGPROXY_USE_ABS"
  storage_enabled   = length(var.source_storage_accounts) > 0
  enable_monitoring = var.enable_monitoring
  otel_service_name = var.service_name

  # Secrets
  insecure                         = var.insecure
  environment                      = var.environment
  secrets                          = var.secrets
  keys_secret                      = var.keys_secret
  salts_secret                     = var.salts_secret
  secret_secret                    = var.secret_secret
  trusted_signatures_secret        = var.trusted_signatures_secret
  source_url_encryption_key_secret = var.source_url_encryption_key_secret
  pro_license_key_secret           = var.pro_license_key_secret
}

locals {
  # From common module
  image             = module.imgproxy_common.image
  workers           = module.imgproxy_common.workers
  env_secret_vars   = module.imgproxy_common.env_secret_vars
  cdn_cache_headers = module.imgproxy_common.cdn_cache_headers
  cdn_cache_cookies = module.imgproxy_common.cdn_cache_cookies

  # Whether to set AZURE_CLIENT_ID
  use_storage = length(var.source_storage_accounts) > 0 || var.cache_storage_account != null

  # Azure-specific env_vars extension
  env_vars = merge(
    # imgproxy reads from a single storage account (IMGPROXY_ABS_NAME): the first one listed.
    # Defaults only: anything set in var.environment wins.
    length(var.source_storage_accounts) > 0 ? { IMGPROXY_ABS_NAME = element(split("/", var.source_storage_accounts[0]), length(split("/", var.source_storage_accounts[0])) - 1) } : {},
    var.cache_storage_account != null ? { IMGPROXY_CACHE_ABS_NAME = element(split("/", var.cache_storage_account), length(split("/", var.cache_storage_account)) - 1) } : {},
    module.imgproxy_common.env_vars,
    # Explicitly set the managed identity client ID so Azure SDK picks the right identity
    local.use_storage && local.identity_client_id != null ? { AZURE_CLIENT_ID = local.identity_client_id } : {},
  )

  # Azure-specific locals
  create_identity       = var.identity_id == null
  identity_id           = local.create_identity ? azurerm_user_assigned_identity.imgproxy[0].id : var.identity_id
  identity_principal_id = local.create_identity ? azurerm_user_assigned_identity.imgproxy[0].principal_id : var.identity_principal_id
  identity_client_id    = local.create_identity ? azurerm_user_assigned_identity.imgproxy[0].client_id : var.identity_client_id

  container_app_environment_id = var.container_app_environment_id != null ? var.container_app_environment_id : azurerm_container_app_environment.main[0].id

  # Secret configuration: normalized names and Key Vault URIs
  secrets_config = {
    for k, v in local.env_secret_vars :
    k => {
      name = lower(replace(k, "_", "-")) # Container App secret name constraints
      uri  = v.version != "" && v.version != "latest" ? "${v.id}/${v.version}" : v.id
    }
  }

  # Key Vault secret URIs the identity needs to read, keyed by env var / secret name
  key_vault_secret_uris = merge(
    { for k, v in local.secrets_config : k => v.uri },
    local.registry_uses_kv ? { "repo-password" = local.registry_secret_uri } : {},
  )

  # Registry credentials: the password lives in Key Vault; the username defaults to "imgproxy" for docker.imgproxy.pro
  registry_uses_kv = var.repo_password_secret != null
  registry_user    = var.repo_username != null ? var.repo_username : (var.repo == null && var.pro ? "imgproxy" : null)
  registry_server  = split("/", local.image_repo)[0]
  registry_secret_uri = local.registry_uses_kv ? (
    var.repo_password_secret.version != "" && var.repo_password_secret.version != "latest" ?
    "${var.repo_password_secret.id}/${var.repo_password_secret.version}" :
    var.repo_password_secret.id
  ) : null

  monitoring_workspace_id = !var.enable_monitoring ? null : (
    var.container_app_environment_id == null ? azurerm_log_analytics_workspace.main[0].id : azurerm_log_analytics_workspace.monitoring[0].id
  )

  # Vary header value for cache key variation by request headers.
  # Azure Front Door honors the Vary response header for cache key variation.
  # imgproxy already sends Vary: Accept (format detection) and client hint headers;
  # we reinforce it here so the header is preserved even when OverrideAlways is set.
  cdn_vary_value = length(local.cdn_cache_headers) > 0 ? join(", ", local.cdn_cache_headers) : null

  # Front Door CDN TTL in d.HH:MM:SS or HH:MM:SS format
  cdn_ttl_days    = floor(var.cdn_default_ttl / 86400)
  cdn_ttl_hours   = floor((var.cdn_default_ttl % 86400) / 3600)
  cdn_ttl_minutes = floor((var.cdn_default_ttl % 3600) / 60)
  cdn_ttl_seconds = var.cdn_default_ttl % 60
  # Azure Front Door requires HH:MM:SS for < 1 day, D.HH:MM:SS for >= 1 day
  cdn_ttl_str = local.cdn_ttl_days >= 1 ? format(
    "%d.%02d:%02d:%02d",
    local.cdn_ttl_days,
    local.cdn_ttl_hours,
    local.cdn_ttl_minutes,
    local.cdn_ttl_seconds,
    ) : format(
    "%02d:%02d:%02d",
    local.cdn_ttl_hours,
    local.cdn_ttl_minutes,
    local.cdn_ttl_seconds,
  )

}

# ── User Assigned Identity ────────────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "imgproxy" {
  count               = local.create_identity ? 1 : 0
  name                = "${var.service_name}-identity"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  lifecycle {
    precondition {
      condition     = !var.pro || var.repo != null || var.repo_password_secret != null
      error_message = "repo_password_secret is required when pro = true and repo is not set."
    }
    precondition {
      condition     = var.repo_password_secret == null || local.registry_user != null
      error_message = "repo_username is required when repo_password_secret is set."
    }
    precondition {
      condition     = var.insecure || (var.keys_secret != null && var.salts_secret != null)
      error_message = "keys_secret and salts_secret are required when insecure = false."
    }
    precondition {
      condition     = var.cache_storage_account == null || !contains(var.source_storage_accounts, var.cache_storage_account)
      error_message = "cache_storage_account must not also be a source storage account: the cache role grants write access, so imgproxy could overwrite source images."
    }
    precondition {
      condition     = var.identity_id == null || var.identity_principal_id != null
      error_message = "identity_principal_id is required when identity_id is set."
    }
  }
}

# ── Key Vault IAM ─────────────────────────────────────────────────────────────

# One assignment per secret, so the identity cannot read other secrets in the vault.
# The scope is built from the secret name in the URI (https://<vault>/secrets/<name>[/<version>]).
resource "azurerm_role_assignment" "key_vault" {
  for_each             = var.key_vault_id != null ? local.key_vault_secret_uris : {}
  scope                = "${var.key_vault_id}/secrets/${split("/", each.value)[4]}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = local.identity_principal_id
  depends_on           = [azurerm_user_assigned_identity.imgproxy]
}

# ── Storage IAM ───────────────────────────────────────────────────────────────

resource "azurerm_role_assignment" "source_storage" {
  for_each             = toset(var.source_storage_accounts)
  scope                = each.value
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = local.identity_principal_id
  depends_on           = [azurerm_user_assigned_identity.imgproxy]
}

resource "azurerm_role_assignment" "cache_storage" {
  count                = var.cache_storage_account != null ? 1 : 0
  scope                = var.cache_storage_account
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.identity_principal_id
  depends_on           = [azurerm_user_assigned_identity.imgproxy]
}

# ── Container App Environment ─────────────────────────────────────────────────

resource "azurerm_log_analytics_workspace" "main" {
  count               = var.container_app_environment_id == null ? 1 : 0
  name                = "${var.service_name}-logs"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_log_analytics_workspace" "monitoring" {
  count               = var.enable_monitoring && var.container_app_environment_id != null ? 1 : 0
  name                = "${var.service_name}-monitoring"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "monitoring" {
  count               = var.enable_monitoring ? 1 : 0
  name                = "${var.service_name}-monitoring"
  location            = var.location
  resource_group_name = var.resource_group_name
  workspace_id        = local.monitoring_workspace_id
  application_type    = "web"
  tags                = var.tags
}

resource "azurerm_container_app_environment" "main" {
  count                      = var.container_app_environment_id == null ? 1 : 0
  name                       = "${var.service_name}-env"
  location                   = var.location
  resource_group_name        = var.resource_group_name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main[0].id
  infrastructure_subnet_id   = var.subnet_id
  tags                       = var.tags
}

# ── Container App ─────────────────────────────────────────────────────────────

resource "azurerm_container_app" "main" {
  name                         = var.service_name
  container_app_environment_id = local.container_app_environment_id
  resource_group_name          = var.resource_group_name
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity_id]
  }

  # Secrets sourced from Key Vault via the managed identity
  dynamic "secret" {
    for_each = local.env_secret_vars
    content {
      name                = local.secrets_config[secret.key].name
      key_vault_secret_id = local.secrets_config[secret.key].uri
      identity            = local.identity_id
    }
  }

  # OTEL collector configuration and Azure Monitor connection string.
  dynamic "secret" {
    for_each = var.enable_monitoring ? [1] : []
    content {
      name  = "otel-collector-config"
      value = var.otel_collector_config
    }
  }

  dynamic "secret" {
    for_each = var.enable_monitoring ? [1] : []
    content {
      name  = "applicationinsights-connection-string"
      value = azurerm_application_insights.monitoring[0].connection_string
    }
  }

  # Registry password secret (used in the registry block below)
  dynamic "secret" {
    for_each = local.registry_uses_kv ? [1] : []
    content {
      name                = "repo-password"
      key_vault_secret_id = local.registry_secret_uri
      identity            = local.identity_id
    }
  }

  # Authenticate to the registry of 'repo' (docker.imgproxy.pro for Pro images by default)
  dynamic "registry" {
    for_each = local.registry_uses_kv ? [1] : []
    content {
      server               = local.registry_server
      username             = local.registry_user
      password_secret_name = "repo-password"
    }
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "imgproxy"
      image  = local.image
      cpu    = var.cpu
      memory = var.memory

      dynamic "env" {
        for_each = local.env_vars
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.env_secret_vars
        content {
          name        = env.key
          secret_name = local.secrets_config[env.key].name
        }
      }

      startup_probe {
        transport               = "HTTP"
        path                    = "/health"
        port                    = 8080
        initial_delay           = 2
        interval_seconds        = 2
        timeout                 = 1
        failure_count_threshold = 30
      }

      liveness_probe {
        transport               = "HTTP"
        path                    = "/health"
        port                    = 8080
        interval_seconds        = 10
        timeout                 = 1
        failure_count_threshold = 5
      }
    }

    # OpenTelemetry collector sidecar (when enabled)
    dynamic "container" {
      for_each = var.enable_monitoring ? [1] : []
      content {
        name   = "otel-collector"
        image  = "otel/opentelemetry-collector-contrib:0.164.0"
        cpu    = 0.25
        memory = "0.5Gi"

        command = ["/otelcol-contrib"]
        args    = ["--config=env:OTEL_COLLECTOR_CONFIG"]

        env {
          name        = "OTEL_COLLECTOR_CONFIG"
          secret_name = "otel-collector-config"
        }

        env {
          name        = "APPLICATIONINSIGHTS_CONNECTION_STRING"
          secret_name = "applicationinsights-connection-string"
        }
      }
    }
  }

  ingress {
    external_enabled           = var.enable_cdn ? true : var.allow_unauthenticated
    target_port                = 8080
    transport                  = "http"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  lifecycle {
    precondition {
      condition = (
        var.insecure &&
        var.secret_secret == null &&
        var.trusted_signatures_secret == null &&
        var.source_url_encryption_key_secret == null &&
        var.pro_license_key_secret == null &&
        length(var.secrets) == 0
      ) || var.key_vault_id != null
      error_message = "key_vault_id is required when any secrets are configured."
    }

    precondition {
      condition     = !var.enable_cdn || var.secret_secret == null
      error_message = "secret_secret cannot be used with enable_cdn = true. Azure Front Door does not forward the Authorization header."
    }
  }

  depends_on = [
    azurerm_user_assigned_identity.imgproxy,
    azurerm_role_assignment.key_vault,
    azurerm_application_insights.monitoring,
    azurerm_container_app_environment.main,
  ]
}

# ── Azure Front Door Standard (CDN) ───────────────────────────────────────────

resource "azurerm_cdn_frontdoor_profile" "main" {
  count               = var.enable_cdn ? 1 : 0
  name                = "${var.service_name}-afd"
  resource_group_name = var.resource_group_name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.tags
}

resource "azurerm_cdn_frontdoor_endpoint" "main" {
  count                    = var.enable_cdn ? 1 : 0
  name                     = "${var.service_name}-endpoint"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id
  tags                     = var.tags
}

resource "azurerm_cdn_frontdoor_origin_group" "main" {
  count                    = var.enable_cdn ? 1 : 0
  name                     = "${var.service_name}-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id
  session_affinity_enabled = false

  health_probe {
    interval_in_seconds = 100
    path                = "/health"
    protocol            = "Https"
    request_type        = "GET"
  }

  load_balancing {
    additional_latency_in_milliseconds = 50
    sample_size                        = 4
    successful_samples_required        = 3
  }
}

resource "azurerm_cdn_frontdoor_origin" "main" {
  count                         = var.enable_cdn ? 1 : 0
  name                          = "${var.service_name}-origin"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main[0].id
  enabled                       = true

  certificate_name_check_enabled = true
  host_name                      = azurerm_container_app.main.ingress[0].fqdn
  http_port                      = 80
  https_port                     = 443
  origin_host_header             = azurerm_container_app.main.ingress[0].fqdn
  priority                       = 1
  weight                         = 1000
}

resource "azurerm_cdn_frontdoor_custom_domain" "main" {
  for_each                 = var.enable_cdn ? toset(var.cdn_domains) : toset([])
  name                     = replace(each.value, ".", "-")
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id
  host_name                = each.value

  tls {
    certificate_type = "ManagedCertificate"
  }
}

# Cache TTL and query string behavior via rule set
resource "azurerm_cdn_frontdoor_rule_set" "cache" {
  count                    = var.enable_cdn ? 1 : 0
  name                     = "${replace(var.service_name, "-", "")}cache"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main[0].id
}

resource "azurerm_cdn_frontdoor_rule" "cache_ttl" {
  count                     = var.enable_cdn ? 1 : 0
  name                      = "SetCacheTTL"
  cdn_frontdoor_rule_set_id = azurerm_cdn_frontdoor_rule_set.cache[0].id
  order                     = 1
  behavior_on_match         = "Continue"

  # Front Door rejects rules until the origin group has an enabled origin
  depends_on = [azurerm_cdn_frontdoor_origin.main]

  actions {
    route_configuration_override_action {
      cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main[0].id
      forwarding_protocol           = "HttpsOnly"
      query_string_caching_behavior = "IgnoreQueryString"
      cache_behavior                = "OverrideAlways"
      cache_duration                = local.cdn_ttl_str
      compression_enabled           = true
    }

    # Reinforce the Vary header so Azure Front Door varies the cache by the same
    # request headers that CloudFront includes in its cache key. imgproxy sends
    # these headers itself (e.g. Vary: Accept for webp/avif detection) but
    # OverrideAlways can suppress origin headers — setting it explicitly here
    # ensures both AFD cache variation and correct client-side browser caching.
    dynamic "response_header_action" {
      for_each = local.cdn_vary_value != null ? [1] : []
      content {
        header_action = "Overwrite"
        header_name   = "Vary"
        value         = local.cdn_vary_value
      }
    }
  }
}

resource "azurerm_cdn_frontdoor_route" "main" {
  count                         = var.enable_cdn ? 1 : 0
  name                          = "${var.service_name}-route"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.main[0].id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.main[0].id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.main[0].id]
  cdn_frontdoor_rule_set_ids    = [azurerm_cdn_frontdoor_rule_set.cache[0].id]

  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = var.cdn_redirect_http_to_https
  patterns_to_match      = ["/*"]
  supported_protocols    = ["Http", "Https"]
  link_to_default_domain = true # Always link to default *.azurefd.net endpoint

  cdn_frontdoor_custom_domain_ids = [
    for d in azurerm_cdn_frontdoor_custom_domain.main : d.id
  ]

  depends_on = [
    azurerm_cdn_frontdoor_origin.main,
    azurerm_cdn_frontdoor_rule_set.cache,
  ]
}

resource "azurerm_cdn_frontdoor_custom_domain_association" "main" {
  for_each                       = var.enable_cdn ? azurerm_cdn_frontdoor_custom_domain.main : {}
  cdn_frontdoor_custom_domain_id = each.value.id
  cdn_frontdoor_route_ids        = [azurerm_cdn_frontdoor_route.main[0].id]
}
