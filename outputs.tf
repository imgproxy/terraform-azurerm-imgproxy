output "url" {
  description = "The HTTPS URL of the imgproxy Container App."
  value       = "https://${azurerm_container_app.main.ingress[0].fqdn}"
}

output "name" {
  description = "The Container App name."
  value       = azurerm_container_app.main.name
}

output "identity_id" {
  description = "Resource ID of the User Assigned Managed Identity used by the Container App."
  value       = local.identity_id
}

output "location" {
  description = "The Azure region where the Container App is deployed."
  value       = var.location
}

output "cdn_endpoint_hostname" {
  description = "Hostname of the Front Door endpoint. Create a CNAME record pointing your domain to this hostname. Null when CDN is disabled."
  value       = var.enable_cdn ? azurerm_cdn_frontdoor_endpoint.main[0].host_name : null
}

output "cdn_custom_domain_validation_tokens" {
  description = "Map of domain → DNS TXT validation token required to activate managed TLS certificates for custom domains."
  value = var.enable_cdn ? {
    for d in azurerm_cdn_frontdoor_custom_domain.main :
    d.host_name => d.validation_token
  } : {}
}

output "monitoring_workspace_id" {
  description = "Resource ID of the Log Analytics workspace used by Azure Monitor for OTEL data. Null when monitoring is disabled."
  value       = var.enable_monitoring ? local.monitoring_workspace_id : null
}

output "monitoring_application_insights_id" {
  description = "Resource ID of the Application Insights resource receiving OTEL data. Null when monitoring is disabled."
  value       = var.enable_monitoring ? azurerm_application_insights.monitoring[0].id : null
}
