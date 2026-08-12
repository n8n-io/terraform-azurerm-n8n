# Azure Key Vault external secrets

n8n's Azure Key Vault external-secrets integration is separate from both Azure Blob workload identity and Application Gateway certificate access. This Terraform module does not create or configure the integration.

## Prerequisites

The integration is an n8n Enterprise feature. The operator must provide a caller-owned Microsoft Entra application and service principal with:

- Tenant ID
- Application client ID
- Client secret value
- Access to the target Key Vault

Grant the service principal `Key Vault Secrets User` on the target vault. The integration lists secrets before reading their values, so a per-secret assignment is not sufficient for the complete provider workflow. n8n supports single-line secret values, not JSON objects, for this provider.

This client-secret contract is different from the AKS workload identity used for Blob Storage. Do not reuse the Application Gateway identity or assume the n8n pod's federated identity authenticates the external-secrets provider.

## Configure n8n

1. Sign in as an n8n instance owner or administrator.
2. Open **Settings**, then **External Secrets**.
3. Add an Azure Key Vault connection.
4. Enter the vault name, tenant ID, client ID, and client secret value.
5. Test and save the connection.
6. Reference a value in a credential as `{{ $secrets.<connection-name>.<secret-name> }}`.

The client secret is stored through n8n's encrypted credential and settings path, not through this Terraform module's variables.

## Public and sovereign endpoints

An Azure Key Vault client needs two coordinated endpoint settings:

| Cloud | Vault DNS suffix | Microsoft Entra authority host |
| --- | --- | --- |
| Public Azure | `vault.azure.net` | `https://login.microsoftonline.com/` |
| Azure Government | `vault.usgovcloudapi.net` | `https://login.microsoftonline.us/` |
| Azure China | `vault.azure.cn` | `https://login.chinacloudapi.cn/` |
| Custom environment | Caller-supplied HTTPS vault endpoint | Caller-supplied HTTPS authority host |

The vault endpoint and authority host must belong to the same cloud. Mixing a sovereign vault suffix with the public authority causes token audience or authority failures.

At the pinned n8n application line, the Azure Key Vault external-secrets UI accepts a vault name, tenant ID, client ID, and client secret and constructs the public Azure URL `https://<vault>.vault.azure.net/`. It does not expose vault endpoint or authority-host fields. Therefore, the stock pinned image supports the public Azure path only for this integration. A sovereign or custom deployment requires an n8n release or caller-maintained image that exposes both endpoint settings. Verify that behavior before deployment.

This limitation is specific to n8n's external-secrets provider. `azure_blob_endpoint` configures Blob Storage only and does not change Key Vault or Microsoft Entra endpoints.

Endpoint compatibility does not certify this Terraform module for Azure Government, Azure China, or a disconnected cloud. The caller must also validate provider support, AKS, private DNS, and every managed service in the selected environment.

## Microsoft Entra workflow credentials

Workflow-node credentials are outside this deployment module's boundary. The module does not:

- Create Microsoft Entra applications or service principals
- Generate client secrets or certificates for workflow credentials
- Grant Microsoft Graph application permissions
- Perform tenant-wide admin consent
- Configure redirect URIs for individual n8n credentials

The application owner must create those identities, apply least-privilege API permissions, complete admin consent when required, and rotate their credentials. Azure Key Vault external secrets may hold the resulting values, but it does not replace the Entra application lifecycle.

## Security notes

- Prefer short-lived client secrets and rotate them before expiry.
- Restrict the service principal to the required Key Vault scope.
- Keep Application Gateway certificate access, Blob data access, and external-secret access on separate identities.
- Audit Key Vault secret reads and n8n external-secrets connection changes.
- Treat Terraform state, n8n database backups, and namespace access as sensitive even though this module does not accept the external-secrets client secret.
