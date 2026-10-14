# Opt-in network allowlist

This page explains the bundled iptables allowlist (`aic-firewall`). It shows
how to enable it, what it does not stop, and how it works.

## Enable the allowlist

Use the allowlist for projects where you want stricter containment. Examples:
you review untrusted code, you work on a corporate LAN, or you want strong
protection against exfiltration. Enable the allowlist from inside the
container:

```bash
aic shell
sudo aic-firewall enable          # apply the DROP-default policy with the curated allowlist
sudo aic-firewall status          # show the rules and the resolved IPs
```

The default allowlist covers these hosts:

- Anthropic
- OpenAI
- OpenCode (`opencode.ai`, `models.dev`)
- GitHub
- npm
- PyPI
- Docker registries

To add hosts for one project, put them in `.devcontainer/firewall-allowlist`.
Write one validated domain on each line. `#` comments are permitted. After you
edit the file, run `sudo aic-firewall enable` again.

The file cannot open the host or the services of the stack. `enable` refuses
`localhost`, `*.localhost`, `*.internal` (for example `host.docker.internal`),
the managed service names (`socket-proxy`, `aic-auth-sync`,
`aic-seed-sanitizer`, `devcontainer`), and every entry that resolves to the
host gateway or to a managed service. The active policy then stays the same.

## Enable the allowlist on every start

The firewall rules do not survive a container restart. To turn the firewall on
for a project at every start, add an empty marker file on the host and commit
it:

```bash
touch .devcontainer/firewall-enable
aic rebuild
```

When the marker exists, these steps occur on every start:

1. The start command of the container runs `sudo aic-firewall auto`. This
   occurs before post-create and before you can open a shell. It also occurs
   when Docker starts a stopped container directly.
2. If the firewall cannot be enabled (for example, DNS does not work), the
   container stops. Read the cause with `docker logs`.
3. post-create, `postStartCommand`, `aic shell`, and `aic run` wait for step
   1. Thus `aic up` returns, VS Code opens a terminal, and `aic shell` opens a
   shell only when the firewall is on. If the firewall is not on, `aic shell`
   and `aic run` stop with an error.

aic reads only the presence of the marker. Its content has no effect. The
marker can only turn the firewall on. It cannot remove a rule.

To turn the firewall off again, remove the marker on the host, then run
`aic rebuild`.

With the marker, post-create keeps the Claude Code and Codex versions of the
image. Their updates need `downloads.claude.ai` and `releases.openai.com`,
which are not on the default allowlist. See [Updating](updating.md).

## Add registry presets

The default allowlist has npm and PyPI as package registries. For other
stacks, select presets. A preset is a fixed set of hosts in the image. List one
preset name on each line in `.devcontainer/firewall-presets`. `#` comments are
permitted:

```
# .devcontainer/firewall-presets
crates
go
```

| Preset | Hosts |
|---|---|
| `crates` | `index.crates.io`, `static.crates.io` |
| `go` | `proxy.golang.org`, `sum.golang.org` |
| `maven` | `repo.maven.apache.org` |
| `nodejs` | `nodejs.org` |
| `packagist` | `repo.packagist.org` |
| `rubygems` | `rubygems.org`, `index.rubygems.org` |
| `semgrep` | `semgrep.dev` |

The [Stack reference](stack-reference.md) names the presets for each stack.

Each preset has only the hosts that the default client of the registry needs:

- `go`: a module that the proxy does not have falls back to its source
  host. Add that host to `firewall-allowlist`.
- `packagist`: Composer downloads most packages from GitHub, which the default
  allowlist already has.
- `maven`: Gradle plugins also need `plugins.gradle.org`. Add it to
  `firewall-allowlist` if you use them.
- `semgrep`: Semgrep also sends metrics to `metrics.semgrep.dev`. The firewall
  blocks it, and Semgrep continues. Use `--metrics=off` to skip the attempt.

A preset name that is not in the table stops the start: `aic` refuses the
project before Docker starts, and `aic-firewall` refuses the file. A preset
adds hosts only when the firewall is on. After you edit the file, run
`sudo aic-firewall enable` again, or restart the container.

## What the allowlist does not stop

The allowlist limits where data can go. It does not make exfiltration
impossible:

- *Allowed hosts accept writes.* An agent can upload to `github.com` /
  `api.github.com` (gists, repositories, pull requests) with any token in the
  container. It can publish to `registry.npmjs.org` (with an npm login). It
  can send data to `api.anthropic.com` / `api.openai.com` with a key of its
  own. Every host that you add to `firewall-allowlist` or with a preset is
  the same (for example, `rubygems` lets an agent push a gem to
  `rubygems.org` with an API key of its own). There is no read-only profile:
  the default list is fixed, and the files can only add hosts.
- *A proxy preset can relay reads.* `proxy.golang.org` fetches a module path
  that it does not have from the origin host of that path. Thus with the `go`
  preset, the agent can make the proxy send GET requests to any domain, and
  can encode data in the module path.
- *DNS stays open.* The firewall accepts queries for any name to the
  configured resolvers (and to the Docker embedded resolver). Thus data can
  go out inside DNS queries.
- *Rules match IP addresses, resolved one time.* `enable` resolves each name
  to the addresses that it has at that moment. The firewall also allows all
  other hosts that share one of those addresses. `enable` also writes each
  allowed name with these addresses into `/etc/hosts`, so programs in the
  container connect only to them. Many hosts are on a CDN, which gives
  different addresses at different times. If an address stops working later,
  restart the container or run `sudo aic-firewall enable` again. Tools that
  query DNS directly (`dig`, `nslookup`) do not read `/etc/hosts` and can show
  other addresses, which the firewall blocks.
- *It applies from the moment you run it.* It does not undo what the agent
  did before: data that it read or sent, code that it installed. Run `enable`
  before you start the agent.

## Design notes

- The script is **enable-only**. When you enable it again, it builds inactive
  IPv4/IPv6 rule generations. It rejects zero-result or prohibited metadata
  resolutions. Then it switches the new generations into use atomically. If a
  step fails, the prior DROP policy stays active. The firewall never flushes
  the metadata chains.
- The firewall also cuts the connections that the container opened **before**
  `enable`, unless their destination is on the allowlist. The firewall accepts
  established packets only as replies to sessions that started from outside.
  It never accepts them as a continuation of an outbound session.
- To turn the firewall off, run `aic rebuild` from the host. The firewall
  rules do not stay when the container is created again. With
  `.devcontainer/firewall-enable`, remove the marker first.
- The agent in the container cannot turn the firewall off or change the
  presets. `.devcontainer/` is read-only in the container, the helper has no
  `disable` command, and the preset hosts are in the root-owned helper.
- The three project files (`firewall-enable`, `firewall-presets`,
  `firewall-allowlist`) need no `aic trust`. The firewall only restricts the
  open default, so a file in a cloned repository cannot give more egress than
  a project without the files. Review them as part of the repository.
- The pins in `/etc/hosts` are in a managed block between
  `# BEGIN aic-firewall` and `# END aic-firewall`. `enable` replaces the block.
  `sudo aic-firewall status` shows the number of pinned addresses. The agent
  cannot change the file.
- The firewall needs only `NET_ADMIN`. `NET_RAW` stays dropped. If IPv6 is
  configured but the firewall cannot filter it, `enable` refuses a policy that
  IPv6 can bypass.
- When the host-global [agent status relay](status-relay.md) is enabled, the
  firewall accepts its dedicated resolved IP set on TCP 8787 only. The
  firewall never puts the host gateway in the general all-port domain set.

See also [Threat model](security.md).
