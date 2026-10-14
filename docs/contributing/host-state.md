# Generated host state

Read this page before you change the generated `.devcontainer/.env`, the Docker socket resolution (`docker_runtime_kind()`, `docker_socket_bind_source()`, `resolve_docker_socket()`), or the agent-status relay consent and its firewall exception.

This page ends the host-side rules. See also [Project identity and the host control boundary](project-identity.md) and [Host-side validation](validation.md).

## The selected local Docker socket

The selected local Docker socket is generated host state. `aic init`, `aic sync`, and each call of the generated `aic initialize` do these steps:

1. They resolve the `unix://` endpoint of the active context.
2. They derive the runtime UID:GID for Dev Containers.
3. They atomically write `.devcontainer/.env` again.

The managed `template/gitignore` is copied as `.devcontainer/.gitignore`, and it excludes that file. So rootless Docker, Docker Desktop, Colima, and OrbStack work without flags and without machine-specific diffs.

### The project name in `.env`

`.devcontainer/.env` also holds `AIC_PROJECT_NAME`, the path-unique Compose project name. The committed name line of the Compose file reads it (see [Project identity](project-identity.md#path-unique-project-name)). The same writes create it, and the same exact-content check covers it:

- `write_runtime_environment_file()` writes one fixed set of keys in one fixed order.
- `validate_runtime_environment_file()` compares the whole file with the expected content. A changed value, an added key, or a duplicate key (Compose takes the last one) is a finding.
- `aic validate` is read-only. It does not write `.env`: it exports `AIC_PROJECT_NAME` for its own Compose calls. A missing `.env` is not a finding.
- A `.devcontainer/.env` that Git tracks is a MANAGED finding in the gate and a failure in `doctor` (`runtime_environment_file_tracked()`). Rules for that query:
  - It matches every letter case (`:(icase)` pathspec), because `.devcontainer/.ENV` is the same file on a case-insensitive volume.
  - It fails closed. `git ls-files` exits 0 for a match and for no match, so the output decides. Any other exit status is a finding.
  - It runs only when `git_control_path_problems()` reports nothing. A planted `.git/commondir` would make host Git read the config of another directory. That problem is already a finding.
  - It runs host Git with `core.fsmonitor` off.

### Host values in the environment

Compose substitutes every key of `.devcontainer/.env`, and a value in the
environment wins over the file. `aic` commands export their own values
(`export_runtime_environment()`). A direct Dev Containers start has only the
environment of the editor. So:

- The `aic` entry script records which of `AIC_DOCKER_SOCKET`,
  `AIC_RUNTIME_USER`, `AIC_STATUS_RELAY`, `AIC_STATUS_PROJECT`, and
  `AIC_STATUS_PROJECT_ID` it inherited (`aic_runtime_env_keys`). Keep that
  list equal to the keys of `write_runtime_environment_file()`.
- `check_devcontainer_project_name()` refuses each inherited key, an empty one
  too. It names the key, never the value. The callers are the same as for
  `AIC_PROJECT_NAME` (see [Project identity](project-identity.md)).
- `aic up` and `aic rebuild` run `devcontainer up` through
  `without_runtime_environment()`. Thus the `aic initialize` child inherits
  none of these keys, and Compose reads them from `.devcontainer/.env`.

Guarded by the inherited-variable cases in `tests/test-aic-host-security.sh`.
They read the keys from a generated `.env`, so a new key without a refusal
fails the test.

Hard rules:

- Do not trust `AIC_DOCKER_SOCKET` from the environment or from the repository.
- Do not trust `AIC_PROJECT_NAME` from the environment or from the repository. `aic` exports its own value, and a direct start refuses a different one.
- Do not accept a remote TCP/SSH endpoint.
- Do not make the dotenv grammar wider.
- Keep `.env`/`.gitignore` in the control-path checks and in the template copies.

### The bind source as the daemon sees it

`AIC_DOCKER_SOCKET` is the bind source as the **daemon** resolves it. It is not the host socket that the Docker CLI talks to.

A VM daemon cannot mount the macOS path of the context. Docker Desktop refuses it. In Colima/Lima, it is a forwarded socket. Thus:

- `docker_runtime_kind()` asks the selected socket itself (`docker -H unix://<socket> info`).
- `docker_socket_bind_source()` returns the fixed `/var/run/docker.sock` only for a rootful Docker Desktop, Colima, Lima, or Rancher Desktop daemon.
- Every other daemon keeps the host path.

### Rules (do not change)

1. **The choice is binary.** The bind source is the resolved host path or the one fixed VM path. Never take a path from `docker info`, the environment, or a template.
2. **Never remap rootless Docker.** In the namespace of a rootless daemon, `/var/run/docker.sock` can be another, rootful daemon. A remap would give the socket proxy and `aic-chown-volumes` more authority than the user selected.
3. **Docker Desktop is the exact `OperatingSystem` string.** `aic` identifies Colima/Lima/Rancher by the VM hostname (`Name`). A Linux host can have the same hostname.
   - On Linux, the socket must also be the default path of that runtime. So `aic` does not detect Colima with `--hostname` on Linux.
   - macOS has no native daemon. So on macOS, the name or the default socket path of Colima/Lima/Rancher is sufficient.
4. **Only a complete answer counts.** The answer must contain the OS, the name, and the security-options list. Otherwise it is "no answer". A cut-off answer cannot prove that the daemon is rootful.
5. **One probe per process.** `export_runtime_environment()` caches the bind source. The cache is initialized at script start, never from the environment. So a daemon that starts between the `.env` write and the validation cannot make the gate fail.
6. **Use the same daemon as Compose.** `resolve_docker_socket()` and `doctor` follow the order of the Docker CLI: `DOCKER_HOST` beats `DOCKER_CONTEXT`.
7. **Default paths decide only while the daemon cannot answer** (`aic init`/`sync` with Docker stopped). Every start path writes `.env` again with the answer of the daemon before validation. Lima is not part of that fallback, because its default template is rootless.

Guarded by `tests/test-aic-docker-runtime.sh`, which fakes the `docker info` output and the host OS of each runtime.

## The agent-status relay as host consent

The agent-status relay is generated host consent too.

- It is off by default.
- Only the exact, non-symlinked `$HOME/.config/aicontainer/status-relay` marker can enable it.
- Repository Compose or devcontainer input cannot set it or redirect it.

The marker path is fixed. It does not come from XDG. The Compose seed mount and `prepare_host_seed_paths()` hardcode the same directory. A second root would make a correctly written marker silently do nothing.

Resolved-config validation protects the managed environment values: `AIC_STATUS_RELAY`, `AIC_STATUS_PROJECT`, and `AIC_STATUS_PROJECT_ID`.

### The relay hook

The root-owned hook sends only the fixed schema that `tests/test-aic-agent-status-relay.py` covers.

- It sends to `http://host.docker.internal:8787/events`.
- Proxies and redirects are disabled.
- Timeouts and errors are fail-open.

Its label validation must continue to accept the full `expected_project_label()` alphabet, a leading `_`/`-` included. Otherwise the affected projects lose every event, and no diagnostic shows it anywhere.

> **Warning:** Do not add prompt, response, path, transcript, tool input/result, or error content to the relay schema.

### The firewall exception

Keep the strict firewall exception as an exact TCP-8787 status ipset rule. It must never give general reachability to the host gateway.

`aic-firewall` reads the relay mode only from `/workspace/.devcontainer/.env`. The pre-Docker gate checks that file against the host state, and the agent cannot write the read-only mount. The value only turns the fixed host and port rule on or off.

> **Warning:** Do not read the mode from the environment. sudo resets it, and `/proc/1/environ` needs `CAP_SYS_PTRACE`, because PID 1 runs as `vscode`. Without that capability the rule is never added.

Guarded by `tests/test-aic-firewall-relay.sh` and the "firewall allows the opted-in status relay on its port only" smoke.

The exception must also stay strengthen-only in the other direction. `host.docker.internal` sometimes does not resolve (plain Docker Engine, rootless Docker), or it resolves into a prohibited range. Then `enable` warns and omits that one rule.

> **Warning:** Do not let `enable` abort and leave the project with no allowlist. Observability must not remove policy.

For the same reason, `aic status` reports the marker together with the applied `.env` value. A diagnostic that reports an unapplied relay as active is a wrong diagnostic.
