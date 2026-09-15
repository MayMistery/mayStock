"""Resolve one complete inference connection without borrowing launcher credentials."""
from __future__ import annotations

from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
from typing import Mapping
import urllib.parse

if __package__:
    from .research import ResearchError
else:
    from research import ResearchError


TRANSPORT_ENV = {
    "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
    "https_proxy", "http_proxy", "all_proxy", "no_proxy", "NODE_EXTRA_CA_CERTS",
    "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE",
}
AUTH_ENV = {
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
    "ANTHROPIC_CUSTOM_HEADERS", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_FOUNDRY_RESOURCE",
    "ANTHROPIC_FOUNDRY_BASE_URL", "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_VERTEX_PROJECT_ID",
    "CLOUD_ML_REGION", "AWS_REGION", "AWS_PROFILE", "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "GOOGLE_APPLICATION_CREDENTIALS",
    "ANTHROPIC_BEDROCK_BASE_URL", "ANTHROPIC_VERTEX_BASE_URL", "AWS_DEFAULT_REGION",
    "AWS_BEARER_TOKEN_BEDROCK", "CLAUDE_CODE_SKIP_BEDROCK_AUTH", "CLAUDE_CODE_SKIP_VERTEX_AUTH",
    "CLAUDE_CODE_SKIP_FOUNDRY_AUTH", "CLAUDE_CODE_USE_GATEWAY",
    "CLAUDE_CODE_USE_ANTHROPIC_AWS", "ANTHROPIC_AWS_BASE_URL", "ANTHROPIC_AWS_API_KEY",
    "CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH",
} | TRANSPORT_ENV
ROUTE_ENV = AUTH_ENV - TRANSPORT_ENV
FIXED_ENV = {"CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "ENABLE_CLAUDEAI_MCP_SERVERS": "false"}
_HEADER_NAME = re.compile(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+\Z")


@dataclass(frozen=True)
class ConnectionProfile:
    env: dict[str, str] = field(repr=False)
    source: str
    origin: str | None = None
    header_names: tuple[str, ...] = ()
    ignored_environment_keys: tuple[str, ...] = field(default_factory=tuple)

    def diagnostics(self) -> dict:
        """Do not include credentials, header values, filesystem paths, or URL paths."""
        return {"source": self.source, "origin": self.origin,
                "headerNames": list(self.header_names),
                "ignoredEnvironmentKeys": list(self.ignored_environment_keys)}


def _error(message: str) -> ResearchError:
    return ResearchError("CONNECTION_CONFIG: " + message)


def _configuration(path: Path, *, dedicated: bool) -> dict[str, str]:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError, UnicodeError):
        raise _error("cannot read a valid connection JSON object" if dedicated else
                     "cannot read valid Claude settings JSON") from None
    if not isinstance(data, dict):
        raise _error("connection must be a JSON object" if dedicated else "Claude settings must be a JSON object")
    values = data if dedicated else data.get("env", {})
    if not isinstance(values, dict):
        raise _error("Claude settings env must be an object")
    result = {}
    for key, value in values.items():
        if key not in AUTH_ENV:
            continue
        if not isinstance(value, str):
            raise _error(f"{key} must be a string")
        result[key] = value
    return result


def _origin(base: str, field_name: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(base)
        port = parsed.port
        if (not base or any(ord(c) <= 32 or ord(c) == 127 for c in base)
                or parsed.scheme not in {"http", "https"} or not parsed.hostname
                or parsed.username is not None or parsed.password is not None
                or parsed.query or parsed.fragment or "?" in base or "#" in base):
            raise ValueError()
        hostname = parsed.hostname
        if ":" in hostname:
            hostname = "[" + hostname + "]"
        authority = hostname + (f":{port}" if port is not None else "")
        return f"{parsed.scheme}://{authority}"
    except (ValueError, TypeError):
        raise _error(f"{field_name} must be an http/https URL without userinfo, query, or fragment") from None


def _headers(value: str) -> dict[str, str]:
    if r"\n" in value or r"\r" in value:
        raise _error("ANTHROPIC_CUSTOM_HEADERS must use actual newlines")
    if ("\r" in value.replace("\r\n", "")
            or any(ord(char) < 32 and char not in "\r\n\t" for char in value)):
        raise _error("ANTHROPIC_CUSTOM_HEADERS requires LF or CRLF line separators")
    parsed = {}
    for line in value.splitlines():
        if not line.strip():
            continue
        name, separator, contents = line.partition(":")
        name, contents = name.strip(), contents.strip()
        if not separator or not _HEADER_NAME.fullmatch(name):
            raise _error("ANTHROPIC_CUSTOM_HEADERS contains an invalid header name or missing colon")
        normalized = name.lower()
        if normalized in parsed:
            raise _error("ANTHROPIC_CUSTOM_HEADERS contains a duplicate header name")
        if not contents or any(ord(char) < 32 or ord(char) == 127 for char in contents):
            raise _error("ANTHROPIC_CUSTOM_HEADERS contains an empty or invalid header value")
        parsed[normalized] = contents
    if not parsed:
        raise _error("ANTHROPIC_CUSTOM_HEADERS must contain at least one header")
    return parsed


def _validate(env: dict[str, str]) -> tuple[str | None, tuple[str, ...]]:
    origin = None
    for key, value in env.items():
        if key.startswith("ANTHROPIC_") and key.endswith("_BASE_URL"):
            candidate = _origin(value, key)
            if key == "ANTHROPIC_BASE_URL":
                origin = candidate
    headers = _headers(env["ANTHROPIC_CUSTOM_HEADERS"]) if "ANTHROPIC_CUSTOM_HEADERS" in env else {}
    if "x-relay-passthrough" in headers or "x-relay-api-key" in headers:
        if not origin or not {"x-relay-passthrough", "x-relay-api-key"} <= headers.keys():
            raise _error("relay configuration requires ANTHROPIC_BASE_URL, x-relay-passthrough, and x-relay-api-key together")
        if headers["x-relay-passthrough"] != "anthropic":
            raise _error("x-relay-passthrough must select anthropic")
    return origin, tuple(sorted(headers))


def _removed(key: str) -> bool:
    if key == "CLAUDE_CONFIG_DIR":
        return False
    return (key == "CLAUDECODE" or key.startswith(("ANTHROPIC_", "CLAUDE_", "_CLAUDE"))
            or key in ROUTE_ENV)


def _path(value: str, home: Path) -> Path:
    if value == "~":
        return home
    if value.startswith("~/"):
        return home / value[2:]
    return Path(value)


def resolve_connection(environ: Mapping[str, str] | None = None,
                       home: str | Path | None = None) -> ConnectionProfile:
    inherited = dict(os.environ if environ is None else environ)
    home_directory = Path(home if home is not None else inherited.get("HOME") or Path.home())
    dedicated_override = inherited.get("MAYSTOCK_INTELLIGENCE_CONNECTION")
    if "MAYSTOCK_INTELLIGENCE_CONNECTION" in inherited and not dedicated_override:
        raise _error("MAYSTOCK_INTELLIGENCE_CONNECTION must name a connection file")
    connection = (_path(dedicated_override, home_directory) if dedicated_override else
                  home_directory / "Library/Application Support/MayStock/Intelligence/connection.json")
    if dedicated_override and not connection.is_file():
        raise _error("MAYSTOCK_INTELLIGENCE_CONNECTION does not name a readable file")

    # Connection selection is atomic. Transport settings can be inherited
    # independently; they cannot replace an endpoint or contribute a credential.
    transport = {key: value for key, value in inherited.items()
                 if key in TRANSPORT_ENV and isinstance(value, str)}
    environment_route = {key: value for key, value in inherited.items()
                         if key in ROUTE_ENV and isinstance(value, str)}
    if connection.exists():
        if not connection.is_file():
            raise _error("connection must be a readable file")
        selected, source = _configuration(connection, dedicated=True), "connection"
    elif environment_route:
        selected, source = environment_route, "environment"
    else:
        config_directory = inherited.get("CLAUDE_CONFIG_DIR")
        settings = (_path(config_directory, home_directory) if config_directory else
                    home_directory / ".claude") / "settings.json"
        selected = _configuration(settings, dedicated=False) if settings.exists() else {}
        source = "claude_settings" if selected else "native"
        # Explicit shell proxy/CA values override legacy settings' transport.
        selected = {**selected, **transport}
    effective = {**transport, **selected}
    origin, header_names = _validate(effective)
    ignored = tuple(sorted(key for key in inherited if _removed(key) and
                           (key not in effective or effective[key] != inherited[key]
                            or (source != "environment" and key in ROUTE_ENV))))
    return ConnectionProfile(env=effective, source=source, origin=origin,
                             header_names=header_names, ignored_environment_keys=ignored)


def isolated_environment(environ: Mapping[str, str], profile: ConnectionProfile) -> dict[str, str]:
    """Return a complete child environment; callers replace rather than merge it.

    The Python Agent SDK itself merges its env option over os.environ. The worker
    must install this result before constructing the SDK client.
    """
    result = {key: value for key, value in environ.items() if not _removed(key)}
    result.update(profile.env)
    result.update(FIXED_ENV)
    return result
