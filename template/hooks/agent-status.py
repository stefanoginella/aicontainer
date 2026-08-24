#!/usr/bin/env python3
"""Fail-open, metadata-only Claude Code/Codex lifecycle relay."""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import urllib.request
from collections.abc import Mapping
from typing import Any, BinaryIO


ENDPOINT = "http://host.docker.internal:8787/events"
MAX_INPUT_BYTES = 1_048_576
# Socket timeout only: it bounds connect/send/recv, not the getaddrinfo call
# urllib makes first. A resolver that blackholes host.docker.internal is
# bounded by the agent's own hook timeout, not by this value.
TIMEOUT_SECONDS = 0.5
SAFE_VALUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/+@ -]*$")
# expected_project_label() strips disallowed characters instead of
# substituting them, so a checkout in a directory named "_internal" or
# "-scratch" keeps its leading _ or -. Mirror that exact alphabet and length
# here: a stricter first character would silently drop every event for those
# projects. It stays narrower than SAFE_VALUE in every other respect.
SAFE_LABEL = re.compile(r"^[a-z0-9_-]{1,32}$")

EVENT_STATES = {
    "claude": {
        "SessionStart": "waiting",
        "UserPromptSubmit": "working",
        "PermissionRequest": "waiting",
        "Notification": "waiting",
        "Elicitation": "waiting",
        "ElicitationResult": "working",
        "Stop": "waiting",
        "StopFailure": "error",
        "SessionEnd": "ended",
    },
    "codex": {
        "SessionStart": "waiting",
        "UserPromptSubmit": "working",
        "PermissionRequest": "waiting",
        "Stop": "waiting",
        "SessionEnd": "ended",
    },
}


def safe_value(value: object, *, limit: int) -> str | None:
    if not isinstance(value, str) or not 1 <= len(value) <= limit:
        return None
    if not SAFE_VALUE.fullmatch(value):
        return None
    return value


def safe_label(value: object) -> str | None:
    if not isinstance(value, str) or not SAFE_LABEL.fullmatch(value):
        return None
    return value


def utc_timestamp() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def build_payload(
    provider: str,
    event_input: object,
    environ: Mapping[str, str],
    *,
    occurred_at: str | None = None,
) -> dict[str, object] | None:
    """Build only the documented, non-content event envelope."""
    if provider not in EVENT_STATES or not isinstance(event_input, dict):
        return None

    event = safe_value(event_input.get("hook_event_name"), limit=40)
    session_id = safe_value(event_input.get("session_id"), limit=128)
    project = safe_label(environ.get("AIC_STATUS_PROJECT"))
    project_id = safe_value(environ.get("AIC_STATUS_PROJECT_ID"), limit=64)
    if not event or event not in EVENT_STATES[provider]:
        return None
    if not session_id or not project or not project_id:
        return None

    state = EVENT_STATES[provider][event]
    if event == "SessionStart" and event_input.get("source") == "compact":
        # SessionStart also fires during mid-turn compaction; that is not a
        # request for user input and must not overwrite an active turn.
        state = "working"

    payload: dict[str, object] = {
        "schema_version": 1,
        "source": "aicontainer",
        "provider": provider,
        "project": project,
        "project_id": project_id,
        "session_id": session_id,
        "event": event,
        "state": state,
        "occurred_at": occurred_at or utc_timestamp(),
    }
    model = safe_value(event_input.get("model"), limit=128)
    if model:
        payload["model"] = model
    if event == "Notification":
        notification_type = safe_value(event_input.get("notification_type"), limit=64)
        if notification_type:
            payload["notification_type"] = notification_type
    return payload


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Keep the callback fixed even if a listener returns a redirect."""

    def redirect_request(
        self,
        req: Any,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        return None


def post_payload(payload: Mapping[str, object], opener: Any | None = None) -> None:
    body = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    request = urllib.request.Request(
        ENDPOINT,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "User-Agent": "aicontainer-agent-status/1",
        },
    )
    active_opener = opener or urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirectHandler()
    )
    with active_opener.open(request, timeout=TIMEOUT_SECONDS):
        pass


def main(
    argv: list[str] | None = None,
    environ: Mapping[str, str] | None = None,
    stdin: BinaryIO | None = None,
    opener: Any | None = None,
) -> int:
    """Never delay or change the agent's behavior when telemetry fails."""
    args = argv if argv is not None else sys.argv[1:]
    env = environ if environ is not None else os.environ
    # Read the binary stream, not the decoded one: `read(n)` on a text stream
    # counts characters, so multibyte input would sail past a limit named in
    # bytes. json.loads() decodes UTF-8 itself.
    source = stdin if stdin is not None else sys.stdin.buffer
    try:
        if env.get("AIC_STATUS_RELAY") != "1" or len(args) != 1:
            return 0
        raw = source.read(MAX_INPUT_BYTES + 1)
        if len(raw) > MAX_INPUT_BYTES:
            return 0
        payload = build_payload(args[0], json.loads(raw), env)
        if payload is not None:
            post_payload(payload, opener)
    except Exception:
        # Hooks are status hints, never policy. Invalid input, DNS failures,
        # timeouts, HTTP errors, and listener downtime must all be invisible.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
