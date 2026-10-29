#!/usr/bin/env python3
"""
Works out which files of a pull request can reach BC, from the AL-Go settings rather than from a
list kept by hand: the folders AL-Go builds are the folders whose files end up in a .app.

  sandbox-app-folders.py <ref>...                         # print the app folders, one per line
  sandbox-app-folders.py --shipped <files.txt> <ref>...   # print the changed files that ship

Every ref is read from git objects only (git ls-tree, git show) - nothing from a pull request is
checked out or executed. The folders of all refs are added together. The SandboxTested workflow
passes the base and the head of the pull request, so a request that adds a folder to the settings
counts that folder, and a request that takes its own folder out of the settings still counts it:
neither side can make the gate fail open.

The rules are AL-Go's own (Actions/AL-Go-Helper.ps1, AnalyzeRepo):

  * projects are the folders, up to two levels below the root, that hold .AL-Go/settings.json -
    or the ones listed in the 'projects' setting of .github/AL-Go-Settings.json;
  * a project builds the folders in appFolders, testFolders and bcptTestFolders, relative to the
    project folder, wildcards allowed, and only those that contain an app.json;
  * a project where all three lists are empty builds every folder below it that holds an app.json.

The lists of .github/AL-Go-Settings.json and the project's own settings are added together, again
so that the answer can only grow. conditionalSettings, user settings and GitHub variables are not
read; they can only make a list different on a branch, and the union over both refs already errs
on the side of asking for a verdict.

Inside an app folder, documentation and scripts in docs/ and scripts/ do not ship - but only files
of a type the AL compiler never takes in (NOT_COMPILED). The folder name alone proves nothing: the
compiler takes every .al file under the app folder, docs/ included, and an image there can be a
resource the app declares. Anything else in those folders counts as shipping.

Exit code 2 when a settings file cannot be read. The caller then has to treat every changed file
as one that reaches BC.
"""

import fnmatch
import json
import posixpath
import subprocess
import sys

LISTS = ("appFolders", "testFolders", "bcptTestFolders")
REPO_SETTINGS = ".github/AL-Go-Settings.json"
PROJECT_SETTINGS = ".AL-Go/settings.json"
NOT_SHIPPED = ("docs", "scripts")
NOT_COMPILED = (".md", ".txt", ".ps1", ".psm1", ".psd1", ".sh", ".py", ".cmd", ".bat")


class SettingsError(Exception):
    pass


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True,
                          encoding="utf-8").stdout


def load(ref, path):
    try:
        # utf-8-sig: a settings file saved by Windows tools may start with a BOM.
        return json.loads(git("show", f"{ref}:{path}").encode("utf-8").decode("utf-8-sig"))
    except (subprocess.CalledProcessError, ValueError) as e:
        raise SettingsError(f"{ref}:{path} cannot be read: {e}") from e


def folders_of(ref):
    files = git("ls-tree", "-r", "--name-only", ref).splitlines()
    app_dirs = {posixpath.dirname(f) for f in files if posixpath.basename(f) == "app.json"}

    repo = load(ref, REPO_SETTINGS) if REPO_SETTINGS in files else {}

    # "" is the root project. AL-Go looks two levels deep: "Project" and "Group/Project".
    projects = [f[: -len(PROJECT_SETTINGS)].rstrip("/") for f in files
                if f == PROJECT_SETTINGS or f.endswith("/" + PROJECT_SETTINGS)]
    projects = [p for p in projects if p.count("/") <= 1]
    if repo.get("projects"):
        listed = {posixpath.normpath(p) for p in repo["projects"]}
        projects = [p for p in projects if posixpath.normpath(p or ".") in listed]

    found = set()
    for project in projects:
        settings = load(ref, posixpath.join(project, PROJECT_SETTINGS))
        patterns = [p for key in LISTS for p in (repo.get(key) or []) + (settings.get(key) or [])]
        if patterns:
            for pattern in patterns:
                wanted = posixpath.normpath(posixpath.join(project, pattern.replace("\\", "/")))
                found |= {d for d in app_dirs if fnmatch.fnmatchcase(d, wanted)}
        else:
            prefix = project + "/" if project else ""
            found |= {d for d in app_dirs if d.startswith(prefix) and d != project}
    return found


def ships(path, folders):
    for folder in folders:
        if path.startswith(folder + "/"):
            inside = path[len(folder) + 1:]
            exempt = ("/" in inside and inside.split("/", 1)[0] in NOT_SHIPPED
                      and posixpath.splitext(inside)[1].lower() in NOT_COMPILED)
            return not exempt
    return False


def main(argv):
    shipped_from = None
    if argv[:1] == ["--shipped"]:
        if len(argv) < 3:
            sys.exit(__doc__)
        shipped_from, argv = argv[1], argv[2:]
    if not argv:
        sys.exit(__doc__)

    try:
        folders = set().union(*(folders_of(ref) for ref in argv))
    except SettingsError as e:
        print(e, file=sys.stderr)
        return 2

    if shipped_from is None:
        print("\n".join(sorted(folders)))
        return 0

    with open(shipped_from, encoding="utf-8") as f:
        changed = [line.strip() for line in f if line.strip()]
    print("\n".join(p for p in changed if ships(p, folders)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
