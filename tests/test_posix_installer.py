from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "team-skills.sh"


@unittest.skipIf(os.name == "nt", "POSIX installer tests run on POSIX CI workers")
class PosixInstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="team skills ")
        self.base = Path(self.temporary.name)
        self.home = self.base / "disposable home"
        self.state = self.base / "state root"
        self.agents = self.home / ".agents" / "skills"
        self.claude = self.home / ".claude" / "skills"
        self.home.mkdir()
        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.home),
                "TEAM_SKILLS_STATE_ROOT": str(self.state),
                "TEAM_SKILLS_AGENTS_ROOT": str(self.agents),
                "TEAM_SKILLS_CLAUDE_ROOT": str(self.claude),
                "GIT_CONFIG_NOSYSTEM": "1",
            }
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, *args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", *args], cwd=cwd, text=True, capture_output=True, check=False, env=self.env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def make_catalog(
        self, label: str, body: str, *, executable_resource: bool = False
    ) -> tuple[Path, Path]:
        work = self.base / f"{label} work"
        origin = self.base / f"{label} origin.git"
        work.mkdir()
        manifest = {
            "$schema": "./schemas/catalog.schema.json",
            "schema_version": 1,
            "catalog_id": "shared-catalog-id",
            "display_name": label,
            "skills_directory": "skills",
            "default_prefix": "",
        }
        (work / "catalog.json").write_text(json.dumps(manifest, indent=2) + "\n")
        skill = work / "skills" / "common-skill"
        (skill / "scripts").mkdir(parents=True)
        (skill / "SKILL.md").write_text(
            "---\nname: common-skill\ndescription: A fixture skill.\n---\n\n" + body + "\n",
            encoding="utf-8",
        )
        helper = skill / "scripts" / "helper.sh"
        helper.write_text("#!/bin/sh\nprintf 'fixture\\n'\n", encoding="utf-8")
        runtime = work / "scripts"
        runtime.mkdir()
        shutil.copy2(INSTALLER, runtime / "team-skills.sh")
        shutil.copy2(ROOT / "scripts" / "team-skills-json.awk", runtime / "team-skills-json.awk")
        if executable_resource:
            helper.chmod(helper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.git("init", "--initial-branch=main", str(work))
        self.git("config", "user.name", "Installer Test", cwd=work)
        self.git("config", "user.email", "installer@example.invalid", cwd=work)
        self.git("add", ".", cwd=work)
        self.git("commit", "-m", "fixture catalog", cwd=work)
        self.git("init", "--bare", str(origin))
        self.git("remote", "add", "origin", str(origin), cwd=work)
        self.git("push", "-u", "origin", "main", cwd=work)
        self.git("symbolic-ref", "HEAD", "refs/heads/main", cwd=origin)
        return work, origin

    def run_installer(
        self, action: str, origin: Path | str, *extra: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["sh", str(INSTALLER), action, str(origin), *extra],
            text=True,
            capture_output=True,
            check=False,
            env=self.env,
        )

    def run_updater(self, action: str = "update-all", *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["sh", str(INSTALLER), action, *extra],
            text=True,
            capture_output=True,
            check=False,
            env=self.env,
        )

    def instance_root(self) -> Path:
        roots = list((self.state / "catalogs").iterdir())
        self.assertEqual(len(roots), 1)
        return roots[0]

    def read_hook_config(self, product: str) -> dict:
        paths = {
            "claude": self.home / ".claude" / "settings.json",
            "codex": self.home / ".codex" / "hooks.json",
            "cursor": self.home / ".cursor" / "hooks.json",
        }
        return json.loads(paths[product].read_text(encoding="utf-8"))

    def owned_hook_commands(self) -> dict[str, str]:
        instance = self.instance_root()
        return {
            product: (instance / "hooks" / f"{product}.owner")
            .read_text(encoding="utf-8")
            .splitlines()[1]
            for product in ("claude", "codex", "cursor")
        }

    def test_hook_registration_preserves_foreign_config_and_is_idempotent(self) -> None:
        _, origin = self.make_catalog("hooks", "# Hooks")
        claude_config = self.home / ".claude" / "settings.json"
        codex_config = self.home / ".codex" / "hooks.json"
        cursor_config = self.home / ".cursor" / "hooks.json"
        for path in (claude_config, codex_config, cursor_config):
            path.parent.mkdir(parents=True, exist_ok=True)
        claude_config.write_text(
            json.dumps(
                {
                    "permissions": {"allow": ["Read"]},
                    "hooks": {"PreToolUse": [{"hooks": [{"command": "foreign-claude"}]}]},
                }
            ),
            encoding="utf-8",
        )
        codex_config.write_text(
            json.dumps({"foreign": True, "hooks": {"Other": [{"command": "foreign-codex"}]}}),
            encoding="utf-8",
        )
        cursor_config.write_text(
            json.dumps(
                {
                    "version": 1,
                    "hooks": {
                        "sessionStart": [{"command": "foreign-cursor"}],
                        "workspaceOpen": [{"command": "keep-workspace"}],
                    },
                }
            ),
            encoding="utf-8",
        )

        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        commands = self.owned_hook_commands()
        claude = self.read_hook_config("claude")
        codex = self.read_hook_config("codex")
        cursor = self.read_hook_config("cursor")
        self.assertEqual(claude["permissions"], {"allow": ["Read"]})
        self.assertEqual(claude["hooks"]["PreToolUse"][0]["hooks"][0]["command"], "foreign-claude")
        self.assertEqual(claude["hooks"]["SessionStart"][0]["matcher"], "startup|clear")
        self.assertEqual(claude["hooks"]["SessionStart"][0]["hooks"][0]["command"], commands["claude"])
        self.assertTrue(claude["hooks"]["SessionStart"][0]["hooks"][0]["async"])
        self.assertTrue(codex["foreign"])
        self.assertEqual(codex["hooks"]["SessionStart"][0]["matcher"], "startup|clear")
        self.assertEqual(codex["hooks"]["SessionStart"][0]["hooks"][0]["command"], commands["codex"])
        self.assertEqual(cursor["hooks"]["workspaceOpen"], [{"command": "keep-workspace"}])
        self.assertEqual(
            cursor["hooks"]["sessionStart"],
            [{"command": "foreign-cursor"}, {"command": commands["cursor"]}],
        )

        repeated = self.run_installer("install", origin)
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        serialized = {
            product: json.dumps(self.read_hook_config(product), sort_keys=True)
            for product in ("claude", "codex", "cursor")
        }
        for product, command in commands.items():
            self.assertEqual(serialized[product].count(command), 1)

    def test_two_catalog_hook_entries_coexist_and_one_removal_is_exact(self) -> None:
        _, first_origin = self.make_catalog("first-hooks", "# First hooks")
        _, second_origin = self.make_catalog("second-hooks", "# Second hooks")
        cursor_config = self.home / ".cursor" / "hooks.json"
        cursor_config.parent.mkdir(parents=True)
        cursor_config.write_text(
            json.dumps({"hooks": {"sessionStart": [{"command": "foreign"}]}}),
            encoding="utf-8",
        )
        self.assertEqual(self.run_installer("install", first_origin).returncode, 0)
        self.assertEqual(
            self.run_installer("install", second_origin, "--prefix", "second").returncode,
            0,
        )
        instances = sorted((self.state / "catalogs").iterdir())
        commands = {
            instance.name: (instance / "hooks" / "cursor.owner")
            .read_text(encoding="utf-8")
            .splitlines()[1]
            for instance in instances
        }
        before = [entry["command"] for entry in self.read_hook_config("cursor")["hooks"]["sessionStart"]]
        self.assertEqual(before[0], "foreign")
        self.assertEqual(set(before[1:]), set(commands.values()))

        removed = self.run_installer("remove", first_origin)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        after = [entry["command"] for entry in self.read_hook_config("cursor")["hooks"]["sessionStart"]]
        self.assertEqual(after[0], "foreign")
        self.assertEqual(len(after), 2)
        self.assertIn(next(iter((self.state / "catalogs").iterdir())).name, after[1])
        for product in ("claude", "codex"):
            serialized = json.dumps(self.read_hook_config(product))
            self.assertNotIn(commands[[key for key in commands if key not in after[1]][0]], serialized)
            self.assertIn(after[1], serialized)

    def test_changed_owned_hook_refuses_removal_and_clean_retry_succeeds(self) -> None:
        _, origin = self.make_catalog("changed-hook", "# Hook ownership")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        cursor_path = self.home / ".cursor" / "hooks.json"
        original = cursor_path.read_bytes()
        cursor = json.loads(original)
        cursor["hooks"]["sessionStart"][0]["command"] += " changed"
        cursor_path.write_text(json.dumps(cursor), encoding="utf-8")

        refused = self.run_installer("remove", origin)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("no longer owned", refused.stderr)
        self.assertTrue((self.agents / "common-skill").is_symlink())
        self.assertTrue(self.instance_root().is_dir())

        cursor_path.write_bytes(original)
        retried = self.run_installer("remove", origin)
        self.assertEqual(retried.returncode, 0, retried.stderr)
        self.assertFalse((self.agents / "common-skill").exists())
        self.assertEqual(list((self.state / "catalogs").glob("*")), [])

    def test_malformed_hook_config_refuses_install_without_overwrite(self) -> None:
        _, origin = self.make_catalog("malformed-hooks", "# Hooks")
        claude_config = self.home / ".claude" / "settings.json"
        claude_config.parent.mkdir(parents=True)
        malformed = b'{"hooks":'
        claude_config.write_bytes(malformed)

        installed = self.run_installer("install", origin)
        self.assertNotEqual(installed.returncode, 0)
        self.assertIn("malformed, unsupported", installed.stderr)
        self.assertEqual(claude_config.read_bytes(), malformed)
        self.assertFalse((self.agents / "common-skill").exists())
        self.assertFalse((self.home / ".codex" / "hooks.json").exists())
        self.assertFalse((self.home / ".cursor" / "hooks.json").exists())

    def test_hook_command_quotes_metacharacter_and_unicode_state_path(self) -> None:
        self.state = self.base / "state 🧪 with '$dollar"
        self.env["TEAM_SKILLS_STATE_ROOT"] = str(self.state)
        _, origin = self.make_catalog("quoted-hooks", "# Hooks")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        command = self.owned_hook_commands()["claude"]
        self.assertIn("'\\''", command)
        self.env.update(
            {
                "TEAM_SKILLS_TEST_FOREGROUND": "1",
                "TEAM_SKILLS_NOW": "2000000000",
            }
        )
        invoked = subprocess.run(
            ["sh", "-c", command], text=True, capture_output=True, check=False, env=self.env
        )
        self.assertEqual(invoked.returncode, 0, invoked.stderr)
        self.assertTrue((self.instance_root() / "last-success").is_file())

    def test_two_origins_collision_prefix_idempotence_and_safe_remove(self) -> None:
        _, first_origin = self.make_catalog("first", "# First catalog")
        _, second_origin = self.make_catalog(
            "second", "# Second catalog", executable_resource=True
        )

        first = self.run_installer("install", first_origin)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_link = self.agents / "common-skill"
        self.assertTrue(first_link.is_symlink())
        self.assertIn("# First catalog", (first_link / "SKILL.md").read_text())

        repeated = self.run_installer("install", first_origin)
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(len(list((self.state / "catalogs").iterdir())), 1)
        generations = (
            next((self.state / "catalogs").iterdir())
            / "installs"
            / "_default"
            / "generations"
        )
        generation = next(generations.iterdir())
        self.assertEqual(
            sorted(path.relative_to(generation) for path in generation.rglob("*")),
            [
                Path("common-skill"),
                Path("common-skill/SKILL.md"),
                Path("common-skill/scripts"),
                Path("common-skill/scripts/helper.sh"),
            ],
        )

        collision = self.run_installer("install", second_origin)
        self.assertEqual(collision.returncode, 0, collision.stderr)
        self.assertIn("warning: catalog shared-catalog-id skill common-skill skipped", collision.stderr)
        self.assertIn("# First catalog", (first_link / "SKILL.md").read_text())
        self.assertEqual(len(list((self.state / "catalogs").iterdir())), 2)

        prefixed = self.run_installer("install", second_origin, "--prefix", "second")
        self.assertEqual(prefixed.returncode, 0, prefixed.stderr)
        prefixed_link = self.claude / "second-common-skill"
        self.assertTrue(prefixed_link.is_symlink())
        prefixed_text = (prefixed_link / "SKILL.md").read_text()
        self.assertIn("name: second-common-skill", prefixed_text)
        self.assertIn("# Second catalog", prefixed_text)
        helper_mode = (prefixed_link / "scripts" / "helper.sh").stat().st_mode
        self.assertTrue(helper_mode & stat.S_IXUSR)

        # A user replacement at an owned path revokes proof of ownership and survives removal.
        claude_first = self.claude / "common-skill"
        claude_first.unlink()
        claude_first.mkdir()
        marker = claude_first / "user-owned.txt"
        marker.write_bytes(b"preserve me byte-for-byte\n")
        removed = self.run_installer("remove", first_origin)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(first_link.exists())
        self.assertFalse(first_link.is_symlink())
        self.assertEqual(marker.read_bytes(), b"preserve me byte-for-byte\n")
        self.assertIn("not removing changed path", removed.stderr)
        self.assertTrue(prefixed_link.is_symlink())

    def test_invalid_fetched_catalog_retains_last_known_good_view(self) -> None:
        work, origin = self.make_catalog("update", "# Known good")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        exposed = self.agents / "common-skill" / "SKILL.md"
        original = exposed.read_bytes()

        skill_file = work / "skills" / "common-skill" / "SKILL.md"
        skill_file.write_text(
            skill_file.read_text(encoding="utf-8").replace(
                "name: common-skill", "name: mismatched-name"
            ),
            encoding="utf-8",
        )
        self.git("add", ".", cwd=work)
        self.git("commit", "-m", "malformed update", cwd=work)
        self.git("push", cwd=work)

        failed = self.run_installer("install", origin)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("keeping the last known-good installation", failed.stderr)
        self.assertEqual(exposed.read_bytes(), original)

    def test_configured_origin_can_change_without_changing_instance_ownership(self) -> None:
        _, initial_origin = self.make_catalog("initial", "# Initial origin")
        _, replacement_origin = self.make_catalog("replacement", "# Replacement origin")
        installed = self.run_installer("install", initial_origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)

        instance_roots = list((self.state / "catalogs").iterdir())
        self.assertEqual(len(instance_roots), 1)
        managed_repo = instance_roots[0] / "repo"
        self.git("remote", "set-url", "origin", str(replacement_origin), cwd=managed_repo)

        reconciled = self.run_installer("install", initial_origin)
        self.assertEqual(reconciled.returncode, 0, reconciled.stderr)
        self.assertIn(
            "# Replacement origin", (self.agents / "common-skill" / "SKILL.md").read_text()
        )
        self.assertEqual(list((self.state / "catalogs").iterdir()), instance_roots)

        removed = self.run_installer("remove", initial_origin)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(self.agents.joinpath("common-skill").exists())

    def test_failed_current_replacement_retains_last_known_good_view(self) -> None:
        work, origin = self.make_catalog("replacement", "# Known good")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        exposed = self.agents / "common-skill" / "SKILL.md"
        original = exposed.read_bytes()

        skill_file = work / "skills" / "common-skill" / "SKILL.md"
        skill_file.write_text(
            skill_file.read_text(encoding="utf-8").replace("# Known good", "# Candidate"),
            encoding="utf-8",
        )
        self.git("add", ".", cwd=work)
        self.git("commit", "-m", "valid candidate", cwd=work)
        self.git("push", cwd=work)

        command_bin = self.base / "injected command bin"
        command_bin.mkdir()
        real_mv = shutil.which("mv")
        self.assertIsNotNone(real_mv)
        mv_wrapper = command_bin / "mv"
        mv_wrapper.write_text(
            "#!/bin/sh\n"
            "last=\n"
            "for argument do last=$argument; done\n"
            "case $last in */current) exit 73 ;; esac\n"
            'exec "$TEAM_SKILLS_TEST_REAL_MV" "$@"\n',
            encoding="utf-8",
        )
        mv_wrapper.chmod(0o755)
        self.env["TEAM_SKILLS_TEST_REAL_MV"] = real_mv or ""
        self.env["PATH"] = str(command_bin) + os.pathsep + self.env["PATH"]

        failed = self.run_installer("install", origin)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("cannot activate generated view", failed.stderr)
        self.assertEqual(exposed.read_bytes(), original)
        install_root = next((self.state / "catalogs").iterdir()) / "installs" / "_default"
        self.assertEqual(list(install_root.glob(".current.*")), [])

    def test_racing_unrelated_destination_is_not_overwritten(self) -> None:
        work, origin = self.make_catalog("race", "# Known good")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        original = (self.agents / "common-skill" / "SKILL.md").read_bytes()

        common_skill = work / "skills" / "common-skill" / "SKILL.md"
        common_skill.write_text(
            common_skill.read_text(encoding="utf-8").replace("# Known good", "# Candidate"),
            encoding="utf-8",
        )
        new_skill = work / "skills" / "new-skill"
        new_skill.mkdir()
        (new_skill / "SKILL.md").write_text(
            "---\nname: new-skill\ndescription: A new fixture skill.\n---\n\n# New skill\n",
            encoding="utf-8",
        )
        self.git("add", ".", cwd=work)
        self.git("commit", "-m", "add a valid skill", cwd=work)
        self.git("push", cwd=work)

        command_bin = self.base / "racing command bin"
        command_bin.mkdir()
        real_ln = shutil.which("ln")
        self.assertIsNotNone(real_ln)
        ln_wrapper = command_bin / "ln"
        ln_wrapper.write_text(
            "#!/bin/sh\n"
            "last=\n"
            "for argument do last=$argument; done\n"
            "case $last in\n"
            "  */.agents/skills/new-skill)\n"
            "    printf 'race winner\\n' >\"$last\"\n"
            "    ;;\n"
            "esac\n"
            'exec "$TEAM_SKILLS_TEST_REAL_LN" "$@"\n',
            encoding="utf-8",
        )
        ln_wrapper.chmod(0o755)
        self.env["TEAM_SKILLS_TEST_REAL_LN"] = real_ln or ""
        original_path = self.env["PATH"]
        self.env["PATH"] = str(command_bin) + os.pathsep + self.env["PATH"]

        failed = self.run_installer("install", origin)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("cannot expose skill new-skill", failed.stderr)
        self.assertEqual((self.agents / "new-skill").read_bytes(), b"race winner\n")
        self.assertEqual((self.agents / "common-skill" / "SKILL.md").read_bytes(), original)
        ownership = (
            next((self.state / "catalogs").iterdir())
            / "installs"
            / "_default"
            / "ownership"
            / "agents"
            / "new-skill.owner"
        )
        self.assertFalse(ownership.exists())

        install_root = ownership.parents[2]
        current = install_root / "current"
        self.assertIn("# Known good", (current / "common-skill" / "SKILL.md").read_text())
        for product_root, product in ((self.agents, "agents"), (self.claude, "claude")):
            owner_file = install_root / "ownership" / product / "common-skill.owner"
            self.assertTrue(owner_file.is_file())
            self.assertEqual(os.readlink(product_root / "common-skill"), owner_file.read_text().strip())

        self.env["PATH"] = original_path
        (self.agents / "new-skill").unlink()
        rerun = self.run_installer("install", origin)
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertIn("# Candidate", (self.agents / "common-skill" / "SKILL.md").read_text())
        self.assertIn("# New skill", (self.claude / "new-skill" / "SKILL.md").read_text())

        removed = self.run_installer("remove", origin)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        for product_root in (self.agents, self.claude):
            self.assertFalse((product_root / "common-skill").exists())
            self.assertFalse((product_root / "new-skill").exists())

    def test_failed_first_install_removes_partial_catalog_exposures(self) -> None:
        work, origin = self.make_catalog("first-race", "# Initial")
        new_skill = work / "skills" / "new-skill"
        new_skill.mkdir()
        (new_skill / "SKILL.md").write_text(
            "---\nname: new-skill\ndescription: A new fixture skill.\n---\n\n# New skill\n",
            encoding="utf-8",
        )
        self.git("add", ".", cwd=work)
        self.git("commit", "-m", "add second initial skill", cwd=work)
        self.git("push", cwd=work)

        command_bin = self.base / "first install racing bin"
        command_bin.mkdir()
        real_ln = shutil.which("ln")
        self.assertIsNotNone(real_ln)
        ln_wrapper = command_bin / "ln"
        ln_wrapper.write_text(
            "#!/bin/sh\n"
            "last=\n"
            "for argument do last=$argument; done\n"
            "case $last in\n"
            "  */.agents/skills/new-skill)\n"
            "    printf 'first race winner\\n' >\"$last\"\n"
            "    ;;\n"
            "esac\n"
            'exec "$TEAM_SKILLS_TEST_REAL_LN" "$@"\n',
            encoding="utf-8",
        )
        ln_wrapper.chmod(0o755)
        self.env["TEAM_SKILLS_TEST_REAL_LN"] = real_ln or ""
        original_path = self.env["PATH"]
        self.env["PATH"] = str(command_bin) + os.pathsep + original_path

        failed = self.run_installer("install", origin)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("cannot expose skill new-skill", failed.stderr)
        self.assertEqual((self.agents / "new-skill").read_bytes(), b"first race winner\n")
        self.assertFalse((self.agents / "common-skill").exists())
        self.assertFalse((self.claude / "common-skill").exists())
        install_root = next((self.state / "catalogs").iterdir()) / "installs" / "_default"
        self.assertFalse((install_root / "current").exists())
        self.assertEqual(list((install_root / "ownership").rglob("*.owner")), [])

        self.env["PATH"] = original_path
        (self.agents / "new-skill").unlink()
        rerun = self.run_installer("install", origin)
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertTrue((self.agents / "common-skill").is_symlink())
        self.assertTrue((self.claude / "new-skill").is_symlink())

    def test_clone_failure_does_not_print_credentials(self) -> None:
        secret_url = "file://fixture-user:fixture-password@/definitely/missing/catalog.git"
        result = self.run_installer("install", secret_url)
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertNotIn("fixture-user", combined)
        self.assertNotIn("fixture-password", combined)
        self.assertIn("unable to clone the supplied repository", combined)

    def test_script_accepts_curl_style_standard_input_bootstrap(self) -> None:
        _, origin = self.make_catalog("stdin", "# Standard input bootstrap")
        result = subprocess.run(
            ["sh", "-s", "--", "install", str(origin)],
            input=INSTALLER.read_text(encoding="utf-8"),
            text=True,
            capture_output=True,
            check=False,
            env=self.env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "# Standard input bootstrap",
            (self.agents / "common-skill" / "SKILL.md").read_text(),
        )

    def test_invalid_root_fails_before_clone_or_mutation(self) -> None:
        self.env["TEAM_SKILLS_STATE_ROOT"] = "relative/state"
        result = self.run_installer("install", "/not/used")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be an absolute path", result.stderr)
        self.assertFalse((self.base / "relative").exists())

    def test_url_free_update_reconciles_every_installed_prefix(self) -> None:
        work, origin = self.make_catalog("all-prefixes", "# Initial")
        first = self.run_installer("install", origin)
        self.assertEqual(first.returncode, 0, first.stderr)
        prefixed = self.run_installer("install", origin, "--prefix", "fork")
        self.assertEqual(prefixed.returncode, 0, prefixed.stderr)

        skill_file = work / "skills" / "common-skill" / "SKILL.md"
        skill_file.write_text(
            skill_file.read_text(encoding="utf-8").replace("# Initial", "# Updated"),
            encoding="utf-8",
        )
        self.git("add", ".", cwd=work)
        self.git("commit", "-m", "update every view", cwd=work)
        self.git("push", cwd=work)

        self.env["TEAM_SKILLS_NOW"] = "2000000000"
        updated = self.run_updater()
        self.assertEqual(updated.returncode, 0, updated.stderr)
        self.assertIn("# Updated", (self.agents / "common-skill" / "SKILL.md").read_text())
        self.assertIn(
            "# Updated", (self.claude / "fork-common-skill" / "SKILL.md").read_text()
        )
        self.assertEqual((self.instance_root() / "last-success").read_text().strip(), "2000000000")

    def test_throttled_update_and_active_lock_do_not_fetch(self) -> None:
        _, origin = self.make_catalog("throttle", "# Initial")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        instance = self.instance_root()
        (instance / "last-success").write_text("2000000000\n", encoding="utf-8")
        self.git("remote", "set-url", "origin", str(self.base / "missing origin"), cwd=instance / "repo")

        self.env["TEAM_SKILLS_NOW"] = "2000000010"
        throttled = self.run_updater()
        self.assertEqual(throttled.returncode, 0, throttled.stderr)

        (instance / "last-success").unlink()
        lock = instance / "update.lock"
        lock.mkdir()
        (lock / "owner").write_text(f"{os.getpid()}\n2000000000\n", encoding="utf-8")
        locked = self.run_updater()
        self.assertEqual(locked.returncode, 0, locked.stderr)
        self.assertTrue(lock.is_dir())

    def test_stale_lock_recovers_conservatively(self) -> None:
        _, origin = self.make_catalog("stale", "# Initial")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        instance = self.instance_root()
        lock = instance / "update.lock"
        lock.mkdir()
        (lock / "owner").write_text("99999999\n100\n", encoding="utf-8")
        self.env.update(
            {
                "TEAM_SKILLS_NOW": "10000",
                "TEAM_SKILLS_STALE_LOCK_SECONDS": "1000",
                "TEAM_SKILLS_THROTTLE_SECONDS": "0",
            }
        )

        recovered = self.run_updater()
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertFalse(lock.exists())
        self.assertEqual((instance / "last-success").read_text().strip(), "10000")

    def test_hook_masks_failure_and_credential_safe_log_retains_known_good(self) -> None:
        _, origin = self.make_catalog("hook-failure", "# Known good")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        instance = self.instance_root()
        secret_origin = "file://fixture-user:fixture-password@/definitely/missing/catalog.git"
        self.git("remote", "set-url", "origin", secret_origin, cwd=instance / "repo")
        original = (self.agents / "common-skill" / "SKILL.md").read_bytes()
        self.env.update(
            {
                "TEAM_SKILLS_TEST_FOREGROUND": "1",
                "TEAM_SKILLS_THROTTLE_SECONDS": "0",
                "TEAM_SKILLS_NOW": "2000000000",
            }
        )

        hooked = self.run_updater("hook", instance.name)
        self.assertEqual(hooked.returncode, 0, hooked.stderr)
        log = (instance / "last-update.log").read_text(encoding="utf-8")
        self.assertIn("unable to fetch the managed catalog origin", log)
        self.assertNotIn("fixture-user", log)
        self.assertNotIn("fixture-password", log)
        self.assertEqual((self.agents / "common-skill" / "SKILL.md").read_bytes(), original)

    def test_changed_configured_origin_updates_without_bootstrap_url(self) -> None:
        _, initial_origin = self.make_catalog("url-free-initial", "# Initial")
        _, replacement_origin = self.make_catalog("url-free-replacement", "# Replacement")
        installed = self.run_installer("install", initial_origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        instance = self.instance_root()
        self.git("remote", "set-url", "origin", str(replacement_origin), cwd=instance / "repo")
        self.env["TEAM_SKILLS_THROTTLE_SECONDS"] = "0"

        updated = self.run_updater()
        self.assertEqual(updated.returncode, 0, updated.stderr)
        self.assertIn(
            "# Replacement", (self.agents / "common-skill" / "SKILL.md").read_text()
        )


if __name__ == "__main__":
    unittest.main()
