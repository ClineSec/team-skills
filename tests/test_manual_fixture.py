from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "prepare-manual-verification.py"


class ManualFixtureTests(unittest.TestCase):
    def run_helper(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(HELPER), *arguments],
            text=True,
            capture_output=True,
            check=False,
            timeout=90,
        )

    def test_prepare_advance_failure_fixture_and_restore_are_disposable(self) -> None:
        with tempfile.TemporaryDirectory(prefix="team skills manual helper ") as temporary:
            parent = Path(temporary)
            fixture = parent / "new fixture"
            prepared = self.run_helper("prepare", str(fixture))
            self.assertEqual(prepared.returncode, 0, prepared.stderr)
            self.assertIn("Human Claude Code, Codex, Cursor, and WSL results remain PENDING", prepared.stdout)

            metadata = json.loads((fixture / "fixture.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["root"], str(fixture.resolve()))
            self.assertEqual(metadata["expected"]["human_results"], "PENDING")
            self.assertIn("PENDING", (fixture / "RESULTS.md").read_text(encoding="utf-8"))
            self.assertTrue((fixture / "home" / ".agents" / "skills" / "common-skill").exists())
            generated = fixture / "home" / ".claude" / "skills" / "second-common-skill" / "SKILL.md"
            self.assertIn("name: second-common-skill", generated.read_text(encoding="utf-8"))
            transcript = (fixture / "evidence" / "install-transcript.txt").read_text(
                encoding="utf-8"
            )
            self.assertIn(
                "warning: catalog manual-shared-catalog-id skill common-skill skipped", transcript
            )

            refused = self.run_helper("prepare", str(fixture))
            self.assertEqual(refused.returncode, 2)
            self.assertIn("refusing to prepare over an existing path", refused.stderr)

            advanced = self.run_helper("advance", str(fixture), "first", "verified-v2")
            self.assertEqual(advanced.returncode, 0, advanced.stderr)
            metadata = json.loads((fixture / "fixture.json").read_text(encoding="utf-8"))
            self.assertEqual(metadata["catalogs"]["first"]["marker"], "verified-v2")

            unreachable = self.run_helper("origin", str(fixture), "first", "unreachable")
            self.assertEqual(unreachable.returncode, 0, unreachable.stderr)
            instance_repo = Path(metadata["catalogs"]["first"]["instance"]) / "repo"
            configured = subprocess.run(
                ["git", "remote", "get-url", "origin"],
                cwd=instance_repo,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(configured.returncode, 0, configured.stderr)
            self.assertIn("manual-user:manual-secret", configured.stdout)

            restored = self.run_helper("origin", str(fixture), "first", "restore")
            self.assertEqual(restored.returncode, 0, restored.stderr)
            configured = subprocess.run(
                ["git", "remote", "get-url", "origin"],
                cwd=instance_repo,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(configured.stdout.strip(), metadata["catalogs"]["first"]["origin"])

            # The process environment and normal home remain outside the fixture helper's scope.
            self.assertNotEqual(Path(os.environ.get("HOME", parent)).resolve(), fixture / "home")


if __name__ == "__main__":
    unittest.main()
