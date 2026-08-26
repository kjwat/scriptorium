#!/usr/bin/env python3
"""Reconcile ingress and public DNS for a remotely managed Cloudflare Tunnel."""

from __future__ import annotations

import argparse
import base64
import copy
import json
import re
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlencode, urlsplit


API_ROOT = "https://api.cloudflare.com/client/v4"
MAX_RESPONSE_BYTES = 2 * 1024 * 1024


class CloudflareConfigurationError(RuntimeError):
    """Raised when tunnel identity, configuration, or an API response is invalid."""


@dataclass(frozen=True)
class TunnelIdentity:
    account_id: str
    tunnel_id: str


@dataclass(frozen=True)
class ReconcileResult:
    changed: bool
    identity: TunnelIdentity
    ingress_changed: bool = False
    dns_changed: bool = False


Transport = Callable[[str, str, str, dict[str, Any] | None], dict[str, Any]]


def decode_connector_token(token: str) -> TunnelIdentity:
    """Extract the non-secret account and tunnel identifiers from a run token."""

    encoded = token.strip()
    if not encoded or any(character.isspace() for character in encoded):
        raise CloudflareConfigurationError(
            "Cloudflare connector token is empty or contains whitespace"
        )
    try:
        padding = "=" * (-len(encoded) % 4)
        decoded = base64.b64decode(
            encoded + padding,
            altchars=b"-_",
            validate=True,
        )
        payload = json.loads(decoded)
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise CloudflareConfigurationError(
            "Cloudflare connector token is not valid base64-encoded JSON"
        ) from error
    if not isinstance(payload, dict):
        raise CloudflareConfigurationError(
            "Cloudflare connector token payload is not an object"
        )

    account_id = payload.get("a")
    tunnel_id = payload.get("t")
    tunnel_secret = payload.get("s")
    if not isinstance(account_id, str) or not re.fullmatch(
        r"[0-9a-fA-F]{32}", account_id
    ):
        raise CloudflareConfigurationError(
            "Cloudflare connector token has no valid account ID"
        )
    if not isinstance(tunnel_secret, str) or not tunnel_secret:
        raise CloudflareConfigurationError("Cloudflare connector token has no tunnel secret")
    try:
        canonical_tunnel_id = str(uuid.UUID(str(tunnel_id)))
    except (ValueError, TypeError, AttributeError) as error:
        raise CloudflareConfigurationError(
            "Cloudflare connector token has no valid tunnel UUID"
        ) from error
    return TunnelIdentity(account_id=account_id.lower(), tunnel_id=canonical_tunnel_id)


def validate_api_token(token: str) -> str:
    token = token.strip()
    if not token or any(character.isspace() for character in token):
        raise CloudflareConfigurationError(
            "Cloudflare API token is empty or contains whitespace"
        )
    return token


def validate_hostname(hostname: str) -> str:
    hostname = hostname.rstrip(".").lower()
    if len(hostname) > 253 or not hostname:
        raise CloudflareConfigurationError(f"invalid public hostname: {hostname!r}")
    labels = hostname.split(".")
    if any(
        not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in labels
    ):
        raise CloudflareConfigurationError(f"invalid public hostname: {hostname!r}")
    return hostname


def validate_local_service(service: str) -> str:
    try:
        parsed = urlsplit(service)
        port = parsed.port
    except ValueError as error:
        raise CloudflareConfigurationError(
            f"invalid local tunnel service: {service!r}"
        ) from error
    if (
        parsed.scheme != "http"
        or parsed.hostname != "localhost"
        or parsed.username is not None
        or parsed.password is not None
        or port is None
        or not 1 <= port <= 65535
        or parsed.path
        or parsed.query
        or parsed.fragment
    ):
        raise CloudflareConfigurationError(
            "public tunnel service must be an http://localhost:PORT origin"
        )
    return f"http://localhost:{port}"


def _normalized_rule_hostname(rule: dict[str, Any]) -> str | None:
    hostname = rule.get("hostname")
    if not isinstance(hostname, str) or not hostname:
        return None
    return hostname.rstrip(".").lower()


def merge_public_ingress(
    configuration: dict[str, Any],
    hostnames: list[str],
    service: str,
) -> tuple[dict[str, Any], bool]:
    """Return a configuration with effective host-only rules for every hostname."""

    if not isinstance(configuration, dict):
        raise CloudflareConfigurationError(
            "Cloudflare tunnel configuration is not an object"
        )
    desired_hostnames = [validate_hostname(hostname) for hostname in hostnames]
    if len(set(desired_hostnames)) != len(desired_hostnames):
        raise CloudflareConfigurationError("duplicate public hostname requested")
    desired_service = validate_local_service(service)

    merged = copy.deepcopy(configuration)
    raw_ingress = merged.get("ingress", [])
    if raw_ingress is None:
        raw_ingress = []
    if not isinstance(raw_ingress, list) or any(
        not isinstance(rule, dict) for rule in raw_ingress
    ):
        raise CloudflareConfigurationError(
            "Cloudflare tunnel ingress is not a list of objects"
        )
    ingress: list[dict[str, Any]] = raw_ingress
    changed = "ingress" not in merged or merged.get("ingress") is None

    catch_all_index = next(
        (
            index
            for index, rule in enumerate(ingress)
            if _normalized_rule_hostname(rule) is None
        ),
        len(ingress),
    )
    matched: set[str] = set()
    for rule in ingress[:catch_all_index]:
        hostname = _normalized_rule_hostname(rule)
        if (
            hostname in desired_hostnames
            and not rule.get("path")
            and hostname not in matched
        ):
            matched.add(hostname)
            if rule.get("service") != desired_service:
                rule["service"] = desired_service
                changed = True

    additions = [
        {
            "hostname": hostname,
            "service": desired_service,
            "originRequest": {},
        }
        for hostname in desired_hostnames
        if hostname not in matched
    ]
    if additions:
        ingress[catch_all_index:catch_all_index] = additions
        changed = True

    if not any(_normalized_rule_hostname(rule) is None for rule in ingress):
        ingress.append({"service": "http_status:404"})
        changed = True

    merged["ingress"] = ingress
    return merged, changed


def _response_error(response: dict[str, Any], action: str) -> CloudflareConfigurationError:
    messages = []
    for item in response.get("errors", []):
        if isinstance(item, dict) and item.get("message"):
            messages.append(str(item["message"]))
    detail = "; ".join(messages) or "Cloudflare returned an unsuccessful response"
    return CloudflareConfigurationError(f"could not {action}: {detail}")


def _configuration_from_response(
    response: dict[str, Any],
    identity: TunnelIdentity,
    action: str,
) -> tuple[dict[str, Any], bool]:
    if not isinstance(response, dict) or response.get("success") is not True:
        if not isinstance(response, dict):
            raise CloudflareConfigurationError(
                f"could not {action}: response is not an object"
            )
        raise _response_error(response, action)
    result = response.get("result")
    if result is None:
        return {}, False
    if not isinstance(result, dict):
        raise CloudflareConfigurationError(
            f"could not {action}: result is not an object"
        )
    response_account_id = result.get("account_id")
    response_tunnel_id = result.get("tunnel_id")
    if response_account_id is not None and response_account_id != identity.account_id:
        raise CloudflareConfigurationError(
            f"could not {action}: response belongs to a different Cloudflare account"
        )
    if response_tunnel_id is not None:
        try:
            canonical_response_tunnel_id = str(uuid.UUID(str(response_tunnel_id)))
        except (ValueError, TypeError, AttributeError) as error:
            raise CloudflareConfigurationError(
                f"could not {action}: response contains an invalid tunnel UUID"
            ) from error
        if canonical_response_tunnel_id != identity.tunnel_id:
            raise CloudflareConfigurationError(
                f"could not {action}: response belongs to a different Cloudflare tunnel"
            )
    configuration = result.get("config")
    if configuration is None:
        return {}, False
    if not isinstance(configuration, dict):
        raise CloudflareConfigurationError(
            f"could not {action}: returned configuration is not an object"
        )
    return configuration, True


def _list_from_response(
    response: dict[str, Any],
    action: str,
) -> list[dict[str, Any]]:
    if not isinstance(response, dict) or response.get("success") is not True:
        if not isinstance(response, dict):
            raise CloudflareConfigurationError(
                f"could not {action}: response is not an object"
            )
        raise _response_error(response, action)
    result = response.get("result")
    if not isinstance(result, list) or any(
        not isinstance(item, dict) for item in result
    ):
        raise CloudflareConfigurationError(
            f"could not {action}: result is not a list of objects"
        )
    result_info = response.get("result_info")
    if isinstance(result_info, dict):
        total_count = result_info.get("total_count")
        total_pages = result_info.get("total_pages")
        result_is_truncated = (
            isinstance(total_count, int) and total_count > len(result)
        )
        result_has_more_pages = isinstance(total_pages, int) and total_pages > 1
        if result_is_truncated or result_has_more_pages:
            raise CloudflareConfigurationError(
                f"could not {action}: Cloudflare response was unexpectedly paginated"
            )
    return result


def _successful_response(response: dict[str, Any], action: str) -> None:
    if not isinstance(response, dict) or response.get("success") is not True:
        if not isinstance(response, dict):
            raise CloudflareConfigurationError(
                f"could not {action}: response is not an object"
            )
        raise _response_error(response, action)


def _identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-fA-F]{32}", value):
        raise CloudflareConfigurationError(f"Cloudflare returned an invalid {label}")
    return value.lower()


def _zone_id_from_response(
    response: dict[str, Any],
    identity: TunnelIdentity,
    zone_name: str,
) -> str:
    zones = _list_from_response(response, f"find Cloudflare zone {zone_name}")
    matching_zones = [
        zone
        for zone in zones
        if isinstance(zone.get("name"), str)
        and zone["name"].rstrip(".").lower() == zone_name
    ]
    if not matching_zones:
        raise CloudflareConfigurationError(
            f"Cloudflare zone {zone_name} is not visible to the API token; "
            "replace the protected token with one that has Zone / Zone / Read "
            "and Zone / DNS / Edit for that zone"
        )

    account_zones = []
    for zone in matching_zones:
        account = zone.get("account")
        account_id = account.get("id") if isinstance(account, dict) else None
        if isinstance(account_id, str) and account_id.lower() == identity.account_id:
            account_zones.append(zone)
    if not account_zones:
        raise CloudflareConfigurationError(
            f"Cloudflare zone {zone_name} is not in connector account "
            f"{identity.account_id}; tunnel DNS records only work in the same account"
        )

    active_zones = [zone for zone in account_zones if zone.get("status") == "active"]
    if len(active_zones) != 1:
        raise CloudflareConfigurationError(
            f"expected one active Cloudflare zone named {zone_name} in connector account "
            f"{identity.account_id}, found {len(active_zones)}"
        )
    return _identifier(active_zones[0].get("id"), "zone ID")


def _dns_records_from_response(
    response: dict[str, Any],
    zone_id: str,
    hostname: str,
) -> list[dict[str, Any]]:
    records = _list_from_response(response, f"read DNS record for {hostname}")
    exact_records = []
    for record in records:
        name = record.get("name")
        if not isinstance(name, str) or name.rstrip(".").lower() != hostname:
            continue
        response_zone_id = record.get("zone_id")
        if response_zone_id is not None and (
            not isinstance(response_zone_id, str)
            or response_zone_id.lower() != zone_id
        ):
            raise CloudflareConfigurationError(
                f"Cloudflare DNS response for {hostname} belongs to a different zone"
            )
        exact_records.append(record)
    return exact_records


def _dns_record_matches_tunnel(
    record: dict[str, Any],
    hostname: str,
    target: str,
) -> bool:
    name = record.get("name")
    content = record.get("content")
    return (
        record.get("type") == "CNAME"
        and isinstance(name, str)
        and name.rstrip(".").lower() == hostname
        and isinstance(content, str)
        and content.rstrip(".").lower() == target
        and record.get("proxied") is True
    )


def reconcile_public_hostname_dns(
    identity: TunnelIdentity,
    api_token: str,
    zone_name: str,
    hostnames: list[str],
    *,
    transport: Transport | None = None,
) -> bool:
    """Point only the requested public hostnames at the connector's tunnel UUID."""

    if transport is None:
        transport = cloudflare_request
    api_token = validate_api_token(api_token)
    zone_name = validate_hostname(zone_name)
    desired_hostnames = [validate_hostname(hostname) for hostname in hostnames]
    if len(set(desired_hostnames)) != len(desired_hostnames):
        raise CloudflareConfigurationError("duplicate public hostname requested")
    if any(
        hostname != zone_name and not hostname.endswith(f".{zone_name}")
        for hostname in desired_hostnames
    ):
        raise CloudflareConfigurationError(
            f"public hostnames must belong to Cloudflare zone {zone_name}"
        )

    zones_endpoint = f"{API_ROOT}/zones?" + urlencode(
        {"name": zone_name, "per_page": 50}
    )
    zone_id = _zone_id_from_response(
        transport("GET", zones_endpoint, api_token, None),
        identity,
        zone_name,
    )
    records_endpoint = f"{API_ROOT}/zones/{zone_id}/dns_records"
    target = f"{identity.tunnel_id}.cfargotunnel.com"
    changed = False

    def read_exact_records(hostname: str) -> list[dict[str, Any]]:
        endpoint = records_endpoint + "?" + urlencode(
            {"name.exact": hostname, "per_page": 100}
        )
        return _dns_records_from_response(
            transport("GET", endpoint, api_token, None),
            zone_id,
            hostname,
        )

    for hostname in desired_hostnames:
        records = read_exact_records(hostname)
        if len(records) > 1:
            raise CloudflareConfigurationError(
                f"refusing to alter ambiguous DNS state for {hostname}: "
                f"found {len(records)} exact-name records"
            )

        if records:
            record = records[0]
            if record.get("type") != "CNAME":
                raise CloudflareConfigurationError(
                    f"refusing to replace non-CNAME DNS record for {hostname}"
                )
            if _dns_record_matches_tunnel(record, hostname, target):
                continue
            record_id = _identifier(record.get("id"), "DNS record ID")
            update: dict[str, Any] = {}
            content = record.get("content")
            if not isinstance(content, str) or content.rstrip(".").lower() != target:
                update["content"] = target
            if record.get("proxied") is not True:
                update["proxied"] = True
            response = transport(
                "PATCH",
                f"{records_endpoint}/{record_id}",
                api_token,
                update,
            )
            _successful_response(response, f"update DNS record for {hostname}")
        else:
            response = transport(
                "POST",
                records_endpoint,
                api_token,
                {
                    "type": "CNAME",
                    "name": hostname,
                    "content": target,
                    "proxied": True,
                    "ttl": 1,
                },
            )
            _successful_response(response, f"create DNS record for {hostname}")
        changed = True

        verified_records = read_exact_records(hostname)
        if len(verified_records) != 1 or not _dns_record_matches_tunnel(
            verified_records[0], hostname, target
        ):
            raise CloudflareConfigurationError(
                f"Cloudflare did not retain the required tunnel DNS association for "
                f"{hostname}"
            )

    return changed


def cloudflare_request(
    method: str,
    url: str,
    api_token: str,
    payload: dict[str, Any] | None,
) -> dict[str, Any]:
    data = None
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {api_token}",
        "User-Agent": "scriptorium-setup-server/1",
    }
    if payload is not None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as error:
        body = error.read(MAX_RESPONSE_BYTES + 1)
        try:
            response_payload = json.loads(body)
        except (ValueError, json.JSONDecodeError):
            raise CloudflareConfigurationError(
                f"Cloudflare API returned HTTP {error.code}"
            ) from error
        if isinstance(response_payload, dict):
            raise _response_error(response_payload, "complete Cloudflare API request") from error
        raise CloudflareConfigurationError(
            f"Cloudflare API returned HTTP {error.code}"
        ) from error
    except urllib.error.URLError as error:
        raise CloudflareConfigurationError(
            f"could not reach the Cloudflare API: {error.reason}"
        ) from error
    if len(body) > MAX_RESPONSE_BYTES:
        raise CloudflareConfigurationError(
            "Cloudflare API response was unexpectedly large"
        )
    try:
        parsed = json.loads(body)
    except (ValueError, json.JSONDecodeError) as error:
        raise CloudflareConfigurationError("Cloudflare API returned invalid JSON") from error
    if not isinstance(parsed, dict):
        raise CloudflareConfigurationError("Cloudflare API response is not an object")
    return parsed


def reconcile_public_ingress(
    identity: TunnelIdentity,
    api_token: str,
    hostnames: list[str],
    service: str,
    *,
    transport: Transport = cloudflare_request,
) -> ReconcileResult:
    api_token = validate_api_token(api_token)
    endpoint = (
        f"{API_ROOT}/accounts/{identity.account_id}/cfd_tunnel/"
        f"{identity.tunnel_id}/configurations"
    )
    current_response = transport("GET", endpoint, api_token, None)
    current, _ = _configuration_from_response(
        current_response,
        identity,
        "read remotely managed tunnel configuration",
    )
    merged, changed = merge_public_ingress(current, hostnames, service)
    if not changed:
        return ReconcileResult(
            changed=False,
            identity=identity,
            ingress_changed=False,
        )

    updated_response = transport("PUT", endpoint, api_token, {"config": merged})
    updated, has_configuration = _configuration_from_response(
        updated_response,
        identity,
        "replace remotely managed tunnel configuration",
    )
    if not has_configuration:
        verification_response = transport("GET", endpoint, api_token, None)
        updated, has_configuration = _configuration_from_response(
            verification_response,
            identity,
            "verify remotely managed tunnel configuration",
        )
    if not has_configuration:
        raise CloudflareConfigurationError(
            "Cloudflare accepted the update but returned no tunnel configuration"
        )
    _, still_needs_changes = merge_public_ingress(updated, hostnames, service)
    if still_needs_changes:
        raise CloudflareConfigurationError(
            "Cloudflare did not retain the required public tunnel ingress rules"
        )
    return ReconcileResult(
        changed=True,
        identity=identity,
        ingress_changed=True,
    )


def reconcile_from_connector_token(
    connector_token: str,
    api_token: str,
    hostnames: list[str],
    service: str,
    *,
    zone_name: str,
    expected_tunnel_id: str | None = None,
    transport: Transport = cloudflare_request,
) -> ReconcileResult:
    identity = decode_connector_token(connector_token)
    if expected_tunnel_id is not None:
        try:
            expected = str(uuid.UUID(expected_tunnel_id))
        except ValueError as error:
            raise CloudflareConfigurationError(
                "expected Cloudflare tunnel ID is not a UUID"
            ) from error
        if identity.tunnel_id != expected:
            raise CloudflareConfigurationError(
                f"connector token is for tunnel {identity.tunnel_id}, expected {expected}"
            )
    ingress_result = reconcile_public_ingress(
        identity,
        api_token,
        hostnames,
        service,
        transport=transport,
    )
    dns_changed = reconcile_public_hostname_dns(
        identity,
        api_token,
        zone_name,
        hostnames,
        transport=transport,
    )
    return ReconcileResult(
        changed=ingress_result.changed or dns_changed,
        identity=identity,
        ingress_changed=ingress_result.changed,
        dns_changed=dns_changed,
    )


def _read_secret(path: Path, label: str) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError) as error:
        raise CloudflareConfigurationError(f"cannot read {label} file: {path}") from error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connector-token-file", required=True, type=Path)
    parser.add_argument("--api-token-file", required=True, type=Path)
    parser.add_argument("--expected-tunnel-id")
    parser.add_argument("--zone-name", required=True)
    parser.add_argument("--hostname", action="append", required=True)
    parser.add_argument("--service", required=True)
    args = parser.parse_args()

    try:
        result = reconcile_from_connector_token(
            _read_secret(args.connector_token_file, "Cloudflare connector token"),
            _read_secret(args.api_token_file, "Cloudflare API token"),
            args.hostname,
            args.service,
            zone_name=args.zone_name,
            expected_tunnel_id=args.expected_tunnel_id,
        )
    except CloudflareConfigurationError as error:
        parser.exit(1, f"configure-cloudflare-tunnel: {error}\n")

    action = "configured" if result.changed else "already configured"
    print(
        f"Cloudflare tunnel ingress and public DNS {action}: "
        f"{', '.join(args.hostname)} -> {validate_local_service(args.service)} "
        f"via {result.identity.tunnel_id}"
    )


if __name__ == "__main__":
    main()
