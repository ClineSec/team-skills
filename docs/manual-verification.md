# Disposable manual verification

Automated tests exercise configuration merging and updater behavior with disposable homes, Git
origins, state roots, and config roots on Linux, macOS, and native Windows. The checks below are the
remaining human product-verification package. They have not been run or accepted on behalf of any
user.

## Safety boundary

Do not test against a normal user profile. Use a dedicated temporary OS account, VM, or disposable
product profile whose entire home/configuration directory can be discarded. The Team Skills test
overrides redirect its files, but Claude Code, Codex, and Cursor must also be launched in that same
disposable environment to read those hook files. Back up any intentionally seeded foreign JSON
fixtures before beginning.

Use two disposable local bare Git repositories as origins. Avoid credentials in their URLs even
though the lifecycle utility suppresses origin and Git fetch diagnostics. Seed each from a trusted
checkout, give both catalogs the same `catalog_id` and skill name, and install the second both with
the blank prefix (to observe warning-and-skip) and a nonblank prefix (to expose both).

## WSL POSIX-path evidence

WSL uses `scripts/team-skills.sh`, not the native PowerShell implementation. From a disposable WSL
checkout, the automated POSIX suite creates all of its own temporary homes and local origins:

```sh
python3 scripts/validate.py
python3 -m unittest discover -s tests -v
sh -n scripts/team-skills.sh
```

For a manual merge smoke test, first create a disposable catalog origin and set its path in
`DISPOSABLE_CATALOG_URL`. Then redirect every writable location before running `install`:

```sh
TEAM_SKILLS_CHECK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/team-skills-wsl.XXXXXXXX")
export TEAM_SKILLS_CHECK_ROOT
export TEAM_SKILLS_STATE_ROOT="$TEAM_SKILLS_CHECK_ROOT/state"
export TEAM_SKILLS_AGENTS_ROOT="$TEAM_SKILLS_CHECK_ROOT/agents/skills"
export TEAM_SKILLS_CLAUDE_ROOT="$TEAM_SKILLS_CHECK_ROOT/claude/skills"
export TEAM_SKILLS_CLAUDE_HOOKS_FILE="$TEAM_SKILLS_CHECK_ROOT/config/claude/settings.json"
export TEAM_SKILLS_CODEX_HOOKS_FILE="$TEAM_SKILLS_CHECK_ROOT/config/codex/hooks.json"
export TEAM_SKILLS_CURSOR_HOOKS_FILE="$TEAM_SKILLS_CHECK_ROOT/config/cursor/hooks.json"
sh scripts/team-skills.sh install "$DISPOSABLE_CATALOG_URL"
TEAM_SKILLS_THROTTLE_SECONDS=0 sh scripts/team-skills.sh update-all
```

Inspect only files below `$TEAM_SKILLS_CHECK_ROOT`, then remove that directory after the test. This
smoke test proves the WSL/POSIX path and merge output; it does not prove that a Windows-hosted
Cursor instance consumes WSL user configuration.

## Product lifecycle checks

Before starting a product, capture the three hook files, each instance's `last-success`, and the
active skill content. Set the catalog's remote to a new valid commit containing an unmistakable but
non-sensitive skill change. For timing-sensitive checks, launch the product from an environment
with `TEAM_SKILLS_THROTTLE_SECONDS=0`; restore the ordinary environment afterward.

### Claude Code

1. Start a new local session in the disposable profile. Confirm startup is prompt and the instance
   eventually records a successful update.
2. Use `/clear` after another valid remote change and confirm another update attempt.
3. Resume a session and trigger compaction separately. Confirm neither action starts a Team Skills
   update.
4. Force an unreachable origin, start a new session, and confirm Claude Code remains usable, the
   hook exits successfully, the previous skill stays active, and `last-update.log` contains no URL
   credentials. Restore the origin and confirm a clean retry.

Do not require the changed skill in the session that triggered the update. Claude Code normally
scans skills before an asynchronous `SessionStart` update completes, so verify it in the following
session.

### Codex

1. Review the newly discovered non-managed Team Skills hook and explicitly trust its exact
   definition. Record that step; Codex skips it until trusted and requires renewed review if its
   hash changes.
2. Start a new local session and then use `/clear`, making one valid remote change before each.
   Confirm both eventually update without delaying startup.
3. Resume and compact separately and confirm neither starts a Team Skills update.
4. Repeat the unreachable-origin and clean-retry check, including last-known-good retention and a
   credential-safe log.

As with Claude Code, allow one additional session before expecting a newly updated skill in the
initial scan.

### Cursor

1. Create a new local composer/agent conversation and confirm `sessionStart` launches the updater
   without blocking conversation creation.
2. Open or change a workspace without creating a conversation and confirm Team Skills does not run;
   it does not register `workspaceOpen`.
3. Create another conversation after a valid remote update, allow the fire-and-forget process to
   finish, and verify the changed skill no later than the following conversation.
4. Repeat the unreachable-origin and clean-retry check.

This check applies only to local Cursor. User-level `~/.cursor/hooks.json` and `sessionStart` are
not available in Cursor cloud agents, and no cloud synchronization is part of Team Skills.

## Multi-catalog and removal checks

With all three products closed, inspect the disposable JSON files and verify foreign entries plus
one updater entry for each catalog. Rerun both installs and confirm no duplicate entry appears.
Remove one catalog's final prefix and verify its exact entries and state disappear while the other
catalog, its prefixes, and every foreign entry survive. Finally remove the other catalog and verify
only its owned exposures, hook entries, and instance state are removed.

Record product versions, OS and shell versions, the tested Team Skills commit, sanitized
before/after JSON, state timestamps, and any product warnings. Do not report Milestone 4 product
verification as passed until a human has completed and reviewed these checks.
