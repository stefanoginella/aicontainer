# Commit signing

This page explains how to sign commits inside the sandbox with `aic signing`.
It also explains the risks of a signing key that the agent can read.

## Why host signing does not work in the sandbox

You can sign commits on your host (`commit.gpgsign=true`, SSH or GPG). This
does not work inside the sandbox by default. Your signing key is on the host,
and aicontainer does **not** forward `~/.ssh` or the SSH agent on purpose (see
the [threat model](security.md)). Without a change, Git fails every commit
with `Couldn't find key in agent`.

So when a host signs commits and has no sandbox key, aicontainer turns signing
**off inside the container**. Commits succeed, but they are unsigned.
aicontainer prints a one-line notice. This is better than a `git commit` that
fails with an unclear error.

## Set up a sandbox-only signing key

To get signed commits *and* keep the boundary, make a **sandbox-only signing
key** with `aic signing`:

```bash
aic up                 # the container must be running
aic signing auto       # make an ed25519 signing key in the aic-auth-global volume
                       #   (add --register to push its pubkey to GitHub via gh)
aic rebuild            # apply — post-create wires the key into the container gitconfig
```

`aic signing auto` prints the public key. Register it on GitHub as a
**Signing Key**:

1. Go to Settings → SSH and GPG keys → New.
2. Select *Signing Key*, **not** Authentication.

As an alternative, pass `--register`, and `gh` registers the key. This needs
the `write:ssh_signing_key` scope.

## Other modes

- `aic signing byok` — install a *separate* signing key that you supply. Use
  `aic signing byok < your_key`, or put the key at
  `~/.config/aic-auth/signing/id_ed25519`.
- `aic signing disable` — keep commits unsigned in the sandbox. This also
  stops the notice.
- `aic signing status` — show the current state.

## Where the key is and when it applies

- The key is only in the `aic-auth-global` volume. It is never on your host.
- All your projects share the key, so you register it one time.
- The key stays after a rebuild.

aicontainer applies your choice on the next `aic rebuild`. At that time it
validates `/etc/aic/user-config/gitconfig` and creates it as root-owned 0444.
There is no command that unlocks or updates this file while the container
runs.

## What "Verified" means

The signing key is where the AI runs. So GitHub shows the commits of the agent
as **Verified**. This is correct if your goal is a branch-protection rule
*"require signed commits"*. But "Verified" does *not* tell you that a human
reviewed the commit.

To keep sandbox commits separate and revocable on their own, use a different
signing key for the sandbox. You can also use a different committer identity.

## The agent can read and copy this key

> **Warning:** Register a key that exists only for the sandbox. The agent can
> read and copy this key.

The private key is a file. The same user that runs the agent owns this file.
**Every** aicontainer project mounts the same key. A compromised agent in any
project can copy the key out. The network is open unless you enable the
[allowlist](network-allowlist.md). Even with the allowlist, an allowed host
such as GitHub accepts the upload.

After you register the public key on GitHub (with `--register`, or by hand),
the person with the copy can sign commits from any location. GitHub shows
these commits as **Verified** until you delete the key from your GitHub
account. So:

- Register a key that exists only for the sandbox. Never register a key that
  you also use on your host. This also applies to `byok`.
- Do not use "Verified" on a commit as proof that the commit came from you or
  from a reviewed sandbox session. Keep human review (pull-request approval,
  protected branches) as the gate.
- If you think that the key leaked, first delete the key on GitHub under
  *Settings → SSH and GPG keys*. `aic signing disable` only stops signing in
  the sandbox. The key file stays in the volume.
- To replace the key, do these steps:
  1. In a running container, delete `~/.config/aic-auth/signing/id_ed25519`
     and `id_ed25519.pub`.
  2. Run `aic signing auto` again.
