#!/usr/bin/env python3
"""Render systemd and portable service definitions for one website checkout."""

from __future__ import annotations

import argparse
import grp
import html
import os
import pwd
import re
import shlex
from pathlib import Path


SERVER_ROOT = Path(__file__).resolve().parent
TEMPLATE_DIR = SERVER_ROOT / "templates"
SYSTEMD_TEMPLATES = {
    "caddy.service.conf": "caddy.service.conf.in",
    "cloudflared-token.service": "cloudflared.service.in",
    "cloudflared-local.service": "cloudflared-local.service.in",
    "keelanwatlington-store.service": "keelanwatlington-store.service.in",
    "keelanwatlington-blog-sync.service": "keelanwatlington-blog-sync.service.in",
    "keelanwatlington-blog-sync.timer": "keelanwatlington-blog-sync.timer",
}
LAUNCHER_TEMPLATES = {
    "launcher-caddy": "caddy-launcher.sh.in",
    "launcher-store": "store-launcher.sh.in",
    "launcher-blog": "blog-launcher.sh.in",
    "launcher-cloudflared-token": "cloudflared-token-launcher.sh.in",
    "launcher-cloudflared-local": "cloudflared-local-launcher.sh.in",
}
PORTABLE_SERVICES = (
    (
        "caddy",
        "keelanwatlington-caddy",
        "keelanwatlington_caddy",
        "com.keelanwatlington.caddy",
        "Keelan Watlington website origin",
        True,
    ),
    (
        "store",
        "keelanwatlington-store",
        "keelanwatlington_store",
        "com.keelanwatlington.store",
        "Keelan Watlington digital-store fulfillment",
        True,
    ),
    (
        "blog",
        "keelanwatlington-blog-sync",
        "keelanwatlington_blog_sync",
        "com.keelanwatlington.blog-sync",
        "Keelan Watlington Substack synchronization",
        True,
    ),
    (
        "cloudflared",
        "keelanwatlington-cloudflared",
        "keelanwatlington_cloudflared",
        "com.keelanwatlington.cloudflared",
        "Cloudflare Tunnel for keelanwatlington.com",
        False,
    ),
)
MARKER = re.compile(r"@[A-Z][A-Z0-9_]*@")
PORTABLE_LAUNCHER_ROOT = Path("/usr/local/libexec/keelanwatlington")


def render_cloudflared_config(
    source: Path,
    output: Path,
    *,
    credentials_file: Path,
) -> None:
    lines = source.read_text(encoding="utf-8").splitlines()
    replaced = 0
    rendered: list[str] = []
    for line in lines:
        key, separator, _value = line.strip().partition(":")
        if separator and key == "credentials-file":
            indentation = line[: len(line) - len(line.lstrip())]
            rendered.append(f"{indentation}credentials-file: {credentials_file}")
            replaced += 1
        else:
            rendered.append(line)
    if replaced != 1:
        raise RuntimeError(
            f"expected one credentials-file entry in {source}, found {replaced}"
        )
    output.write_text("\n".join(rendered).rstrip() + "\n", encoding="utf-8")


def account_group(user: str) -> str:
    account = pwd.getpwnam(user)
    return grp.getgrgid(account.pw_gid).gr_name


def substitute(template_name: str, values: dict[str, str]) -> str:
    text = (TEMPLATE_DIR / template_name).read_text(encoding="utf-8")
    for marker, value in values.items():
        text = text.replace(marker, value)
    unresolved = MARKER.search(text)
    if unresolved:
        raise RuntimeError(
            f"unresolved template marker {unresolved.group()} in {template_name}"
        )
    return text


def write_rendered(output: Path, text: str) -> Path:
    output.write_text(text, encoding="utf-8")
    return output


def render(
    output_directory: Path,
    *,
    site_root: Path,
    home: Path,
    user: str,
    group: str,
    site_address: str,
    python_bin: Path = Path("/usr/bin/python3"),
    caddy_bin: Path = Path("/usr/bin/caddy"),
    cloudflared_bin: Path = Path("/usr/bin/cloudflared"),
    cloudflared_token_file: Path = Path("/etc/cloudflared/keelanwatlington.token"),
) -> list[Path]:
    for label, path in (
        ("site root", site_root),
        ("home", home),
        ("Python", python_bin),
        ("Caddy", caddy_bin),
        ("cloudflared", cloudflared_bin),
    ):
        if not path.is_absolute():
            raise ValueError(f"{label} path must be absolute: {path}")

    config_dir = home / ".config" / "keelanwatlington"
    state_dir = home / ".local" / "state" / "keelanwatlington-store"
    environment_file = config_dir / "store.env"
    values = {
        "@SITE_ROOT@": str(site_root),
        "@SITE_USER@": user,
        "@SITE_GROUP@": group,
        "@SITE_ADDRESS@": site_address,
        "@CONFIG_DIR@": str(config_dir),
        "@STATE_DIR@": str(state_dir),
        "@PYTHON_BIN@": str(python_bin),
        "@CADDY_BIN@": str(caddy_bin),
        "@CLOUDFLARED_BIN@": str(cloudflared_bin),
        "@CLOUDFLARED_TOKEN_FILE@": str(cloudflared_token_file),
        "@HOME_ENV@": shlex.quote(f"HOME={home}"),
        "@XDG_CONFIG_ENV@": shlex.quote(f"XDG_CONFIG_HOME={home / '.config'}"),
        "@XDG_DATA_ENV@": shlex.quote(f"XDG_DATA_HOME={home / '.local' / 'share'}"),
        "@SITE_ROOT_ENV@": shlex.quote(f"SITE_ROOT={site_root}"),
        "@SITE_ADDRESS_ENV@": shlex.quote(f"SITE_ADDRESS={site_address}"),
        "@PYTHON_BIN_Q@": shlex.quote(str(python_bin)),
        "@CADDY_BIN_Q@": shlex.quote(str(caddy_bin)),
        "@CLOUDFLARED_BIN_Q@": shlex.quote(str(cloudflared_bin)),
        "@CLOUDFLARED_TOKEN_FILE_Q@": shlex.quote(str(cloudflared_token_file)),
        "@RUN_STORE_Q@": shlex.quote(str(site_root / "tools" / "run_store.py")),
        "@ENV_FILE_Q@": shlex.quote(str(environment_file)),
        "@STORE_PROGRAM_Q@": shlex.quote(
            str(site_root / "tools" / "store_fulfillment.py")
        ),
        "@SYNC_BLOG_Q@": shlex.quote(str(site_root / "tools" / "sync_blog.sh")),
    }

    output_directory.mkdir(parents=True, exist_ok=True)
    rendered: list[Path] = []
    for output_name, template_name in SYSTEMD_TEMPLATES.items():
        rendered.append(
            write_rendered(
                output_directory / output_name,
                substitute(template_name, values),
            )
        )
    for output_name, template_name in LAUNCHER_TEMPLATES.items():
        rendered.append(
            write_rendered(
                output_directory / output_name,
                substitute(template_name, values),
            )
        )

    generic_templates = {
        "openrc": "portable.openrc.in",
        "runit": "portable.runit.in",
        "freebsd": "portable.freebsd.in",
        "launchd": "portable.launchd.plist.in",
    }
    for key, service_name, rc_name, label, description, run_as_user in PORTABLE_SERVICES:
        launcher = PORTABLE_LAUNCHER_ROOT / key
        service_values = values | {
            "@DESCRIPTION@": description,
            "@LAUNCHER@": str(launcher),
            "@COMMAND_USER_LINE@": (
                f'command_user="{user}:{group}"' if run_as_user else "# Runs as root."
            ),
            "@RUN_PREFIX@": (
                f"chpst -u {shlex.quote(user + ':' + group)} " if run_as_user else ""
            ),
            "@RC_NAME@": rc_name,
            "@DAEMON_USER_ARG@": (
                f"-u {shlex.quote(user)} " if run_as_user else ""
            ),
            "@LABEL@": label,
            "@LAUNCHER_XML@": html.escape(str(launcher)),
            "@USER_XML@": (
                f"<key>UserName</key>\n  <string>{html.escape(user)}</string>"
                if run_as_user
                else "<!-- Runs as root. -->"
            ),
        }
        output_names = {
            "openrc": f"openrc-{service_name}",
            "runit": f"runit-{service_name}.run",
            "freebsd": f"freebsd-{rc_name}",
            "launchd": f"launchd-{label}.plist",
        }
        for manager, template_name in generic_templates.items():
            rendered.append(
                write_rendered(
                    output_directory / output_names[manager],
                    substitute(template_name, service_values),
                )
            )
    return rendered


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--site-root", type=Path, required=True)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--user", default=os.environ.get("USER", ""))
    parser.add_argument("--group")
    parser.add_argument("--site-address", default=":8080")
    parser.add_argument("--python-bin", type=Path, default=Path("/usr/bin/python3"))
    parser.add_argument("--caddy-bin", type=Path, default=Path("/usr/bin/caddy"))
    parser.add_argument(
        "--cloudflared-bin", type=Path, default=Path("/usr/bin/cloudflared")
    )
    parser.add_argument(
        "--cloudflared-token-file",
        type=Path,
        default=Path("/etc/cloudflared/keelanwatlington.token"),
    )
    parser.add_argument("--cloudflared-local-config", type=Path)
    parser.add_argument(
        "--cloudflared-local-credentials-file",
        type=Path,
        default=Path("/etc/cloudflared/keelanwatlington-credentials.json"),
    )
    args = parser.parse_args()

    if not args.user:
        parser.error("--user is required when USER is unset")
    if any(character.isspace() for character in args.site_address):
        parser.error("site address cannot contain whitespace")

    try:
        render(
            args.output,
            site_root=args.site_root,
            home=args.home,
            user=args.user,
            group=args.group or account_group(args.user),
            site_address=args.site_address,
            python_bin=args.python_bin,
            caddy_bin=args.caddy_bin,
            cloudflared_bin=args.cloudflared_bin,
            cloudflared_token_file=args.cloudflared_token_file,
        )
        if args.cloudflared_local_config:
            render_cloudflared_config(
                args.cloudflared_local_config,
                args.output / "cloudflared-config.yml",
                credentials_file=args.cloudflared_local_credentials_file,
            )
    except (RuntimeError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
