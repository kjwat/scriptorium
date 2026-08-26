#!/usr/bin/env python3
"""Unit coverage for Scriptorium-owned website-server provisioning assets."""

from __future__ import annotations

import base64
import copy
import io
import json
import os
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SERVER_ROOT = REPOSITORY_ROOT / "scripts" / "server"
sys.path.insert(0, str(SERVER_ROOT))

from backup_server_state import backup_state  # noqa: E402
from configure_cloudflare_tunnel import (  # noqa: E402
    API_ROOT,
    CloudflareConfigurationError,
    decode_connector_token,
    merge_public_ingress,
    reconcile_from_connector_token,
    reconcile_public_hostname_dns,
    reconcile_public_ingress,
)
from configure_store import main as configure_store  # noqa: E402
from render_server_config import render, render_cloudflared_config  # noqa: E402


class ServerProvisioningTests(unittest.TestCase):
    CLOUDFLARE_TUNNEL_ID = "beb29759-dac7-43c9-a66d-36153e9b90fd"
    STALE_CLOUDFLARE_TUNNEL_ID = "e1d5fa1e-dc6a-4afe-bce1-6ad081190492"
    CLOUDFLARE_ACCOUNT_ID = "a" * 32

    @classmethod
    def cloudflare_connector_token(cls, tunnel_id: str | None = None) -> str:
        payload = {
            "a": cls.CLOUDFLARE_ACCOUNT_ID,
            "s": "fixture-tunnel-secret",
            "t": tunnel_id or cls.CLOUDFLARE_TUNNEL_ID,
        }
        return base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")

    def test_fresh_remote_tunnel_with_connector_but_no_hostnames_gets_ingress(
        self,
    ) -> None:
        calls: list[tuple[str, str, str, dict[str, object] | None]] = []
        existing_configuration = {
            "originRequest": {"connectTimeout": 30},
            "ingress": [{"service": "http_status:404"}],
        }

        def transport(method, url, api_token, payload):
            calls.append((method, url, api_token, copy.deepcopy(payload)))
            configuration = (
                existing_configuration if method == "GET" else payload["config"]
            )
            return {
                "success": True,
                "errors": [],
                "result": {
                    "account_id": self.CLOUDFLARE_ACCOUNT_ID,
                    "tunnel_id": self.CLOUDFLARE_TUNNEL_ID,
                    "config": copy.deepcopy(configuration),
                },
            }

        result = reconcile_public_ingress(
            decode_connector_token(self.cloudflare_connector_token()),
            "fixture-api-token",
            ["keelanwatlington.com", "www.keelanwatlington.com"],
            "http://localhost:8080",
            transport=transport,
        )

        self.assertTrue(result.changed)
        self.assertEqual([call[0] for call in calls], ["GET", "PUT"])
        expected_endpoint = (
            f"{API_ROOT}/accounts/{self.CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/"
            f"{self.CLOUDFLARE_TUNNEL_ID}/configurations"
        )
        self.assertTrue(all(call[1] == expected_endpoint for call in calls))
        updated = calls[1][3]["config"]
        self.assertEqual(updated["originRequest"], {"connectTimeout": 30})
        self.assertEqual(
            updated["ingress"][:2],
            [
                {
                    "hostname": "keelanwatlington.com",
                    "service": "http://localhost:8080",
                    "originRequest": {},
                },
                {
                    "hostname": "www.keelanwatlington.com",
                    "service": "http://localhost:8080",
                    "originRequest": {},
                },
            ],
        )
        self.assertEqual(updated["ingress"][-1], {"service": "http_status:404"})
        self.assertNotIn("dns_records", expected_endpoint)
        self.assertNotIn("routes", expected_endpoint)

    def test_ingress_merge_preserves_unrelated_public_rules_and_origin_settings(
        self,
    ) -> None:
        existing = {
            "originRequest": {"connectTimeout": 30},
            "ingress": [
                {
                    "hostname": "unrelated.example.com",
                    "service": "http://localhost:9000",
                    "originRequest": {"httpHostHeader": "unrelated.example.com"},
                },
                {"service": "http_status:503"},
            ],
        }
        merged, changed = merge_public_ingress(
            existing,
            ["keelanwatlington.com", "www.keelanwatlington.com"],
            "http://localhost:8080",
        )

        self.assertTrue(changed)
        self.assertEqual(merged["originRequest"], existing["originRequest"])
        self.assertEqual(merged["ingress"][0], existing["ingress"][0])
        self.assertEqual(merged["ingress"][-1], {"service": "http_status:503"})
        self.assertEqual(
            existing["ingress"],
            [
                {
                    "hostname": "unrelated.example.com",
                    "service": "http://localhost:9000",
                    "originRequest": {"httpHostHeader": "unrelated.example.com"},
                },
                {"service": "http_status:503"},
            ],
        )

    def test_remote_tunnel_ingress_reconciliation_is_idempotent(self) -> None:
        calls = []
        existing_configuration = {
            "ingress": [
                {
                    "hostname": "keelanwatlington.com",
                    "service": "http://localhost:8080",
                    "originRequest": {"disableChunkedEncoding": True},
                },
                {
                    "hostname": "www.keelanwatlington.com",
                    "service": "http://localhost:8080",
                },
                {"service": "http_status:404"},
            ]
        }

        def transport(method, url, api_token, payload):
            calls.append((method, payload))
            self.assertEqual(method, "GET")
            return {
                "success": True,
                "errors": [],
                "result": {"config": copy.deepcopy(existing_configuration)},
            }

        result = reconcile_public_ingress(
            decode_connector_token(self.cloudflare_connector_token()),
            "fixture-api-token",
            ["keelanwatlington.com", "www.keelanwatlington.com"],
            "http://localhost:8080",
            transport=transport,
        )

        self.assertFalse(result.changed)
        self.assertEqual(calls, [("GET", None)])

    def test_correct_ingress_with_stale_dns_tunnel_association_is_repaired(
        self,
    ) -> None:
        zone_id = "b" * 32
        target = f"{self.CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com"
        existing_configuration = {
            "ingress": [
                {
                    "hostname": "keelanwatlington.com",
                    "service": "http://localhost:8080",
                },
                {
                    "hostname": "www.keelanwatlington.com",
                    "service": "http://localhost:8080",
                },
                {"service": "http_status:404"},
            ]
        }
        records = {
            "keelanwatlington.com": {
                "id": "c" * 32,
                "zone_id": zone_id,
                "type": "CNAME",
                "name": "keelanwatlington.com",
                "content": f"{self.STALE_CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com",
                "proxied": True,
                "ttl": 1,
                "comment": "Cloudflare-managed tunnel route",
                "tags": ["owner:website"],
            },
            "www.keelanwatlington.com": {
                "id": "d" * 32,
                "zone_id": zone_id,
                "type": "CNAME",
                "name": "www.keelanwatlington.com",
                "content": f"{self.STALE_CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com",
                "proxied": False,
                "ttl": 300,
                "comment": "Keep this comment",
                "tags": ["environment:production"],
            },
            "mail.keelanwatlington.com": {
                "id": "e" * 32,
                "zone_id": zone_id,
                "type": "MX",
                "name": "mail.keelanwatlington.com",
                "content": "mail.example.net",
                "priority": 10,
            },
        }
        original_unrelated = copy.deepcopy(records["mail.keelanwatlington.com"])
        calls: list[tuple[str, str, dict[str, object] | None]] = []

        def transport(method, url, api_token, payload):
            self.assertEqual(api_token, "fixture-api-token")
            calls.append((method, url, copy.deepcopy(payload)))
            parsed = urlsplit(url)
            if parsed.path.endswith("/configurations"):
                self.assertEqual(method, "GET")
                return {
                    "success": True,
                    "errors": [],
                    "result": {
                        "account_id": self.CLOUDFLARE_ACCOUNT_ID,
                        "tunnel_id": self.CLOUDFLARE_TUNNEL_ID,
                        "config": copy.deepcopy(existing_configuration),
                    },
                }
            if parsed.path == "/client/v4/zones":
                self.assertEqual(method, "GET")
                self.assertEqual(
                    parse_qs(parsed.query),
                    {"name": ["keelanwatlington.com"], "per_page": ["50"]},
                )
                return {
                    "success": True,
                    "errors": [],
                    "result": [
                        {
                            "id": zone_id,
                            "name": "keelanwatlington.com",
                            "status": "active",
                            "account": {"id": self.CLOUDFLARE_ACCOUNT_ID},
                        }
                    ],
                    "result_info": {"total_count": 1, "total_pages": 1},
                }
            if parsed.path == f"/client/v4/zones/{zone_id}/dns_records":
                if method == "GET":
                    hostname = parse_qs(parsed.query)["name.exact"][0]
                    record = records.get(hostname)
                    return {
                        "success": True,
                        "errors": [],
                        "result": [] if record is None else [copy.deepcopy(record)],
                        "result_info": {
                            "total_count": 0 if record is None else 1,
                            "total_pages": 1,
                        },
                    }
                self.fail(f"unexpected collection method: {method}")
            prefix = f"/client/v4/zones/{zone_id}/dns_records/"
            if parsed.path.startswith(prefix):
                self.assertEqual(method, "PATCH")
                record_id = parsed.path.removeprefix(prefix)
                record = next(
                    record for record in records.values() if record["id"] == record_id
                )
                record.update(payload)
                return {
                    "success": True,
                    "errors": [],
                    "result": copy.deepcopy(record),
                }
            self.fail(f"unexpected Cloudflare endpoint: {method} {url}")

        first = reconcile_from_connector_token(
            self.cloudflare_connector_token(),
            "fixture-api-token",
            ["keelanwatlington.com", "www.keelanwatlington.com"],
            "http://localhost:8080",
            zone_name="keelanwatlington.com",
            expected_tunnel_id=self.CLOUDFLARE_TUNNEL_ID,
            transport=transport,
        )

        self.assertTrue(first.changed)
        self.assertFalse(first.ingress_changed)
        self.assertTrue(first.dns_changed)
        self.assertEqual(records["keelanwatlington.com"]["content"], target)
        self.assertTrue(records["keelanwatlington.com"]["proxied"])
        self.assertEqual(records["keelanwatlington.com"]["ttl"], 1)
        self.assertEqual(
            records["keelanwatlington.com"]["comment"],
            "Cloudflare-managed tunnel route",
        )
        self.assertEqual(records["keelanwatlington.com"]["tags"], ["owner:website"])
        self.assertEqual(records["www.keelanwatlington.com"]["content"], target)
        self.assertTrue(records["www.keelanwatlington.com"]["proxied"])
        self.assertEqual(records["www.keelanwatlington.com"]["ttl"], 300)
        self.assertEqual(
            records["www.keelanwatlington.com"]["comment"], "Keep this comment"
        )
        self.assertEqual(
            records["www.keelanwatlington.com"]["tags"],
            ["environment:production"],
        )
        self.assertEqual(records["mail.keelanwatlington.com"], original_unrelated)
        patch_calls = [call for call in calls if call[0] == "PATCH"]
        self.assertEqual(
            [call[2] for call in patch_calls],
            [
                {"content": target},
                {"content": target, "proxied": True},
            ],
        )
        self.assertFalse(any(call[0] == "PUT" for call in calls))
        self.assertFalse(any("/routes" in call[1] for call in calls))

        calls.clear()
        second = reconcile_from_connector_token(
            self.cloudflare_connector_token(),
            "fixture-api-token",
            ["keelanwatlington.com", "www.keelanwatlington.com"],
            "http://localhost:8080",
            zone_name="keelanwatlington.com",
            expected_tunnel_id=self.CLOUDFLARE_TUNNEL_ID,
            transport=transport,
        )
        self.assertFalse(second.changed)
        self.assertFalse(second.ingress_changed)
        self.assertFalse(second.dns_changed)
        self.assertTrue(all(call[0] == "GET" for call in calls))

    def test_missing_tunnel_dns_record_is_created_without_private_routes(
        self,
    ) -> None:
        identity = decode_connector_token(self.cloudflare_connector_token())
        zone_id = "b" * 32
        target = f"{self.CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com"
        record = None
        calls = []

        def transport(method, url, api_token, payload):
            nonlocal record
            calls.append((method, url, copy.deepcopy(payload)))
            parsed = urlsplit(url)
            if parsed.path == "/client/v4/zones":
                return {
                    "success": True,
                    "errors": [],
                    "result": [
                        {
                            "id": zone_id,
                            "name": "keelanwatlington.com",
                            "status": "active",
                            "account": {"id": self.CLOUDFLARE_ACCOUNT_ID},
                        }
                    ],
                }
            records_path = f"/client/v4/zones/{zone_id}/dns_records"
            if parsed.path == records_path and method == "GET":
                return {
                    "success": True,
                    "errors": [],
                    "result": [] if record is None else [copy.deepcopy(record)],
                }
            if parsed.path == records_path and method == "POST":
                record = {"id": "c" * 32, "zone_id": zone_id, **payload}
                return {
                    "success": True,
                    "errors": [],
                    "result": copy.deepcopy(record),
                }
            self.fail(f"unexpected Cloudflare endpoint: {method} {url}")

        changed = reconcile_public_hostname_dns(
            identity,
            "fixture-api-token",
            "keelanwatlington.com",
            ["www.keelanwatlington.com"],
            transport=transport,
        )

        self.assertTrue(changed)
        self.assertEqual(
            [call[2] for call in calls if call[0] == "POST"],
            [
                {
                    "type": "CNAME",
                    "name": "www.keelanwatlington.com",
                    "content": target,
                    "proxied": True,
                    "ttl": 1,
                }
            ],
        )
        self.assertFalse(any("/teamnet/" in call[1] for call in calls))
        self.assertFalse(any("/routes" in call[1] for call in calls))

    def test_dns_reconciliation_refuses_to_replace_non_cname_record(self) -> None:
        identity = decode_connector_token(self.cloudflare_connector_token())
        zone_id = "b" * 32
        calls = []

        def transport(method, url, api_token, payload):
            calls.append((method, url, copy.deepcopy(payload)))
            parsed = urlsplit(url)
            if parsed.path == "/client/v4/zones":
                return {
                    "success": True,
                    "errors": [],
                    "result": [
                        {
                            "id": zone_id,
                            "name": "keelanwatlington.com",
                            "status": "active",
                            "account": {"id": self.CLOUDFLARE_ACCOUNT_ID},
                        }
                    ],
                }
            return {
                "success": True,
                "errors": [],
                "result": [
                    {
                        "id": "c" * 32,
                        "zone_id": zone_id,
                        "type": "A",
                        "name": "www.keelanwatlington.com",
                        "content": "192.0.2.10",
                        "proxied": True,
                    }
                ],
            }

        with self.assertRaisesRegex(CloudflareConfigurationError, "non-CNAME"):
            reconcile_public_hostname_dns(
                identity,
                "fixture-api-token",
                "keelanwatlington.com",
                ["www.keelanwatlington.com"],
                transport=transport,
            )
        self.assertTrue(all(call[0] == "GET" for call in calls))

    def test_legacy_tunnel_only_token_reports_required_dns_permissions(self) -> None:
        identity = decode_connector_token(self.cloudflare_connector_token())

        with self.assertRaisesRegex(
            CloudflareConfigurationError,
            "Zone / Zone / Read.*Zone / DNS / Edit",
        ):
            reconcile_public_hostname_dns(
                identity,
                "legacy-tunnel-only-token",
                "keelanwatlington.com",
                ["keelanwatlington.com"],
                transport=lambda *_args: {
                    "success": True,
                    "errors": [],
                    "result": [],
                },
            )

    def test_connector_token_must_match_the_dns_target_tunnel(self) -> None:
        wrong_tunnel = "11111111-2222-4333-8444-555555555555"
        with self.assertRaisesRegex(CloudflareConfigurationError, "expected"):
            reconcile_from_connector_token(
                self.cloudflare_connector_token(wrong_tunnel),
                "fixture-api-token",
                ["keelanwatlington.com", "www.keelanwatlington.com"],
                "http://localhost:8080",
                zone_name="keelanwatlington.com",
                expected_tunnel_id=self.CLOUDFLARE_TUNNEL_ID,
                transport=lambda *_args: self.fail("wrong tunnel reached the API"),
            )

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
