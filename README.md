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

The installer creates a private managed clone, exposes its skills in both user-global discovery
locations, and structurally registers one catalog-owned session updater in each supported product:

- `~/.agents/skills` for Codex and Cursor;
- `~/.claude/skills` for Claude Code and Cursor.

POSIX systems use directory symlinks. Native Windows uses directory junctions, which require no
administrator or Developer Mode access. Hook registration preserves unrelated JSON keys, events,
handlers, and catalog entries. An existing malformed or unsupported hook file makes installation
fail without overwriting that file or exposing a partial installation.

## Automatic updates at session start

Each installed catalog has its own hook entry, lock, throttle, and managed clone. The hook command
contains only the catalog instance key and the path to the lifecycle script in that clone; it does
not contain or persist the bootstrap URL. Update work reads installed instances from owned state,
fetches only each clone's configured `origin` with Git prompting disabled, and reconciles every
installed prefix through the same validation and transactional activation used by `install`. One
locked catalog attempt performs one fetch and pins the resulting exact commit for every prefix.
The commit must be a fast-forward from the managed clone's current revision.

| Product | User configuration | Installed event |
| --- | --- | --- |
| Claude Code | `~/.claude/settings.json` | asynchronous `SessionStart`, matcher `startup\|clear` |
| Codex | `~/.codex/hooks.json` (`$CODEX_HOME/hooks.json` when set) | async `SessionStart`, `startup\|clear` |
| Cursor | `~/.cursor/hooks.json` | `sessionStart` only |

Claude Code and Codex updates run for a new session and after `/clear`, not for resume or compact.
Codex requires the user to review and trust a non-managed hook before it will run; a newly installed
or changed Team Skills hook can therefore be skipped until accepted in Codex. Cursor defines
`sessionStart` as creation of a new composer conversation and runs it fire-and-forget. Team Skills
does not install Cursor's separate `workspaceOpen` event. Cursor user-level hooks are local-only and
are not available in Cursor cloud agents.

The default throttle is six hours per catalog, measured from the last completely successful update.
An update skipped by that throttle or by an already-held catalog lock does no network fetch and
returns success. The hook launcher returns promptly, masks updater failure from product startup,
and starts at most one detached, one-shot updater attempt per event; there is no resident process,
daemon, cron job, or tool wrapper.

Updates are deliberately not guaranteed to finish before a product's initial skill scan. A newly
fetched skill may first be visible in the next session. This is especially relevant to the
asynchronous Claude Code and Codex hooks and Cursor's fire-and-forget event.

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
and foreign product configuration are outside that removal boundary. Removing a non-final prefix
keeps the catalog updater. Removing the final prefix removes only hook entries whose recorded
configuration path and exact command still prove catalog ownership, then removes that catalog's
managed clone, hook ownership state, and origin index. If a catalog-owned hook was edited, removal
refuses safely so the installation can be inspected and retried.

## State and failure behavior

POSIX state defaults to `${XDG_DATA_HOME:-$HOME/.local/share}/team-skills`. Native Windows state
defaults to `%LOCALAPPDATA%\team-skills` (or `%USERPROFILE%\.local\share\team-skills` when
`LOCALAPPDATA` is unavailable). Under that root:

```text
origins/<initial-url-digest>.instance
catalogs/<catalog-id>-<origin-digest>/
├── repo/                         managed Git clone and hook runtime
├── hooks/{claude,codex,cursor}.owner
├── last-success                  successful-update throttle timestamp
├── last-update.log               most recent hook-launched diagnostic
├── update.lock/                  present only during an update attempt
└── installs/<prefix-or-default>/
    ├── current                   active generated view link/junction
    ├── generations/              validated immutable views
    └── ownership/{agents,claude}/
```

The environment variables `TEAM_SKILLS_STATE_ROOT`, `TEAM_SKILLS_AGENTS_ROOT`,
`TEAM_SKILLS_CLAUDE_ROOT`, `TEAM_SKILLS_CLAUDE_HOOKS_FILE`,
`TEAM_SKILLS_CODEX_HOOKS_FILE`, and `TEAM_SKILLS_CURSOR_HOOKS_FILE` override these paths for managed
environments and disposable tests. They must be absolute, non-root paths. The default throttle can
be changed with `TEAM_SKILLS_THROTTLE_SECONDS`; `TEAM_SKILLS_NOW` and
`TEAM_SKILLS_STALE_LOCK_SECONDS` exist for deterministic testing and controlled test environments.

Clone and fetch diagnostics are suppressed so credential-bearing URLs are not echoed. Malformed
catalogs, invalid names, failed fetches, and failed generation do not replace the last known-good
view. Candidate activation, exposure reconciliation, ownership records, and managed-clone
advancement form one transaction: a late destination race or other unsuccessful install restores
the prior view and removes only newly created, still-proven catalog exposures. On a first-install
failure, no partial catalog exposure remains. The racing or user-owned path is never overwritten.
Interrupted temporary work is removed during process cleanup; validated generations are immutable
and activation is atomic at the `current` link.

A candidate is rejected before clone advancement unless it contains regular, non-symlinked copies
of all three lifecycle files (`team-skills.sh`, `team-skills-json.awk`, and `team-skills.ps1`) and
the native lifecycle script parses successfully. Rewritten, downgraded, or unrelated default-branch
history is also rejected. To move an installation to an origin with unrelated history, remove each
prefix using its original bootstrap selector, then install the new origin as a new instance. A
same-history mirror may be configured as `origin` and continues only when its candidate is a
fast-forward.

The last hook-launched diagnostic for a catalog is written atomically to
`catalogs/<instance-key>/last-update.log` below the state root. Origin values and Git clone/fetch
diagnostics are suppressed so credential-bearing remotes are not printed. The log retains at most
the final 64 KiB from the latest attempt without splitting a UTF-8 sequence. A failed fetch,
invalid candidate, substituted catalog-owned directory, or future-dated throttle stamp leaves
existing skills active and is retried after the next eligible session start. The manual
`update-all` action is also available for diagnosis; it attempts every catalog even when one fails
and returns nonzero if any eligible update fails.

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
[the authoring guide](docs/skill-authoring.md) for the portable subset. See
[operations and troubleshooting](docs/operations.md) for lifecycle architecture and recovery, and
[manual verification](docs/manual-verification.md) for the repeatable disposable fixture, pending
results template, and WSL/product checks that still require a human. The bounded Milestone 5
[security review](docs/security-review.md) records trust boundaries and residual risks.
