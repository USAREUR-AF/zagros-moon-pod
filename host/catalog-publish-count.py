#!/usr/bin/env python3
"""Read one slot's publish roll-up with its own portal token."""

from __future__ import annotations

import argparse
import datetime
import email.utils
import http.client
import json
import re
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class CatalogError(Exception):
    """An error safe to show without exposing request credentials."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise CatalogError(f"portal returned an HTTP redirect ({code}); redirects are refused")


def toml_string(path: Path, key: str) -> str:
    pattern = re.compile(rf'^\s*{re.escape(key)}\s*=\s*"([^"]*)"')
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise CatalogError(f"could not read {path}: {error.__class__.__name__}") from None
    for line in lines:
        match = pattern.match(line)
        if match:
            return match.group(1)
    return ""


def valid_context(context: str) -> str:
    if context in {".", ".."} or not re.fullmatch(r"[A-Za-z0-9._-]+", context):
        raise CatalogError(f"invalid active goat context: {context}")
    return context


def retry_after_seconds(value: str | None) -> int | None:
    if not value:
        return None
    value = value.strip()
    if value.isdigit():
        return int(value)
    try:
        when = email.utils.parsedate_to_datetime(value)
        if when.tzinfo is None:
            when = when.replace(tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        return max(0, int((when - now).total_seconds()))
    except (TypeError, ValueError, OverflowError):
        return None


def read_rollup(profile_dir: Path, slot: str, timeout: float, context: str) -> tuple[int, int]:
    context_dir = profile_dir / "contexts" / valid_context(context)
    endpoint = toml_string(context_dir / "profile.toml", "portal_endpoint").rstrip("/")
    if not endpoint:
        raise CatalogError(f"{context_dir / 'profile.toml'} has no portal_endpoint")
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme != "https" or not parsed.netloc:
        raise CatalogError("profile portal_endpoint must be an HTTPS URL")
    try:
        token = (context_dir / "portal.token").read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError) as error:
        raise CatalogError(
            f"could not read {context_dir / 'portal.token'}: {error.__class__.__name__}"
        ) from None
    if not token:
        raise CatalogError(f"{context_dir / 'portal.token'} is empty")

    url = f"{endpoint}/api/catalog?{urllib.parse.urlencode({'include': 'empty'})}"
    request = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Cache-Control": "no-cache",
        },
    )
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=timeout) as response:
            document = json.load(response)
    except CatalogError:
        raise
    except urllib.error.HTTPError as error:
        if error.code == 429:
            retry = retry_after_seconds(error.headers.get("Retry-After"))
            suffix = f"; retry-after-seconds={retry}" if retry is not None else ""
            raise CatalogError(f"portal refused the catalog read with HTTP 429{suffix}") from None
        raise CatalogError(f"portal refused the catalog read with HTTP {error.code}") from None
    except (urllib.error.URLError, TimeoutError, socket.timeout):
        raise CatalogError("catalog read could not reach the portal") from None
    except (json.JSONDecodeError, UnicodeError, http.client.HTTPException):
        raise CatalogError("portal returned an incomplete or malformed JSON response") from None
    except OSError as error:
        raise CatalogError(f"catalog response could not be read: {error.__class__.__name__}") from None

    if not isinstance(document, dict) or not isinstance(document.get("orgs"), list):
        raise CatalogError("catalog response has no valid orgs array")
    for row in document["orgs"]:
        if not isinstance(row, dict) or row.get("prefix") != slot:
            continue
        count = row.get("publish_count")
        published = row.get("last_publish_at")
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise CatalogError(f"catalog row for slot {slot} has no valid publish_count")
        if count == 0 and published is None:
            published = 0
        if not isinstance(published, int) or isinstance(published, bool) or published < 0:
            raise CatalogError(f"catalog row for slot {slot} has no valid last_publish_at")
        return count, published
    raise CatalogError(f"catalog has no row for slot {slot}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile-dir", required=True, type=Path)
    parser.add_argument("--context", required=True)
    parser.add_argument("--slot", required=True)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    try:
        count, published = read_rollup(
            args.profile_dir, args.slot, args.timeout, args.context
        )
        print(f"{count}\t{published}")
        return 0
    except CatalogError as error:
        print(f"not confirmed: {error}", file=sys.stderr)
        message = str(error)
        if "HTTP 401" in message or "HTTP 403" in message:
            return 2
        if "HTTP 429" in message:
            return 3
        return 1
    except Exception:
        print("not confirmed: catalog read failed safely", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
