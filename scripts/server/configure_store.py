#!/usr/bin/env python3
"""Create or update the untracked Stripe/store environment safely."""

from __future__ import annotations

import argparse
import getpass
import os
import secrets
import stat
import sys
import tempfile
from pathlib import Path


DEFAULTS = {
    "SITE_ORIGIN": "https://keelanwatlington.com",
    "GLEAMINGS_SKU": "GLEAMINGS-EPUB-2026",
    "LONG_BEACH_SKU": "LONG-BEACH-EPUB-2026",
    "STORE_BIND": "127.0.0.1",
    "STORE_PORT": "8787",
    "DOWNLOAD_LINK_TTL": "600",
    "RECOVERY_LINK_TTL": "86400",
    "RECOVERY_RATE_WINDOW": "3600",
    "RECOVERY_EMAIL_LIMIT": "3",
    "RECOVERY_IP_LIMIT": "10",
}

OPTIONAL_EMAIL_KEYS = (
    "STORE_SMTP_HOST",
    "STORE_SMTP_PORT",
    "STORE_SMTP_SECURITY",
    "STORE_SMTP_USERNAME",
    "STORE_SMTP_PASSWORD",
    "STORE_SMTP_TIMEOUT",
    "STORE_EMAIL_FROM",
    "STORE_EMAIL_REPLY_TO",
)


def explain_stripe_recovery(site_origin: str) -> None:
    endpoint = f"{site_origin.rstrip('/')}/stripe/webhook"
    print(
        "\nStripe webhook setup is required for this clean installation.\n"
        "  1. Sign in to Stripe and select LIVE mode.\n"
        "  2. Open Workbench -> Webhooks.\n"
        f"  3. Select the destination for {endpoint}.\n"
        "  4. Reveal its Signing secret and paste the whsec_... value below.\n"
        "     This is not an sk_live_... or pk_live_... API key.\n"
        "\n"
        "If that destination is missing, create it with the URL above and subscribe it to:\n"
        "  - checkout.session.completed\n"
        "  - checkout.session.async_payment_succeeded\n"
        "You can also use the destination menu to roll a lost signing secret.\n"
        "\n"
        "Stripe retains its payment history, but without --state-backup this setup cannot\n"
        "reconstruct the wiped server's local order database or old download sessions.\n",
        file=sys.stderr,
    )


def read_environment(path: Path) -> tuple[list[str], dict[str, str]]:
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    values: dict[str, str] = {}
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        values[key] = value
    return lines, values


def write_environment(path: Path, original: list[str], values: dict[str, str]) -> bool:
    emitted: set[str] = set()
    output: list[str] = []
    for line in original:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0]
            if key in values:
                output.append(f"{key}={values[key]}")
                emitted.add(key)
                continue
        output.append(line)
    for key, value in values.items():
        if key not in emitted:
            output.append(f"{key}={value}")

    rendered = "\n".join(output).rstrip() + "\n"
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists() and path.read_text(encoding="utf-8") == rendered:
        if stat.S_IMODE(path.stat().st_mode) != 0o600:
            os.chmod(path, 0o600)
        return False

    descriptor, temporary_name = tempfile.mkstemp(prefix=".store.env.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(rendered)
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    return True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--site-root", type=Path, required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--site-origin", default=DEFAULTS["SITE_ORIGIN"])
    parser.add_argument("--non-interactive", action="store_true")
    args = parser.parse_args()

    original, values = read_environment(args.env_file)
    for key in OPTIONAL_EMAIL_KEYS:
        if key in os.environ:
            values[key] = os.environ[key]
    webhook_secrets = values.get("STRIPE_WEBHOOK_SECRETS", "") or os.environ.get(
        "STRIPE_WEBHOOK_SECRETS", ""
    )
    if not webhook_secrets:
        if args.non_interactive:
            parser.error("STRIPE_WEBHOOK_SECRETS is missing")
        explain_stripe_recovery(args.site_origin)
        webhook_secrets = getpass.getpass("Stripe webhook signing secret (whsec_...): ").strip()
    if any(not item.strip().startswith("whsec_") for item in webhook_secrets.split(",")):
        parser.error("every Stripe webhook signing secret must start with whsec_")

    download_secret = values.get("DOWNLOAD_SIGNING_SECRET", "") or os.environ.get(
        "DOWNLOAD_SIGNING_SECRET", ""
    )
    if len(download_secret) < 32:
        download_secret = secrets.token_urlsafe(48)

    for key, value in DEFAULTS.items():
        values.setdefault(key, value)
    smtp_host = values.get("STORE_SMTP_HOST", "").strip()
    smtp_from = values.get("STORE_EMAIL_FROM", "").strip()
    if bool(smtp_host) != bool(smtp_from):
        parser.error("STORE_SMTP_HOST and STORE_EMAIL_FROM must be supplied together")
    smtp_username = values.get("STORE_SMTP_USERNAME", "").strip()
    smtp_password = values.get("STORE_SMTP_PASSWORD", "")
    if bool(smtp_username) != bool(smtp_password):
        parser.error("STORE_SMTP_USERNAME and STORE_SMTP_PASSWORD must be supplied together")
    if smtp_host:
        values.setdefault("STORE_SMTP_SECURITY", "starttls")
        values.setdefault(
            "STORE_SMTP_PORT",
            "465" if values["STORE_SMTP_SECURITY"].lower() == "ssl" else "587",
        )
        values.setdefault("STORE_SMTP_TIMEOUT", "10")
    values.update({
        "STRIPE_WEBHOOK_SECRETS": webhook_secrets,
        "DOWNLOAD_SIGNING_SECRET": download_secret,
        "STORE_DATABASE": str(args.state_dir / "orders.sqlite3"),
        "GLEAMINGS_EPUB": str(args.site_root / "editions" / "gleamings" / "dist" / "Gleamings.epub"),
        "GLEAMINGS_PDF": str(args.site_root / "editions" / "gleamings" / "dist" / "Gleamings.pdf"),
        "LONG_BEACH_EPUB": str(args.site_root / "editions" / "long-beach" / "dist" / "Long-Beach.epub"),
        "LONG_BEACH_PDF": str(args.site_root / "editions" / "long-beach" / "dist" / "Long-Beach.pdf"),
        "SITE_ORIGIN": args.site_origin.rstrip("/"),
    })
    if not values["SITE_ORIGIN"].startswith("https://"):
        parser.error("--site-origin must use https")
    write_environment(args.env_file, original, values)


if __name__ == "__main__":
    main()
