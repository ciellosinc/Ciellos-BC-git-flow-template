# Prerequisites for Docker on Windows

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

## Install the required Windows Features for Docker

```powershell
#Install the required Windows Features for Docker
Enable-WindowsOptionalFeature -Online -FeatureName $("Microsoft-Hyper-V", "Containers") -All

#Install Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

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
## Install Docker as in the below guide
https://docs.docker.com/desktop/install/windows-install/

## Clone your repo from VSCode as below:
![Clone from GitHub](https://github.com/eh-ciellos/template/blob/main/images/CloneFromGitHub.png)
Open a new VSCode window and clone the repository locally. (You can also use the command line to clone the repository.)
![CloneGitRepoInVSCode1](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode1.png)
Or you can do it via CTRL+Shift+P and type Git: Clone
![CloneGitRepoInVSCode2](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode2.png)
Paste the repository URL and hit ENTER
![CloneGitRepoInVSCode3](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode3.png)
Create a new folder which will be your local repo and select it
![CloneGitRepoInVSCode4](https://github.com/eh-ciellos/template/blob/7f9d1adbd14cba08d41fc4b44c4f3cd7249ae661/images/CloneGitRepoInVSCode4.png)