# Agent status relay

This page explains how to send session status events from the container to a
receiver on your host. A dashboard can then show which Claude Code and Codex
sessions are working or waiting.

## What the relay does

Use the relay to show session status on a Mac dashboard, on a controller like
a Stream Deck, or on the screen of a spare tablet. The screen can show which
Claude Code and Codex sessions are working or waiting.

aicontainer sends lifecycle hints from sessions that you start in a terminal
**or in the VS Code sidebars**. The relay uses the managed hooks of each tool:

- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Codex hooks](https://learn.chatgpt.com/docs/hooks)

So the location in the editor does not change the event source.

## Enable the relay

1. Run a receiver on the Mac. The receiver must accept `POST /events` on port
   `8787`.
2. Opt in globally on that host:

   ```bash
   mkdir -p ~/.config/aicontainer
   printf 'enabled\n' > ~/.config/aicontainer/status-relay
   aic rebuild
   ```

Existing projects must be created again one time. After that, `aic init`,
`aic sync`, and the VS Code initialization refresh the mode automatically.

To opt out, delete the marker file and rebuild.

### Rules for the marker file

- The marker must be a regular file. It must not be a symlink.
- The marker must contain exactly `enabled` and a newline.

A repository `.env` or a Compose override cannot silently enable the relay.
It also cannot change the identity of the relay or send the events to a
different address.

`aic status` shows the host marker and the value that the project actually
uses. So a marker that you wrote but did not apply yet shows as
`pending aic rebuild`.

## Where the events go

Each callback goes to a URL that you cannot change:
`http://host.docker.internal:8787/events`.

The callback ignores proxy environment variables and redirects. It fails open.
These conditions are ignored and never change the behavior of the agent:

- No listener.
- Malformed hook input.
- A DNS failure.
- An HTTP error.

The 500 ms timeout applies to the connection only. It does not apply to the
name lookup before the connection. A host resolver can blackhole
`host.docker.internal` and not answer. Then the hook timeout of each tool
(a few seconds) is the limit. So make sure that the name resolves, or that
it does not exist.

### `host.docker.internal` on each platform

- **Docker Desktop for macOS or Windows:** `host.docker.internal` is built in.
- **Linux:** you must expose the host gateway. Usually you add an
  `extra_hosts` entry for `host.docker.internal:host-gateway`. Review it with
  `aic trust`.

### The relay and the network allowlist

When the opt-in [network allowlist](network-allowlist.md) is active, aic
allows only TCP 8787 to the resolved host-gateway address. It does not add
the host to the general allowlist. The firewall reads the relay mode from the
generated `.devcontainer/.env`, which the agent cannot change.

When the name does not resolve, the firewall shows a warning and does not add
that one rule. So a dashboard that you cannot reach never removes the
outbound allowlist of the project.

## The event format

The JSON contract is small on purpose:

```json
{
  "schema_version": 1,
  "source": "aicontainer",
  "provider": "codex",
  "project": "my-api",
  "project_id": "aic-my-api-0123456789ab",
  "session_id": "session-uuid",
  "event": "UserPromptSubmit",
  "state": "working",
  "occurred_at": "2026-08-24T10:00:00.000Z",
  "model": "optional-model-name"
}
```

### Events and states

| Event | `state` |
| --- | --- |
| `UserPromptSubmit` | `working` |
| Start, permission or input notifications, elicitation, normal stop | `waiting` |
| A compaction in the middle of a turn, or an elicitation response | `working` |
| Claude `StopFailure` | `error` |
| `SessionEnd` | `ended` |

Claude notification events can also add `notification_type`.

The field list above is complete. **The relay never sends these items:**

- Prompt text and response text.
- Tool names, tool inputs, and tool results.
- The working directory.
- The transcript path.
- Error details.
- Credentials.

## Build a safe receiver

Treat these events as untrusted display hints. Code that runs inside the
container can forge a POST to each status listener that it can reach. Keep
the ingestion write-only and harmless.

> **Warning:** Do not put macro execution, shell commands, or Spotify
> credentials behind this unauthenticated route. Code in the container can
> forge events. Serve tablet controls through a different host-side API that
> has authentication.

Hooks run in the background when the tool allows it. So the receiver should do
these things:

- Apply events in the order of `occurred_at`.
- Treat `ended` as the final event for that session ID.
- Remove stale sessions after a reasonable idle period.
