To enable code signing in your AL-Go project in GitHub, you'll need to set up an Azure Key Vault to securely store your CodeSigning certificate and configure your project to access it.

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

### 4. Create an Entra ID App + Client Secret with a Service Principal
- The signing operation needs to be performed by a service principal (your app registration is not going to be used to perform any authentication. No need for RedirectUri or other configs in this Entra ID App).
- For this, you need to create one in your Entra Admin Center and grant it the necessary permissions on the Key Vault.
- [Quickstart: Register an app in Microsoft Entra ID - Microsoft identity platform | Microsoft Learn](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app)
- Keep track of the `tenantId`, `clientId`, `clientSecret`, and `subscriptionId` of your Key Vault. You will need them to generate your `AZURE_CREDENTIALS` that looks like:
  ```json
  {
    "clientId": "CLIENT_ID_OF_YOUR_ENTRAIDAPP",
    "clientSecret": "CLIENT_SECRET_OF_YOUR_ENTRAIDAPP",
    "subscriptionId": "YOUR_SUBSCRIPTION_ID",
    "tenantId": "YOUR_TENANT_ID"
  }
  json```

### 5. Permissions / Access Policies

At a minimum, assign the following permissions:

#### Role Based Access Control (RBAC) - Roles Needed
- **Key Vault Crypto User**
- **Key Vault Certificate User**

#### Vault Access Policy - Permissions Needed
- **Cryptographic Operations:** Sign
- **Certificate permissions:** Get

Example Azure CLI commands:
```bash
az role assignment create --role "Key Vault Crypto User" --assignee <client-id> --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.KeyVault/vaults/<key-vault-name>"
az role assignment create --role "Key Vault Certificate User" --assignee <client-id> --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.KeyVault/vaults/<key-vault-name>"
az keyvault set-policy --name <key-vault-name> --object-id <object-id> --certificate-permissions get --key-permissions sign

### 6. Configure GitHub AL-Go Workflows

- **Add Organizational or Repository Secret:**
  1. Go to your GitHub repository.
  2. Navigate to **Settings** > **Secrets and variables** > **Actions**.
  3. Click **New repository secret**.
  4. Name the secret `AZURE_CREDENTIALS`.
  5. Paste your Azure credentials JSON as the value:
     ```json
     {
       "clientId": "CLIENT_ID_OF_YOUR_ENTRAIDAPP",
       "clientSecret": "CLIENT_SECRET_OF_YOUR_ENTRAIDAPP",
       "subscriptionId": "YOUR_SUBSCRIPTION_ID",
       "tenantId": "YOUR_TENANT_ID"
     }
     ```
  6. Save the secret.

For more details, see:  
[AL-Go/Scenarios/Codesigning.md at main · microsoft/AL-Go](https://github.com/microsoft/AL-Go/blob/main/Scenarios/Codesigning.md)
