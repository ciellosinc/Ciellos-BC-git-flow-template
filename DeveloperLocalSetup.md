- 2. [Prerequisites for your local physical working station](#2-prerequisites-for-docker-on-windows)
   - 2.1. [Prerequisites for Docker on Windows](#21-prequisites-for-docker-on-windows)
   - 2.2. [Install the required Windows Features for Docker](#21-install-the-required-windows-features-for-docker)
   -  2.3. [Install Docker as in the below guide](#22-install-docker-as-in-the-below-guide)
   -  2.4. [Clone your repo from VSCode as below](#23-clone-your-repo-from-vscode-as-below)

## 2.1. Prerequisites for Docker on Windows

Before you can use Docker on Windows, you need to ensure that your system meets certain prerequisites:

- **WSL** (Windows Subsystem for Linux) version 1.1.3.0 or above.
- **Windows 11** 64-bit: Home or Pro version 21H2 or higher, or Enterprise or Education version 21H2 or higher.
- **Windows 10** 64-bit: Home or Pro 21H2 (build 19044) or higher, or Enterprise or Education 21H2 (build 19044) or higher.
- Enable the **WSL 2** feature on Windows. For detailed instructions, refer to the [Microsoft documentation](https://docs.microsoft.com/en-us/windows/wsl/install).
- Hardware prerequisites for running WSL 2 on Windows 10 or Windows 11:
  - 64-bit processor with Second Level Address Translation (SLAT)
  - 4GB system RAM
  - BIOS-level hardware virtualization support must be enabled in the BIOS settings. For more information, see [Virtualization](https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v).

The following PowerShell code should be executed line by line (F8) but can also be executed as a block (F5).

## 2.2. Install the required Windows Features for Docker

```powershell
#Install the required Windows Features for Docker
Enable-WindowsOptionalFeature -Online -FeatureName $("Microsoft-Hyper-V", "Containers") -All

#Install Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
#Set Chocolatey Safe Switch
choco feature enable -n allowGlobalConfirmation

#Use Choco
#Install Git
choco install -y -n allowGlobalConfirmation git.install --force
#Install VSCode
choco install vscode.install --force
#Install VSCode Extensions
$vsCodeExec = ($Env:PROGRAMFILES) + "\Microsoft VS Code\bin\code.cmd"
$extensions = @(
"GitHub.vscode-pull-request-github", # GitHub Pull Request
"waldo.al-extension-pack" # Waldo AL Extension Pack
) | SORT
$extensions | ForEach-Object {
Invoke-Expression "& '$vsCodeExec' --install-extension $_ --force"
}
```
## 2.3. Install Docker as in the below guide
[Install Docker Desktop - Windows](https://docs.docker.com/desktop/install/windows-install/)
## 2.4. Clone your repo from VSCode as below:
![Clone from GitHub](https://github.com/eh-ciellos/template/blob/main/images/CloneFromGitHub.png)
Open a new VSCode window and clone the repository locally. (You can also use the command line to clone the repository.)
![CloneGitRepoInVSCode1](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode1.png)
Or you can do it via CTRL+Shift+P and type Git: Clone
![CloneGitRepoInVSCode2](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode2.png)
Paste the repository URL and hit ENTER
![CloneGitRepoInVSCode3](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode3.png)
Create a new folder which will be your local repo and select it
![CloneGitRepoInVSCode4](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode4.png)
This will start the cloning
![CloneGitRepoInVSCode5](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode5.png)
Click Open on the new pop-up window
![CloneGitRepoInVSCode6](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode6.png)
And you have to trust the authors to continue working on it
![CloneGitRepoInVSCode7](https://github.com/eh-ciellos/template/blob/main/images/CloneGitRepoInVSCode7.png)
Now you can see the files in the repo
Execute .AL-Go\localDevEnv.ps1 as below to create your 1st BC container
![ExecLocalDevEnvPS1](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/ExecLocalDevEnvPS1.png)
You will be asked to enter the name of the container. Enter a name and hit ENTER
This container can be used to download symbols/publish your extension(Test your code before commiting to remote repo)
You can also update the launch.json to include a SaaS sandbox environment
Check this Microsoft documentation on how to create it
https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-json-launch-file

When you need to add a change to your code, it is suggested to create a new branch and commit your changes there. The example below is just adding records to the .gitignore just to give the idea:
![ModifyGitignore1](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/ModifyGitignore1.png)
![ModifyGitignore2](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/ModifyGitignore2.png)
![ModifyGitignore3](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/ModifyGitignore3.png)
![ModifyGitignore4](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/ModifyGitignore4.png)
![ModifyGitignore5](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/ModifyGitignore5.png)
![ModifyGitignore6](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/ModifyGitignore6.png)
![ModifyGitignore7](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/ModifyGitignore7.png)
![OpenGitRepoInVSCode1](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/OpenGitRepoInVSCode1.png)
![PR1](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/PR1.png)
![PR2](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/PR2.png)
![PR3](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/PR3.png)
![PR4](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/PR4.png)
![PR5](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/PR5.png)
![PR6](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/PR6.png)
![PR7](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/PR7.png)
![PR8](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/PR8.png)