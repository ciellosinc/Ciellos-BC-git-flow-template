# Project name - Extension name
## :mega: General Information
This is a template for a Business Central project. Please fill in this template. Specify real names, numbers and links.

The project is developed by a team of developers and is deployed to the following environments: Development, Test, UAT and Production. 
The project is managed using the Kanban board. 
<br />The project is based on the [AL-Go Template](https://github.com/microsoft/AL-Go), which automates the build and deployment process, making it easier for developers to focus on the development and reaching the end goal of publishing to AppSource.

## :steam_locomotive: Team
| Role          | Description              | Full Name              |
|:-------------:|:-------------------------|:-----------------------|
| **PM**        | *Project Manager*        | Michelle Costello
| **TA**        | *Technical Architect*    | Milo Langworth
| **FC**        | *Functional Consultant*  | Abigail West
| **DEV**       | *Developer*              | Giovani Johnston, Addison Hermiston
| **SE/DevOps** | *System Engineer/DevOps* | Larry Williams

## :unicorn: Application
This Business Central Application has the following parameters:
- **Name**: "ABC Extension"  
- **Extension Type**: [Per-tenant extension (PTE)](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-extension-types-and-scope#per-tenant-extensions-ptes)  
- **Extension Type**: [AppSource or Global app](https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-extension-types-and-scope#global-apps)
- **Business Central Version**: BC 23

*Please use one code repository per Extension*

### :triangular_ruler: Object Ranges
- App1 - {
    "from": 7XXXXXXX,
    "to": 7XXXXXXY
  }
- App2 - {
    "from": 7XXXXXXX,
    "to": 7XXXXXXY
  }

### :date: Object Prefix (Affix)
- ABC

### :lollipop: Other BC Applications in use
The customer is going to use the following extensions, including third-party ISV extensions:
| Extension | Description | Link to download |
|:----------|:------------|:-----------------|
| Core solution | Customer Core Extension with essential code | https://github.com/ciellosinc/Ciellos-BC-git-flow-template
| Master Data | Sync Master Data Data between instances | https://appsource.microsoft.com/en-us/marketplace/apps?search=master%20data&page=1&product=dynamics-365-business-central
| Bank | Bank Integration | https://appsource.microsoft.com/en-us/marketplace/apps?search=bank&page=1&product=dynamics-365-business-central
| Warehouse | WHS | https://appsource.microsoft.com/en-us/marketplace/apps?search=warehouse&page=1&product=dynamics-365-business-central

## 🖥️ Environments
| Environment | Branch      |  Link                                                                          | Description |
|:------------|:------------|:-------------------------------------------------------------------------------|-------------|
| `DEV`       | `feature/*` | Use local Docker-containers for development                                    | 
| `Sandbox`   | `main`      | https://businesscentral.dynamics.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/TEST | Internal Testing
| `UAT`       | `release`   | https://businesscentral.dynamics.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/UAT  | Customer's User Acceptance Test
| `PROD`      | `release`   | https://businesscentral.dynamics.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/PROD | Production - we have no access

- Please find how to set up a [local `DEV` environment](https://github.com/ciellosinc/Ciellos-BC-git-flow-template/blob/main/Guides/LocalDevelopment.md).  
- Please find how to set up [Environments](https://dev.azure.com/ciellos-bc/main/_wiki/wikis/Internal%20Wiki/109/Environments).  
- Please find how to work with [Branches](https://github.com/ciellosinc/Ciellos-BC-git-flow-template/blob/main/Guides/BranchFlow.md).

## :microscope: Kanban board and Product Backlog
[![Board Status](https://ciellos.visualstudio.com/6f789900-0db7-46c9-9b00-84e46c577012/12d40337-33b9-431b-8f86-a52195352ee1/_apis/work/boardbadge/7c8cf15d-7ca5-45f8-9a46-e6cb22409844)](https://ciellos.visualstudio.com/6f789900-0db7-46c9-9b00-84e46c577012/_boards/board/t/12d40337-33b9-431b-8f86-a52195352ee1/Microsoft.RequirementCategory)

- [Kanban board](https://ciellos.visualstudio.com/Ciellos%20BC%20git%20flow%20Template/_boards/board/t/Ciellos%20BC%20git%20flow%20Template%20Team/Stories)
- [Product Log](https://ciellos.visualstudio.com/Ciellos%20BC%20git%20flow%20Template)


## :bell: Teams Channel
[BC Implementation](https://teams.microsoft.com/l/channel/19%3ARCJIPW3TwGLgWSR7xB79M5_xPlei2GFJ59xE0eRG4rw1%40thread.tacv2/General?groupId=be7a6c1c-7f8a-4282-addf-e99ebbd295ce&tenantId=46e85934-1fab-4533-a4ad-de92ce1fd81a)


# :moyai: Best Practices and other helpful information
Below, you can find the table of contents pointing to all the needed guides for Business Central development:

- [Branches and git Flow](https://github.com/ciellosinc/Ciellos-BC-git-flow-template/blob/main/Guides/BranchFlow.md)
- [Local development setup](https://github.com/ciellosinc/Ciellos-BC-git-flow-template/blob/main/Guides/LocalDevelopment.md)
- [AL Development Best Practices](https://github.com/ciellosinc/Ciellos-BC-git-flow-template/blob/main/Guides/ALDevelopmentBestPractices.md)
