#!/usr/bin/env python3
"""Create a protected, consistent backup of machine-local website state."""

from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
import tempfile
from pathlib import Path


DEFAULT_ENV = Path.home() / ".config" / "keelanwatlington" / "store.env"
DEFAULT_DATABASE = (
    Path.home() / ".local" / "state" / "keelanwatlington-store" / "orders.sqlite3"
)
DEFAULT_CLOUDFLARED_CONFIG = Path("/etc/cloudflared/config.yml")


def cloudflared_credentials_path(config: Path) -> Path | None:
    for line in config.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.strip().partition(":")
        if separator and key == "credentials-file":
            credential = Path(value.strip().strip("'\"")).expanduser()
            if not credential.is_absolute():
                credential = config.parent / credential
            return credential
    return None


def backup_state(
    output: Path,
    *,
    environment: Path = DEFAULT_ENV,
    database: Path = DEFAULT_DATABASE,
    cloudflared_config: Path | None = DEFAULT_CLOUDFLARED_CONFIG,
) -> None:
    if output.exists():
        raise FileExistsError(f"refusing to overwrite existing path: {output}")
    if not environment.is_file():
        raise FileNotFoundError(f"store environment is missing: {environment}")

    output_parent = output.parent.resolve()
    output_parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".website-state.", dir=output_parent))
    os.chmod(staging, 0o700)
    try:
        environment_copy = staging / "store.env"
        shutil.copyfile(environment, environment_copy)
        os.chmod(environment_copy, 0o600)

        if database.is_file():
            database_copy = staging / "orders.sqlite3"
            source = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
            destination = sqlite3.connect(database_copy)
            try:
                source.backup(destination)
                result = destination.execute("PRAGMA quick_check").fetchone()
                if not result or result[0] != "ok":
                    raise RuntimeError("order database backup failed integrity validation")
            finally:
                destination.close()
                source.close()
            os.chmod(database_copy, 0o600)

        if cloudflared_config is not None and cloudflared_config.is_file():
            credentials = cloudflared_credentials_path(cloudflared_config)
            if credentials is not None:
                if not credentials.is_file():
                    raise FileNotFoundError(
                        f"Cloudflare tunnel credentials are missing: {credentials}"
                    )
                cloudflared_copy = staging / "cloudflared"
                cloudflared_copy.mkdir(mode=0o700)
                shutil.copyfile(cloudflared_config, cloudflared_copy / "config.yml")
                shutil.copyfile(credentials, cloudflared_copy / "credentials.json")
                os.chmod(cloudflared_copy / "config.yml", 0o600)
                os.chmod(cloudflared_copy / "credentials.json", 0o600)

        os.replace(staging, output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--store-env", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--orders-db", type=Path, default=DEFAULT_DATABASE)
    parser.add_argument(
        "--cloudflared-config",
        type=Path,
        default=DEFAULT_CLOUDFLARED_CONFIG,
        help="locally managed tunnel config to include when present",
    )
    args = parser.parse_args()

    backup_state(
        args.output.expanduser(),
        environment=args.store_env.expanduser(),
        database=args.orders_db.expanduser(),
        cloudflared_config=args.cloudflared_config.expanduser(),
    )
    print(f"website server state backed up to {args.output.expanduser()}")


if __name__ == "__main__":
    main()
