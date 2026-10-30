# Sandbox Assembly: workflows and scripts

Ready-to-copy implementation of the [Sandbox Assembly Flow](../../Guides/BranchFlow-SandboxAssembly.md).

Copy the content of [`.github`](.github) into the `.github` folder of an AL-Go repository, then follow [Setting it up in an AL-Go repository](../../Guides/BranchFlow-SandboxAssembly.md#setting-it-up-in-an-al-go-repository): add `sandbox/current` to the AL-Go settings, and create the `GHTOKENWORKFLOW` secret and the `sandbox-tested` label. The app folders are read from the AL-Go settings (`appFolders`, `testFolders`, `bcptTestFolders`), so there is no list to keep up to date.

The workflows do nothing in this template repository: GitHub only runs workflows from the root `.github/workflows` folder.

Run the tests after changing a script:

```bash
bash .github/scripts/test-assemble-sandbox.sh
bash .github/scripts/test-mark-sandbox-deployed.sh
bash .github/scripts/test-sandbox-app-folders.sh
bash .github/scripts/test-notify-teams.sh
```

Optional: set the `TEAMS_WEBHOOK_URL` secret (a Teams Workflows webhook) to get a card in a Teams channel after every Sandbox deploy.
