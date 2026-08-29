# Disposable manual verification

Automated tests exercise configuration merging and updater behavior with disposable homes, Git
origins, state roots, and config roots on Linux, macOS, and native Windows. The checks below are the
remaining human product-verification package. They have not been run or accepted on behalf of any
user.

## Prepare the repeatable fixture

Do not test against a normal user profile. Use a dedicated temporary OS account, VM, or disposable
product profile whose entire home/configuration directory can be discarded. Clone Team Skills at
the commit under test inside that environment. The fixture helper requires Python only to prepare
test data; installation and updating still require only the platform shell and Git.

On macOS, Linux, or WSL:

```sh
TEAM_SKILLS_MANUAL_PARENT=$(mktemp -d "${TMPDIR:-/tmp}/team-skills-manual.XXXXXXXX")
TEAM_SKILLS_MANUAL_ROOT="$TEAM_SKILLS_MANUAL_PARENT/fixture"
export TEAM_SKILLS_MANUAL_PARENT TEAM_SKILLS_MANUAL_ROOT
python3 scripts/prepare-manual-verification.py prepare "$TEAM_SKILLS_MANUAL_ROOT"
. "$TEAM_SKILLS_MANUAL_ROOT/environment.sh"
```

On native Windows PowerShell:

```powershell
$TeamSkillsManualParent = Join-Path ([IO.Path]::GetTempPath()) ("team-skills-manual-" + [guid]::NewGuid())
$TeamSkillsManualRoot = Join-Path $TeamSkillsManualParent "fixture"
python scripts/prepare-manual-verification.py prepare $TeamSkillsManualRoot
. (Join-Path $TeamSkillsManualRoot "environment.ps1")
```

The helper refuses an existing root and never launches a product. It creates two local bare origins
with the same catalog ID and skill name, installs the first twice, installs the second once blank
and once as `second`, seeds foreign configuration, and records before/after JSON and the visible
collision warning. Inspect `fixture.json`, `evidence/install-transcript.txt`, both skill roots, and
all three hook files before launching anything. `RESULTS.md` is copied from the
[pending results template](manual-results-template.md) with the tested Team Skills SHA filled in.

Use these commands to make controlled changes during the checklist:

```sh
python3 scripts/prepare-manual-verification.py advance "$TEAM_SKILLS_MANUAL_ROOT" first v2
python3 scripts/prepare-manual-verification.py origin "$TEAM_SKILLS_MANUAL_ROOT" first unreachable
python3 scripts/prepare-manual-verification.py origin "$TEAM_SKILLS_MANUAL_ROOT" first restore
python3 scripts/prepare-manual-verification.py show "$TEAM_SKILLS_MANUAL_ROOT"
```

Use `python` and `$TeamSkillsManualRoot` for the equivalent PowerShell commands. `advance` creates
and pushes one valid local commit. `origin ... unreachable` uses only an absent local file origin
with inert `manual-user` and `manual-secret` strings, so it exercises credential redaction without
network access; `restore` puts back the original local origin.

Claude Code, Codex, and Cursor must be launched from the prepared environment in the dedicated
account/VM/profile so their ordinary paths resolve to the fixture's `home`. Merely redirecting the
installer while launching a normal product profile would not test the generated hook files.

## WSL POSIX-path evidence

WSL uses `scripts/team-skills.sh`, not the native PowerShell implementation. From a disposable WSL
checkout, the automated POSIX suite creates all of its own temporary homes and local origins:

```sh
python3 scripts/validate.py
python3 -m unittest discover -s tests -v
sh -n scripts/team-skills.sh
```

For the exact disposable merge/update smoke test, run the preparation commands above inside WSL,
then advance only the first catalog and invoke the POSIX URL-free updater:

```sh
python3 scripts/prepare-manual-verification.py advance "$TEAM_SKILLS_MANUAL_ROOT" first wsl-v2
TEAM_SKILLS_NOW=2000000000 sh scripts/team-skills.sh update-all
grep -q '# Fixture first wsl-v2' "$TEAM_SKILLS_AGENTS_ROOT/common-skill/SKILL.md"
grep -q 'name: second-common-skill' "$TEAM_SKILLS_CLAUDE_ROOT/second-common-skill/SKILL.md"
grep -q '# Fixture second v1' "$TEAM_SKILLS_CLAUDE_ROOT/second-common-skill/SKILL.md"
grep -q 'foreign-workspace' "$TEAM_SKILLS_CURSOR_HOOKS_FILE"
```

This proves validation/tests in WSL, POSIX hook merging, colliding/prefixed exposure, and a local
origin-based update that leaves the second skill content unchanged. It does not prove that a
Windows-hosted Cursor instance consumes WSL user configuration, nor does it count as a native
Windows PowerShell result.

## Product lifecycle checks

Before each product event, copy the three hook files, each instance's `last-success` and
`last-update.log` when present, and the active `SKILL.md` into a new evidence subdirectory. Use an
unmistakable, non-sensitive marker with `advance`. The prepared environment disables throttling;
do not carry that setting outside this disposable profile.

### Claude Code

1. Run `advance ... first claude-startup`, start a fresh local session, and confirm startup is
   prompt and `last-success` eventually changes.
2. Run `advance ... first claude-clear`, use `/clear`, and confirm another completed update.
3. Record `last-success` and `last-update.log`, resume a session, and trigger compaction separately.
   Confirm neither file changes.
4. Run `origin ... first unreachable`, start a fresh session, and confirm Claude Code remains
   usable, the previous skill stays active, and `last-update.log` contains neither `manual-user` nor
   `manual-secret`. Run `origin ... first restore`, advance once more, and confirm a clean retry.

Do not require the changed skill in the session that triggered the update. Claude Code normally
scans skills before an asynchronous `SessionStart` update completes, so verify it in the following
session.

### Codex

1. Review the newly discovered non-managed Team Skills hook and explicitly trust its exact
   definition. Record that step; Codex skips it until trusted and requires renewed review if its
   hash changes.
2. Advance the first origin, start a new local session, then advance again and use `/clear`.
   Confirm both eventually update without delaying startup.
3. Capture timestamps, resume and compact separately, and confirm neither starts an update.
4. Repeat `origin ... unreachable`, fresh startup, `restore`, advance, and fresh startup. Confirm
   fail-open behavior, last-known-good retention, a log without either inert credential string,
   and clean retry.

As with Claude Code, allow one additional session before expecting a newly updated skill in the
initial scan.

### Cursor

1. Advance the first origin, create a new local composer/agent conversation, and confirm
   `sessionStart` launches the updater without blocking conversation creation.
2. Capture timestamps, open or change a workspace without creating a conversation, and confirm
   neither updater evidence file changes; Team Skills does not register `workspaceOpen`.
3. Advance again, create a conversation, allow the fire-and-forget process to finish, and verify
   the marker no later than the following conversation.
4. Repeat the unreachable-origin, new-conversation, restore, advance, and clean-retry check.

This check applies only to local Cursor. User-level `~/.cursor/hooks.json` and `sessionStart` are
not available in Cursor cloud agents, and no cloud synchronization is part of Team Skills.

## Multi-catalog and removal checks

With all three products closed, inspect the disposable JSON files and verify foreign entries plus
one updater entry for each catalog. Rerun both installs and confirm no duplicate entry appears.
Remove one catalog's final prefix and verify its exact entries and state disappear while the other
catalog, its prefixes, and every foreign entry survive. Finally remove the other catalog and verify
only its owned exposures, hook entries, and instance state are removed.

## Cleanup

Close every product launched with the disposable environment. Review `RESULTS.md` and copy only
sanitized evidence that must be retained. Confirm `fixture.json` reports the exact expected root.
Then delete only `$TEAM_SKILLS_MANUAL_PARENT` on POSIX or `$TeamSkillsManualParent` on Windows. Do
not delete a normal home, product configuration directory, or any parent of the generated fixture.
No service, scheduled task, cron entry, plugin, wrapper, or machine-wide artifact was installed.

Record product versions, OS and shell versions, the tested Team Skills commit, sanitized
before/after JSON, state timestamps, and any product warnings. Every row remains `PENDING` until a
human performs and reviews it; automated CI does not turn these product/WSL rows into passes.
