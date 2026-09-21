# Turns on every root-module resource gated behind a `count`-controlled
# opt-in switch, so checkov's second CI pass actually evaluates them.
# checkov answers every check on a count-0 resource with UNKNOWN and drops
# it from the report, so a resource off by default in the module and in
# every example (redis_exporter today) draws zero findings under the
# module's own defaults. See tests/scripts/check-checkov.sh.
#
# This is a checkov-only fixture, not a deployable configuration: it does
# not set the required non-nullable variables (location, resource_group_name,
# vnet_id, subnet ids, n8n_domain, app_gateway_tls_cert_secret_id,
# n8n_license_key). checkov's Terraform graph analysis resolves `count` and
# resource attributes from HCL statically; it never needs a valid plan.
redis_exporter_enabled = true
