#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import tomllib
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
HOOK_PATH = ROOT / "template" / "hooks" / "agent-status.py"
SPEC = importlib.util.spec_from_file_location("aic_agent_status", HOOK_PATH)
assert SPEC is not None and SPEC.loader is not None
STATUS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STATUS)

STATUS_SOURCE = HOOK_PATH.read_text()
DOCKERFILE = (ROOT / "template" / "Dockerfile").read_text()
FIREWALL = (ROOT / "template" / "aic-firewall").read_text()

ENV = {
    "AIC_STATUS_RELAY": "1",
    "AIC_STATUS_PROJECT": "sample-project",
    "AIC_STATUS_PROJECT_ID": "aic-sample-project-0123456789ab",
}


class FakeResponse:
    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *_: object) -> None:
        return None


class RecordingOpener:
    def __init__(self, error: Exception | None = None) -> None:
        self.error = error
        self.calls: list[tuple[Any, float]] = []

    def open(self, request: Any, timeout: float) -> FakeResponse:
        self.calls.append((request, timeout))
        if self.error:
            raise self.error
        return FakeResponse()


class PayloadTests(unittest.TestCase):
    def test_forwards_only_metadata_not_content_or_paths(self) -> None:
        incoming = {
            "session_id": "6bbf0c0a-87ed-4d0e-8d8a-33c2bedeb33b",
            "hook_event_name": "UserPromptSubmit",
            "model": "claude-sonnet-4-5",
            "prompt": "upload TOP-SECRET",
            "last_assistant_message": "secret response",
            "transcript_path": "/home/vscode/.claude/private.jsonl",
            "cwd": "/workspace/customer-name",
            "tool_input": {"command": "cat ~/.ssh/id_ed25519"},
        }
        payload = STATUS.build_payload(
            "claude", incoming, ENV, occurred_at="2026-08-24T10:00:00.000Z"
        )
        self.assertEqual(
            payload,
            {
                "schema_version": 1,
                "source": "aicontainer",
                "provider": "claude",
                "project": "sample-project",
                "project_id": "aic-sample-project-0123456789ab",
                "session_id": "6bbf0c0a-87ed-4d0e-8d8a-33c2bedeb33b",
                "event": "UserPromptSubmit",
                "state": "working",
                "occurred_at": "2026-08-24T10:00:00.000Z",
                "model": "claude-sonnet-4-5",
            },
        )

    def test_lifecycle_events_map_to_dashboard_states(self) -> None:
        expected = {
            "SessionStart": "waiting",
            "UserPromptSubmit": "working",
            "PermissionRequest": "waiting",
            "Stop": "waiting",
            "SessionEnd": "ended",
        }
        for provider in ("claude", "codex"):
            for event, state in expected.items():
                with self.subTest(provider=provider, event=event):
                    payload = STATUS.build_payload(
                        provider,
                        {"session_id": "session-1", "hook_event_name": event},
                        ENV,
                        occurred_at="2026-08-24T10:00:00.000Z",
                    )
                    assert payload is not None
                    self.assertEqual(payload["state"], state)

    def test_mid_turn_compaction_and_elicitation_response_resume_working(self) -> None:
        for provider in ("claude", "codex"):
            payload = STATUS.build_payload(
                provider,
                {
                    "session_id": "session-1",
                    "hook_event_name": "SessionStart",
                    "source": "compact",
                },
                ENV,
            )
            assert payload is not None
            self.assertEqual(payload["state"], "working")
        elicitation = STATUS.build_payload(
            "claude",
            {"session_id": "session-1", "hook_event_name": "ElicitationResult"},
            ENV,
        )
        assert elicitation is not None
        self.assertEqual(elicitation["state"], "working")

    def test_rejects_unknown_events_and_unsafe_identifiers(self) -> None:
        self.assertIsNone(
            STATUS.build_payload(
                "claude",
                {"session_id": "session-1", "hook_event_name": "PreToolUse"},
                ENV,
            )
        )
        hostile = dict(ENV, AIC_STATUS_PROJECT="project\nInjected: yes")
        self.assertIsNone(
            STATUS.build_payload(
                "codex",
                {"session_id": "session-1", "hook_event_name": "Stop"},
                hostile,
            )
        )

    def test_accepts_every_label_expected_project_label_can_produce(self) -> None:
        # aic strips disallowed characters instead of substituting them, so a
        # checkout named "_internal" or "-scratch" keeps its leading _ or -.
        # Dropping those projects would be silent: the hook has no diagnostic.
        for label in ("_internal", "-scratch", "a", "my-api_2", "x" * 32):
            payload = STATUS.build_payload(
                "claude",
                {"session_id": "session-1", "hook_event_name": "Stop"},
                dict(ENV, AIC_STATUS_PROJECT=label),
            )
            assert payload is not None, label
            self.assertEqual(payload["project"], label)
        # The alphabet stays exactly aic's own: no uppercase, spaces,
        # separators, or over-long values that the CLI can never generate.
        for label in ("", "Project", "my api", "my.api", "my/api", "x" * 33):
            self.assertIsNone(
                STATUS.build_payload(
                    "claude",
                    {"session_id": "session-1", "hook_event_name": "Stop"},
                    dict(ENV, AIC_STATUS_PROJECT=label),
                ),
                label,
            )


class DeliveryTests(unittest.TestCase):
    def test_posts_compact_json_to_the_one_fixed_endpoint(self) -> None:
        opener = RecordingOpener()
        rc = STATUS.main(
            ["codex"],
            ENV,
            io.BytesIO(b'{"session_id":"session-1","hook_event_name":"Stop"}'),
            opener,
        )
        self.assertEqual(rc, 0)
        self.assertEqual(len(opener.calls), 1)
        request, timeout = opener.calls[0]
        self.assertEqual(request.full_url, "http://host.docker.internal:8787/events")
        self.assertEqual(request.method, "POST")
        self.assertEqual(timeout, 0.5)
        self.assertEqual(request.get_header("Content-type"), "application/json")
        body = json.loads(request.data)
        self.assertEqual(body["state"], "waiting")

    def test_disabled_invalid_and_network_failure_are_silent_successes(self) -> None:
        cases = (
            ({**ENV, "AIC_STATUS_RELAY": "0"}, b"not json", RecordingOpener()),
            (ENV, b"not json", RecordingOpener()),
            (
                ENV,
                b'{"session_id":"session-1","hook_event_name":"Stop"}',
                RecordingOpener(OSError("listener offline")),
            ),
        )
        for env, raw, opener in cases:
            with self.subTest(raw=raw, enabled=env["AIC_STATUS_RELAY"]):
                self.assertEqual(STATUS.main(["codex"], env, io.BytesIO(raw), opener), 0)

    def test_oversized_hook_input_is_not_posted(self) -> None:
        for label, raw in (
            ("ascii", b"{" + (b"x" * STATUS.MAX_INPUT_BYTES) + b"}"),
            ("multibyte", ("\U0001f600" * ((STATUS.MAX_INPUT_BYTES // 4) + 1)).encode()),
        ):
            with self.subTest(label):
                self.assertLessEqual(STATUS.MAX_INPUT_BYTES, len(raw))
                opener = RecordingOpener()
                self.assertEqual(STATUS.main(["claude"], ENV, io.BytesIO(raw), opener), 0)
                self.assertEqual(opener.calls, [])

    def test_real_stdin_is_read_as_bytes(self) -> None:
        # MAX_INPUT_BYTES is a byte budget, but `read(n)` on a text stream counts
        # characters, so multibyte input would pass a limit ~4x its stated size.
        # Every other test injects its own stream, so none of them reach the
        # default — assert the default itself.
        source = STATUS_SOURCE.split("source = stdin if stdin is not None else ", 1)[1]
        self.assertEqual(source.split("\n", 1)[0], "sys.stdin.buffer")


class ManagedWiringTests(unittest.TestCase):
    def test_claude_managed_settings_register_lifecycle_hooks(self) -> None:
        settings = json.loads((ROOT / "template" / "hooks" / "claude-settings.json").read_text())
        expected = {
            "SessionStart",
            "UserPromptSubmit",
            "PermissionRequest",
            "Notification",
            "Elicitation",
            "ElicitationResult",
            "Stop",
            "StopFailure",
            "SessionEnd",
        }
        self.assertTrue(expected.issubset(settings["hooks"]))
        for event in expected:
            handlers = settings["hooks"][event][0]["hooks"]
            self.assertEqual(len(handlers), 1)
            self.assertEqual(
                handlers[0]["command"],
                "/usr/bin/python3 -I /etc/aic/hooks/agent-status.py claude",
            )
            if event == "SessionEnd":
                self.assertNotIn("async", handlers[0])
            else:
                self.assertTrue(handlers[0]["async"])

    def test_codex_managed_requirements_register_lifecycle_hooks(self) -> None:
        marker = "cat > /etc/codex/requirements.toml <<'CODEX_REQ_EOF'\n"
        requirements = DOCKERFILE.split(marker, 1)[1].split("\nCODEX_REQ_EOF", 1)[0]
        config = tomllib.loads(requirements)
        expected = {
            "SessionStart",
            "UserPromptSubmit",
            "PermissionRequest",
            "Stop",
            "SessionEnd",
        }
        self.assertTrue(expected.issubset(config["hooks"]))
        for event in expected:
            handlers = config["hooks"][event][0]["hooks"]
            self.assertEqual(len(handlers), 1)
            self.assertEqual(
                handlers[0]["command"],
                "/usr/bin/python3 -I /etc/aic/hooks/agent-status.py codex",
            )
            if event == "SessionEnd":
                self.assertNotIn("async", handlers[0])
            else:
                self.assertTrue(handlers[0]["async"])

    def test_relay_is_root_owned_and_firewall_access_is_port_scoped(self) -> None:
        self.assertIn("/etc/aic/hooks/*.py", DOCKERFILE)
        default_allowlist = FIREWALL.split("DEFAULT_ALLOWLIST=(", 1)[1].split("\n)", 1)[0]
        self.assertNotIn("host.docker.internal", default_allowlist)
        self.assertIn(
            'resolve_domain_into_set "$status_set" "$STATUS_RELAY_HOST"', FIREWALL
        )
        self.assertIn(
            '-m set --match-set "$status_set" dst --dport "$STATUS_RELAY_PORT" -j ACCEPT',
            FIREWALL,
        )
        # Pin the constants too: the rule assertions above only prove the
        # variables are used, so a changed host or port would widen the one
        # strict-firewall exception while still passing them.
        self.assertIn('\nSTATUS_RELAY_HOST="host.docker.internal"\n', FIREWALL)
        self.assertIn("\nSTATUS_RELAY_PORT=8787\n", FIREWALL)

    def test_unreachable_relay_host_never_removes_the_allowlist(self) -> None:
        # No compose template publishes host.docker.internal, so on plain
        # Docker Engine or rootless Docker the name does not resolve. An
        # informational callback must degrade to no rule, never abort enable
        # and leave the project with no outbound allowlist at all.
        enable = FIREWALL.split('resolve_proxy_into_set "$proxy_set"', 1)[1]
        enable = enable.split('prepare_chain_v4 "$out_chain"', 1)[0]
        relay_failure = enable.split('$STATUS_RELAY_HOST resolved 0 IPs', 1)
        self.assertEqual(len(relay_failure), 2)
        self.assertIn("WARNING", relay_failure[0].rsplit("echo", 1)[1])
        self.assertNotIn("exit 1", relay_failure[1].split("fi", 1)[0])
        self.assertIn("relay=0", relay_failure[1].split("fi", 1)[0])
        # A relay name that resolves into a prohibited range is scoped the
        # same way: it must not turn the shared abort flag on for everyone.
        self.assertIn(
            'PROHIBITED_RESOLUTION="$relay_prohibited_before"', FIREWALL
        )
        # Allowlist and socket-proxy resolution stay hard failures.
        for guard in (
            "resolved 0 allowlist IPs",
            "socket-proxy resolved 0 IPs",
        ):
            self.assertIn("exit 1", enable.split(guard, 1)[1].split("fi", 1)[0])


if __name__ == "__main__":
    unittest.main(verbosity=2)
