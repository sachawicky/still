#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("hooks", Path(__file__).with_name("configure-focus-hooks.py"))
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)


class HooksTests(unittest.TestCase):
    def test_merge_preserves_and_is_idempotent(self):
        original = {"permissions": {"deny": ["secret"]}, "hooks": {"SessionStart": [{"hooks": [{"command": "existing"}]}]}}
        extra = hooks.additions("claude", Path("/Applications/Still.app/Contents/MacOS/Still"))
        result = hooks.merge(original, extra)
        self.assertEqual(result["permissions"], original["permissions"])
        self.assertEqual(len(result["hooks"]["SessionStart"]), 2)
        self.assertEqual(hooks.merge(result, extra), result)
        self.assertEqual(len(original["hooks"]["SessionStart"]), 1)

    def test_codex_permissions_are_explicit(self):
        self.assertNotIn("PermissionRequest", hooks.additions("codex", Path("/app")))
        self.assertIn("PermissionRequest", hooks.additions("codex", Path("/app"), True))

    def test_backup_dry_run_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "settings.json"
            old = b'{"hooks":{}, "custom":true}\n'
            path.write_bytes(old)
            extra = hooks.additions("claude", Path("/a path/app"))
            hooks.install(path, extra, False)
            self.assertEqual(path.read_bytes(), old)
            hooks.install(path, extra, True)
            self.assertTrue(json.loads(path.read_text())["custom"])
            self.assertEqual(next(Path(folder).glob("*.still-backup-*")).read_bytes(), old)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_invalid_and_symlink_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bad.json"
            path.write_text('{"hooks":[]}')
            with self.assertRaises(ValueError):
                hooks.install(path, hooks.additions("codex", Path("/app")), True)
            link = Path(folder) / "link.json"
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                hooks.install(link, {}, True)


unittest.main()
