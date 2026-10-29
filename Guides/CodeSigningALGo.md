# Code Signing with Azure Key Vault in AL-Go

To enable code signing in your AL-Go project in GitHub, you'll need to set up an Azure Key Vault to securely store your CodeSigning certificate and configure your project to access it.

You need three things in the end:

| What | Where | Step |
| --- | --- | --- |
| The certificate | Azure Key Vault (Premium SKU) | 2, 3 |
| `AZURE_CREDENTIALS` secret with `keyVaultName` | GitHub repository or organization secret | 4, 6 |
| `keyVaultCodesignCertificateName` setting | `.github/AL-Go-Settings.json` | 7 |

## Steps

### 1. Azure Subscription
- Ensure you have an active Azure subscription to create and manage Azure resources.

### 2. Azure Key Vault Setup
- Set up a new Azure Key Vault in your Azure subscription.
- The Azure Key Vault should be **Premium SKU**, as only the Premium SKU supports Hardware Security Modules (HSMs) required for CodeSigning certificates.

### 3. Code Signing Certificate
- **Obtain a Code Signing Certificate:** Acquire a code signing certificate from a trusted Certificate Authority (CA).
- **Import the Certificate into your Azure Key Vault:** This process varies depending on your CA.
  - For DigiCert and GlobalSign, there are already integrations in Azure Key Vault:  
    [Integrating Key Vault with DigiCert certificate authority | Microsoft Learn](https://learn.microsoft.com/en-us/azure/key-vault/certificates/certificate-authority-digicert)
  - For other CAs like SSL.com, documentation with specific manual instructions should be provided by the CA:  
    [Generate a CSR and Install a Certificate in Microsoft Azure Key Vault - SSL.com](https://www.ssl.com/how-to/generate-a-csr-and-install-a-certificate-in-microsoft-azure-key-vault/)
- **Note:** Moving your certificate from the CA's vault to Azure Key Vault may interfere with your other CodeSigning processes if you use the same certificate to sign different apps. Since the certificate will not be in the CA's vault anymore, codesigning for these apps should be migrated to Azure Key Vault.

### 4. Create an Entra ID App with a Service Principal
- The signing operation needs to be performed by a service principal (your app registration is not going to be used to perform any authentication. No need for RedirectUri or other configs in this Entra ID App).
- For this, you need to create one in your Entra Admin Center and grant it the necessary permissions on the Key Vault.
- [Quickstart: Register an app in Microsoft Entra ID - Microsoft identity platform | Microsoft Learn](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app)
- Choose how the app authenticates:
  - **Client secret** (the most common option). Create one under **Certificates & secrets** and note its value and expiry date. Keep track of the `tenantId`, `clientId`, `clientSecret` and `subscriptionId`, and the name of your Key Vault. You will need them to generate your `AZURE_CREDENTIALS` that looks like:
    ```json
    {
      "keyVaultName": "YOUR_KEY_VAULT_NAME",
      "clientId": "CLIENT_ID_OF_YOUR_ENTRAIDAPP",
      "clientSecret": "CLIENT_SECRET_OF_YOUR_ENTRAIDAPP",
      "subscriptionId": "YOUR_SUBSCRIPTION_ID",
      "tenantId": "YOUR_TENANT_ID"
    }
    ```
    Before you save it as a secret in step 6, compress it to a single line.
  - **Federated credential (no stored secret).** Under **Certificates & secrets** -> **Federated credentials**, add a credential for **GitHub Actions deploying Azure resources** with your organization, repository and branch. Only workflows from that branch can then sign in, and there is no secret to rotate.

### 5. Permissions / Access Policies

A Key Vault uses **one** of two permission models: Role Based Access Control (RBAC, recommended) or Vault Access Policy. You can see which one under **Settings** -> **Access configuration** of the Key Vault. Assign the permissions for the model your vault uses, not both.

#### Role Based Access Control (RBAC) - Roles Needed
- **Key Vault Crypto User**
- **Key Vault Certificate User**

#### Vault Access Policy - Permissions Needed
- **Cryptographic Operations:** Sign
- **Certificate permissions:** Get

Example Azure CLI commands for RBAC:
```bash
az role assignment create --role "Key Vault Crypto User" --assignee <client-id> --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.KeyVault/vaults/<key-vault-name>"
az role assignment create --role "Key Vault Certificate User" --assignee <client-id> --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.KeyVault/vaults/<key-vault-name>"
```

Example Azure CLI command for Vault Access Policy:
```bash
az keyvault set-policy --name <key-vault-name> --object-id <object-id> --certificate-permissions get --key-permissions sign
```

If AL-Go should also read other secrets from this Key Vault, add **Key Vault Secrets User** (RBAC) or the **Get, List** secret permissions (Access Policy).

### 6. Configure GitHub AL-Go Workflows

- **Add Organizational or Repository Secret:**
  1. Go to your GitHub repository.
  2. Navigate to **Settings** > **Secrets and variables** > **Actions**.
  3. Click **New repository secret**.
  4. Name the secret `AZURE_CREDENTIALS`.
  5. Paste your Azure credentials as the value. It must be **compressed JSON on a single line** and must contain the **`keyVaultName`**: this is how AL-Go knows which Key Vault to use. GitHub masks each line of a secret separately, so a multi-line JSON value breaks AL-Go.
     - With a client secret:
       ```
       {"keyVaultName":"<key-vault-name>","clientId":"<client-id>","clientSecret":"<client-secret>","subscriptionId":"<subscription-id>","tenantId":"<tenant-id>"}
       ```
     - With a federated credential:
       ```
       {"keyVaultName":"<key-vault-name>","clientId":"<client-id>","tenantId":"<tenant-id>"}
       ```
  6. Save the secret.

### 7. Tell AL-Go which certificate to use

Add the name of the certificate, as it is called in the Key Vault, to `.github/AL-Go-Settings.json`:

```json
{
  "keyVaultCodesignCertificateName": "<name-of-the-certificate-in-key-vault>"
}
```

Without this setting AL-Go does not sign the apps, even when `AZURE_CREDENTIALS` is set.

### 8. Check the result

Run the `CI/CD` workflow and open the log of the **Sign** step of the build job. It should show that the apps were signed with the certificate from the Key Vault.

Only `CI/CD` (and the workflows built on it) signs apps. `Pull Request Build` never signs, so a green PR build says nothing about signing. The **Sign** step is also skipped when the `doNotSignApps` setting is `true`.

> [!TIP]
> AL-Go also supports **Azure Trusted Signing** through the `trustedSigning` setting. With it you do not buy a certificate from a CA and do not need a Premium Key Vault. See [AL-Go settings](https://github.com/microsoft/AL-Go/blob/main/Scenarios/settings.md).

For more details, see:  
[AL-Go/Scenarios/Codesigning.md at main · microsoft/AL-Go](https://github.com/microsoft/AL-Go/blob/main/Scenarios/Codesigning.md)
