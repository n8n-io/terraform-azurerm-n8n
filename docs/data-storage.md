# Binary and execution data storage

The module stores binary data in Azure Blob Storage or PostgreSQL and stores execution bundles in either of those backends. 0.1.0 does not support n8n's inline-memory `default` binary mode or a shared-filesystem mode. Binary and execution-data storage have separate n8n Enterprise entitlements.

## Requirements

Azure Blob modes require n8n 2.29.0 or later. The default `n8n_image_tag = "2.35.0"` includes the Azure container-scoped credential startup fix. Keep the application and task-runner images on the same n8n version during every storage rollout.

The license entitlements are separate:

- Azure binary data requires `feat:binaryDataAz`.
- Azure execution data requires `feat:executionDataAz`.

Enabling one mode does not require or grant the other entitlement. n8n refuses to start when an Azure mode is selected without its matching entitlement.

## Binary data modes

`n8n_binary_data_storage_mode` selects where new binary objects are written:

- `azure` writes to the private module-managed Blob container. This is the default.
- `database` writes to PostgreSQL. Use this durable queue-mode backend when the Azure binary-data entitlement is unavailable.

`n8n_available_binary_data_modes` controls which backends n8n may read. It must include the active write mode. Keep every historical backend in this list until all objects in it have expired or have been migrated.

For example, this configuration keeps database-backed objects readable while writes have already moved to Azure:

```hcl
n8n_binary_data_storage_mode    = "azure"
n8n_available_binary_data_modes = ["database", "azure"]
```

The module renders `N8N_DEFAULT_BINARY_DATA_MODE`, `N8N_AVAILABLE_BINARY_DATA_MODES`, and the required storage connection on main, worker, and webhook pods.

## Execution data modes

`n8n_execution_data_storage_mode` selects where new execution bundles are written:

- `database` keeps execution data in PostgreSQL. This is the default.
- `azure` writes to the Blob container and requires `azure_blob_container_stores_execution_data = true`.

n8n records the backend used by each execution. A mode change affects new writes only. Older executions remain readable while their database or Azure backend remains available.

When Azure stores current or historical execution bundles, keep `azure_blob_container_stores_execution_data = true`. This suppresses the binary lifecycle rule because n8n, not Azure lifecycle management, owns execution-data pruning.

## Azure authentication

Workload identity is the default. The module renders the storage account and container names with `N8N_EXTERNAL_STORAGE_AZURE_AUTH_AUTO_DETECT=true`. The n8n service account uses `DefaultAzureCredential`, and its user-assigned managed identity receives `Storage Blob Data Contributor` on the managed container.

Terraform's own storage data-plane authentication is separate from the n8n workload identity. Configure the calling `azurerm` provider with `storage_use_azuread = true`, and grant the applying identity `Storage Blob Data Contributor` on the target resource group or storage account before the module creates its private container. The complete examples provision this role and wait for RBAC propagation. Without both settings, AzureRM attempts shared-key access even though the secure default disables storage-account keys, or Entra authentication fails with HTTP 403.

Compatibility credentials are explicit opt-ins:

- `azure_blob_connection_string` takes precedence over other authentication settings.
- `azure_blob_account_key` uses the managed account name and key.
- `azure_blob_endpoint` overrides the Blob endpoint for a custom or sovereign endpoint.

These inputs are sensitive in Terraform, but their rendered environment values remain in Terraform state and in the pod environment. Restrict access to both.

Endpoint support does not certify the whole module for Azure Government, Azure China, or another sovereign environment. Validate AzureRM resource availability, DNS zone suffixes, AKS features, and n8n behavior separately.

## Retention ownership

Binary and execution data use different pruning owners:

- Azure lifecycle management may expire binary objects when the container is dedicated to binary data.
- n8n prunes execution bundles through its execution hard-delete process.

Do not configure `azure_blob_binary_retention_days` when `azure_blob_container_stores_execution_data = true`. The module omits the lifecycle policy and emits a diagnostic because a broad container or `workflows/` rule can delete execution bundles that n8n still references.

When the container is binary-only, `azure_blob_binary_retention_days` applies expiry to that container. Before enabling Azure execution storage later, remove the lifecycle rule, apply, set `azure_blob_container_stores_execution_data = true`, then change the execution mode.

## Transition procedure

Changing a mode does not copy or backfill data.

1. Back up the database, encryption key, and every current storage backend.
2. Keep the old backend mounted, reachable, and authenticated.
3. Add the new backend to the available mode configuration before changing writes.
4. Apply the connection and networking changes.
5. Change the active write mode and apply again.
6. Verify new writes and historical reads from every n8n pod family.
7. Retain the old backend until all references expire or an operator completes a separate migration.
8. Remove the historical mode only after verification.

Removing a mode or backend early makes retained data unreadable. Terraform does not move objects between Blob Storage and PostgreSQL.
