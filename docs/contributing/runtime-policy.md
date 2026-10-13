# Runtime policy

Read this page before you change the Docker daemon exposure modes (`--docker-read`, `--docker`, `--no-docker`, the socket proxy), the metadata block or the allowlist in `template/aic-firewall`, or the `pids_limit` in the Compose templates.

## Docker daemon exposure modes

Docker daemon exposure has three modes. Both templates use `none` as the
default.

| Mode | Flag | Socket-proxy settings |
|---|---|---|
| `none` | default; `--no-docker` returns to it | `PING/VERSION=1`; all object reads and `POST/BUILD=0` |
| `ro` | `--docker-read` | six object list and inspect groups on; writes off |
| `rw` | `--docker` | reads and writes on |

Read APIs are not safe by default. The container inspect, log, and archive
endpoints can expose unrelated host workloads.

### Host consent

The mode is encoded in Compose, and sync keeps it. But `ro` and `rw` also need
matching host consent under `$XDG_STATE_HOME/aicontainer/docker-write`. Thus a
repository edit cannot opt itself in.

Follow these rules:

- Keep all toggles coherent in `read_compose_docker_mode()`,
  `apply_docker_mode()`, and the structural normalizer.
- A malformed set of toggles resets to a safe value or fails safe.
- `--no-docker` revokes stale consent.
- Sync must reset an inherited `ro` or `rw` mode to `none`. The exceptions
  are an explicit Docker flag from the user, or matching consent that already
  exists. This rule keeps ordinary legacy upgrades and checkouts on a new host
  free of prompts. It does not trust the repository value.
- Change these items together: the boundary summary, help, completions,
  tests, the user guide, and both templates.

The socket-proxy image is pinned to a verified multi-architecture digest. This
is necessary because it holds the raw host socket.

## Always-on metadata block

`block_metadata()` runs on every create. It adds unconditional drops that are
never flushed for these ranges:

- `169.254.0.0/16`
- `100.100.100.200/32`
- `fe80::/10`
- `fd00:ec2::254`

The metadata block is independent of the opt-in full allowlist. It only
makes the policy stronger.

The full `enable` path works in this sequence:

1. It builds inactive A/B IPv4 and IPv6 chains and ipsets.
2. It rejects DNS results that are prohibited or that have zero IPs.
3. It swaps one jump.

Follow these rules:

- Never set policy ACCEPT.
- Never flush a live chain or a metadata chain.
- If IPv6 exists but cannot be filtered, fail. Do not expose an IPv6 bypass.

A sibling container with write access has a different netns. The block does
not cover it.

## Declarative enable and presets

Three project-owned files in `.devcontainer/` control the full allowlist:
`firewall-allowlist`, `firewall-enable`, and `firewall-presets`. The helper
reads them from the read-only `/workspace/.devcontainer` mount.

`firewall-enable` is a marker. Only its presence counts. The rules do not
survive a restart, so the marker acts on every start, in three places:

1. The managed Compose `command` of the devcontainer runs
   `/usr/bin/sudo -n /usr/local/bin/aic-firewall auto` when the marker
   exists, then `exec sleep infinity`. If `auto` fails, the command exits and
   the container stops. This also covers a plain `docker start`.
2. `apply_declared_firewall()`, the first post-create step, runs `auto` again.
   Dev Containers can start post-create while step 1 still resolves DNS. If it
   fails, `main()` skips `refresh_ai_tools` and `run_project_hook`.
3. `postStartCommand` runs `auto` again when the marker exists, and `waitFor`
   is `postStartCommand`. Thus `devcontainer up` returns, and VS Code opens a
   terminal, only after step 1. Without the marker it runs nothing, so an
   older build-mode image without `auto` still starts.
4. `aic shell` and `aic run` use `devcontainer exec`, which skips
   `postStartCommand`. `ensure_declared_firewall()` in `lifecycle.sh` runs
   `auto` first and stops the command when it fails.

`auto` takes the lock (a `flock`, which the kernel releases when the holder
exits, so a crash never blocks the next start). With an active generation it
does nothing. Otherwise it runs the same path as `enable`.

`firewall-presets` selects names from the fixed `preset_domains()` table in
`template/aic-firewall`. The hosts come only from that root-owned table.
An unknown name aborts the change, and the active policy stays the same.
`FIREWALL_PRESETS` in `lib/validate.mjs` holds the same names, so the host
gate refuses an unknown name as a MANAGED finding before Docker starts.

Follow these rules:

- Keep each preset at the minimum hosts that the default client needs, from
  the documentation or the source of the registry. Never add a preset host to
  `DEFAULT_ALLOWLIST`.
- Never let a preset file or the marker name a host, a port, or an option.
- `auto` must never remove a rule. Without the marker, it does nothing.
- These files are not trust findings. The allowlist can only restrict the open
  default, so a repository cannot get more egress with them than without
  them. If the allowlist ever becomes a default, make a preset selection a
  trust finding first.

Guarded by `tests/test-aic-firewall-presets.sh`, the firewall-presets cases in
`tests/test-aic-validate.mjs` and `tests/test-aic-host-security.sh`, the
declared-firewall cases in `tests/test-aic-post-create-reset.py`, and the
"declared firewall is on at every start" smoke.

## Runaway limit

Both Compose templates set `pids_limit: 4096` on the devcontainer. This is a
backstop for a fork bomb or a stuck loop.

There is deliberately *no* `mem_limit`. A fixed memory ceiling would OOM-kill
legitimate heavy builds. Memory and CPU caps are documented as an override
instead.

The Docker-mode test also asserts that `pids_limit` is present.
