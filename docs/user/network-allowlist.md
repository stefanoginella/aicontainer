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

## What the allowlist does not stop

The allowlist limits where data can go. It does not make exfiltration
impossible:

- *Allowed hosts accept writes.* An agent can upload to `github.com` /
  `api.github.com` (gists, repositories, pull requests) with any token in the
  container. It can publish to `registry.npmjs.org` (with an npm login). It
  can send data to `api.anthropic.com` / `api.openai.com` with a key of its
  own. Every host that you add to `firewall-allowlist` is the same. There is
  no read-only profile: the default list is fixed, and the file can only add
  hosts.
- *DNS stays open.* The firewall accepts queries for any name to the
  configured resolvers (and to the Docker embedded resolver). Thus data can
  go out inside DNS queries.
- *Rules match IP addresses, resolved one time.* `enable` resolves each name
  to the addresses that it has at that moment. The firewall also allows all
  other hosts that share one of those addresses. If the addresses of a host
  change later, you possibly must run `sudo aic-firewall enable` again.
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
  rules do not stay when the container is created again.
- The firewall needs only `NET_ADMIN`. `NET_RAW` stays dropped. If IPv6 is
  configured but the firewall cannot filter it, `enable` refuses a policy that
  IPv6 can bypass.
- When the host-global [agent status relay](status-relay.md) is enabled, the
  firewall accepts its dedicated resolved IP set on TCP 8787 only. The
  firewall never puts the host gateway in the general all-port domain set.

See also [Threat model](security.md).
