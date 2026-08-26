#!/usr/bin/env python3
"""Unit coverage for Scriptorium-owned website-server provisioning assets."""

from __future__ import annotations

import io
import os
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SERVER_ROOT = REPOSITORY_ROOT / "scripts" / "server"
sys.path.insert(0, str(SERVER_ROOT))

from backup_server_state import backup_state  # noqa: E402
from configure_store import main as configure_store  # noqa: E402
from render_server_config import render, render_cloudflared_config  # noqa: E402


class ServerProvisioningTests(unittest.TestCase):
    def test_state_backup_is_private_and_sqlite_consistent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = root / "store.env"
            database = root / "orders.sqlite3"
            cloudflared = root / "cloudflared.yml"
            credentials = root / "tunnel.json"
            output = root / "backup"
            environment.write_text(
                "STRIPE_WEBHOOK_SECRETS=whsec_fixture\n", encoding="utf-8"
            )
            credentials.write_text('{"TunnelID":"fixture"}\n', encoding="utf-8")
            cloudflared.write_text(
                "tunnel: fixture\n"
                f"credentials-file: {credentials}\n"
                "ingress:\n"
                "  - service: http://localhost:8080\n",
                encoding="utf-8",
            )
            connection = sqlite3.connect(database)
            connection.execute("CREATE TABLE orders (id TEXT PRIMARY KEY)")
            connection.execute("INSERT INTO orders VALUES ('one')")
            connection.commit()

            backup_state(
                output,
                environment=environment,
                database=database,
                cloudflared_config=cloudflared,
            )
            connection.close()

            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            for protected in (
                output / "store.env",
                output / "orders.sqlite3",
                output / "cloudflared" / "config.yml",
                output / "cloudflared" / "credentials.json",
            ):
                self.assertEqual(protected.stat().st_mode & 0o777, 0o600)
            copied = sqlite3.connect(output / "orders.sqlite3")
            try:
                self.assertEqual(
                    copied.execute("SELECT id FROM orders").fetchone(), ("one",)
                )
            finally:
                copied.close()

    def test_store_configuration_accepts_secrets_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ,
            {
                "STRIPE_WEBHOOK_SECRETS": "whsec_from_environment",
                "DOWNLOAD_SIGNING_SECRET": "d" * 48,
                "STORE_SMTP_HOST": "smtp.example.com",
                "STORE_SMTP_USERNAME": "books@example.com",
                "STORE_SMTP_PASSWORD": "smtp-token",
                "STORE_EMAIL_FROM": "Books <books@example.com>",
            },
            clear=False,
        ), patch(
            "sys.argv",
            [
                "configure_store.py",
                "--env-file",
                f"{directory}/store.env",
                "--site-root",
                f"{directory}/website",
                "--state-dir",
                f"{directory}/state",
                "--non-interactive",
            ],
        ):
            configure_store()
            environment = Path(directory, "store.env")
            inode = environment.stat().st_ino
            configured = environment.read_text(encoding="utf-8")
            self.assertIn("STRIPE_WEBHOOK_SECRETS=whsec_from_environment", configured)
            self.assertIn("STORE_SMTP_PASSWORD=smtp-token", configured)
            self.assertEqual(environment.stat().st_mode & 0o777, 0o600)
            configure_store()
            self.assertEqual(environment.stat().st_ino, inode)

    def test_clean_install_explains_how_to_recover_stripe_secret(self) -> None:
        with tempfile.TemporaryDirectory() as directory, patch.dict(
            os.environ,
            {},
            clear=True,
        ), patch(
            "sys.argv",
            [
                "configure_store.py",
                "--env-file",
                f"{directory}/store.env",
                "--site-root",
                f"{directory}/website",
                "--state-dir",
                f"{directory}/state",
            ],
        ), patch(
            "configure_store.getpass.getpass",
            return_value="whsec_recovered",
        ), patch(
            "sys.stderr",
            new_callable=io.StringIO,
        ) as stderr:
            configure_store()

            instructions = stderr.getvalue()
            self.assertIn("select LIVE mode", instructions)
            self.assertIn("Workbench -> Webhooks", instructions)
            self.assertIn("https://keelanwatlington.com/stripe/webhook", instructions)
            self.assertIn("Reveal its Signing secret", instructions)
            self.assertIn("checkout.session.completed", instructions)
            self.assertIn("checkout.session.async_payment_succeeded", instructions)
            self.assertIn("local order database", instructions)

    def test_rendering_covers_every_service_manager_without_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            paths = render(
                output,
                site_root=Path("/home/example/website"),
                home=Path("/home/example"),
                user="example",
                group="example",
                site_address=":8080",
            )
            names = {path.name for path in paths}
            contents = "\n".join(
                path.read_text(encoding="utf-8") for path in paths
            )
            shell_files = [
                path
                for path in paths
                if path.name.startswith(("launcher-", "openrc-", "runit-", "freebsd-"))
            ]
            subprocess.run(["sh", "-n", *map(str, shell_files)], check=True)
            for path in paths:
                if path.name.startswith("launchd-"):
                    plistlib.loads(path.read_bytes())

        for manager in ("openrc", "runit", "freebsd", "launchd"):
            self.assertEqual(sum(name.startswith(f"{manager}-") for name in names), 4)
        self.assertIn("--token-file /etc/cloudflared/keelanwatlington.token", contents)
        self.assertNotIn("whsec_", contents)
        self.assertNotRegex(contents, r"@[A-Z][A-Z0-9_]*@")

    def test_local_tunnel_restore_rehomes_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory, "source.yml")
            output = Path(directory, "output.yml")
            source.write_text(
                "tunnel: fixture\n"
                "credentials-file: /home/old/.cloudflared/fixture.json\n",
                encoding="utf-8",
            )
            render_cloudflared_config(
                source,
                output,
                credentials_file=Path(
                    "/etc/cloudflared/keelanwatlington-credentials.json"
                ),
            )
            restored = output.read_text(encoding="utf-8")
            self.assertIn(
                "credentials-file: /etc/cloudflared/keelanwatlington-credentials.json",
                restored,
            )
            self.assertNotIn("/home/old", restored)

    def test_caddy_configuration_is_owned_and_blocks_private_payload(self) -> None:
        caddyfile = (SERVER_ROOT / "Caddyfile.production").read_text(
            encoding="utf-8"
        )
        self.assertIn("root * {$SITE_ROOT}", caddyfile)
        self.assertIn("/.git*", caddyfile)
        self.assertIn("/tools/*", caddyfile)
        self.assertIn("/editions/*", caddyfile)
        self.assertIn("/stripe/webhook", caddyfile)


if __name__ == "__main__":
    unittest.main()
