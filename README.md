# Team Skills

Team Skills is a fork-first catalog for distributing user-global, portable Agent Skills to Claude
Code, Codex, and Cursor. A team forks the repository, curates `skills/`, and treats the managed
clone's configured Git `origin` as the authority for later reconciliations. No operational path
falls back to this repository's upstream.

## Install a fork

Fork owners must change **both** `YOUR-ORG` occurrences below to their fork owner. The repository
URL passed to `install` is the explicit initial bootstrap URL and the stable selector for that
catalog instance on later manual runs.

On macOS, Linux, or WSL, using only a POSIX shell and Git:

```sh
curl -fsSL https://raw.githubusercontent.com/YOUR-ORG/team-skills/main/scripts/team-skills.sh \
  | sh -s -- install https://github.com/YOUR-ORG/team-skills.git
```

On native Windows, using Windows PowerShell and Git without administrator access:

```powershell
$installer = Invoke-RestMethod https://raw.githubusercontent.com/YOUR-ORG/team-skills/main/scripts/team-skills.ps1
& ([scriptblock]::Create($installer)) install https://github.com/YOUR-ORG/team-skills.git
```

Review downloaded scripts before executing them when that is required by your security policy.
Private forks may instead clone through their normal authenticated Git workflow and run the local
script:

```sh
sh scripts/team-skills.sh install "$(git remote get-url origin)"
```

```powershell
.\scripts\team-skills.ps1 install (git remote get-url origin)
```

The installer creates a private managed clone and exposes its skills in both user-global discovery
locations:

- `~/.agents/skills` for Codex and Cursor;
- `~/.claude/skills` for Claude Code and Cursor.

POSIX systems use directory symlinks. Native Windows uses directory junctions, which require no
administrator or Developer Mode access. The scripts do not install runtimes, modify product hooks,
or change other product configuration.

## Multiple catalogs and prefixes

Run the installer once for each catalog URL. Each exact initial URL receives deterministic,
isolated clone and ownership state. A rerun fetches only the managed clone's currently configured
`origin`, validates a complete candidate, and then reconciles its exposures.

The default prefix is read from `catalog.json` and is blank in this repository. With a blank
prefix, an existing destination wins: the incoming skill is skipped, a warning is printed, the
existing bytes are untouched, and the command succeeds. Use a prefix when colliding catalogs
should coexist:

```sh
sh scripts/team-skills.sh install https://github.com/YOUR-ORG/team-skills.git --prefix acme
```

```powershell
.\scripts\team-skills.ps1 install https://github.com/YOUR-ORG/team-skills.git -Prefix acme
```

For example, `skill-creator` becomes `acme-skill-creator`. The installer creates a validated,
catalog-owned copy whose directory and `SKILL.md` name agree, while preserving its body, resources,
and required executable permissions.

An explicit empty prefix overrides a catalog's nonblank default:

```sh
sh scripts/team-skills.sh install REPOSITORY-URL --prefix ''
```

```powershell
.\scripts\team-skills.ps1 install REPOSITORY-URL -Prefix ''
```

## Remove a catalog installation

Pass the same initial repository URL and prefix used to install the view:

```sh
sh scripts/team-skills.sh remove REPOSITORY-URL --prefix acme
```

```powershell
.\scripts\team-skills.ps1 remove REPOSITORY-URL -Prefix acme
```

Removal deletes an exposure only when its ownership record and link target both still match. A
changed or user-replaced path is retained with a warning. Other prefixes, catalogs, user skills,
and product configuration are outside that removal boundary. Removing the final prefix also
removes that catalog's managed clone and origin index.

## State and failure behavior

POSIX state defaults to `${XDG_DATA_HOME:-$HOME/.local/share}/team-skills`. Native Windows state
defaults to `%LOCALAPPDATA%\team-skills` (or `%USERPROFILE%\.local\share\team-skills` when
`LOCALAPPDATA` is unavailable). Under that root:

```text
origins/<initial-url-digest>.instance
catalogs/<catalog-id>-<origin-digest>/
├── repo/                         managed Git clone
└── installs/<prefix-or-default>/
    ├── current                   active generated view link/junction
    ├── generations/              validated immutable views
    └── ownership/{agents,claude}/
```

The environment variables `TEAM_SKILLS_STATE_ROOT`, `TEAM_SKILLS_AGENTS_ROOT`, and
`TEAM_SKILLS_CLAUDE_ROOT` override these roots for managed environments and disposable tests. They
must be absolute, non-root paths.

Clone and fetch diagnostics are suppressed so credential-bearing URLs are not echoed. Malformed
catalogs, invalid names, failed fetches, and failed generation do not replace the last known-good
view. Interrupted temporary work is removed on the next process cleanup; validated generations
are immutable and activation is atomic at the `current` link.

## What is not automatic yet

Milestone 2 implements explicit install, reconcile-on-rerun, collision handling, prefixes, and
safe removal. It does **not** install session-start hooks or run background updates. Until milestone
3 adds noninteractive, throttled hook integration, fetching and reconciliation happen only when a
user reruns `install`. Manual in-product verification in Claude Code, Codex, and Cursor also remains
a later acceptance step.

## Curate and validate a fork

Canonical skills live in `skills/<name>/SKILL.md`. Keep them portable across all three products;
the bundled `skill-creator` documents the common authoring workflow and includes a deterministic
scaffold helper.

Python 3.9 or newer is used only for repository validation and tests, not by the installers:

```sh
python3 scripts/validate.py
python3 -m unittest discover -s tests -v
```

The canonical format follows the primary documentation reviewed on 2026-08-29:

- [Agent Skills specification](https://agentskills.io/specification)
- [Claude Code skills](https://code.claude.com/docs/en/skills)
- [Codex skills](https://developers.openai.com/codex/skills)
- [Cursor Agent Skills](https://cursor.com/docs/skills)

See [the catalog contract](docs/catalog-contract.md) for exact multi-catalog semantics and
[the authoring guide](docs/skill-authoring.md) for the portable subset.
