# Delta for managed-service-topologies: slim-first-release-surface

## MODIFIED Requirements

### Requirement: Private service networking
Managed PostgreSQL, Redis, and Blob storage SHALL deny public data-plane access and use private DNS linked to the supplied VNet.

#### Scenario: Resolve managed services privately
- **WHEN** a pod resolves the managed PostgreSQL, Redis, or storage hostname
- **THEN** DNS SHALL return the corresponding private endpoint or delegated-subnet address rather than a public endpoint

## REMOVED Requirements

### Requirement: Optional shared Azure Files storage
**Reason**: Azure Files existed to serve the shared-`filesystem` storage modes, which the 0.1.0 release does not support. Removing it deletes the share, the file private DNS zone and endpoint, the CSI credential Secret, the static PV/PVC pair, the all-pod Helm volume fragment, the destroy-time SMB drain gate, the account-key authentication requirement on the storage account, three inputs, and three outputs. Azure Blob with workload identity is the only managed n8n data plane.
**Migration**: None required for 0.1.0 (first release, no existing deployments). Callers needing a shared volume can mount their own PVC through `n8n_extra_volumes` / `n8n_extra_volume_mounts`.
