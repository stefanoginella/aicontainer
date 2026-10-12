# Updating

This page explains how to update the AI tools in the container and how to
update aicontainer itself. It also explains drift warnings, image tags,
`aic sync`, the migration of old projects, and the one-time upgrade steps.

## Update the AI tools

Claude Code, Codex, and OpenCode update to their latest release **on every
`aic rebuild`**. This occurs in pull mode and in build mode. Each time the
container is created or recreated, `post-create.py` does these steps:

- It runs `claude update`.
- It runs the official unattended Codex installer again.
- It runs `opencode upgrade`.

The pinned image is only the baseline below these updates. The three updates
run at the same time. They start after your Git identity and settings are in
place.

```bash
aic rebuild   # in a project: recreate the container → all enabled CLIs update to latest
```

The refresh is fail-soft. With no network, the container keeps the version
that is baked into the image, and the container still starts.

For a fully reproducible sandbox, pin the tools too. Set `AIC_FREEZE_TOOLS=1`
in `.devcontainer/docker-compose.override.yml`.

> **Note:** Codex and OpenCode install through their official standalone
> installers (not npm). This is the same method as the native Claude
> installer. Codex refreshes when its installer runs again without prompts.
> OpenCode uses `opencode upgrade`. The `NPM_CONFIG_MIN_RELEASE_AGE` npm
> quarantine does not apply to these two CLIs. The quarantine still applies to
> npx-based MCP servers.

## Update aicontainer

Use these steps to update **aicontainer itself**. This includes the `aic` CLI,
the template, and the pinned base image (base OS, Node, semgrep, hooks, …).

```bash
npm update -g aicontainer   # latest aic + template
aic sync                    # in each project: re-pin compose to the new aic version
aic rebuild                 # in each project: pull the new image
```

The pull-mode Compose file pins `ghcr.io/stefanoginella/aicontainer:vX.Y.Z`.
The version is the aic version that ran `aic init` (or the last `aic sync`).
It is not `:latest`. This pin keeps the CLI and the filesystem layout in the
container (hooks, sudoers, helper scripts) in agreement.

To get a new image, update aic and run `aic sync` first. `aic rebuild` alone
does not change the pinned tag.

## Drift warnings

aic tells you when these versions drift, so that you see a stale container:

- **`aic up` / `aic shell` / `aic rebuild`** print a warning when the pinned
  image tag of this project and your installed `aic` are different. This
  check is offline (no network). You get this state after
  `npm update -g aicontainer` and before you run `aic sync` again. The warning
  tells you to run `aic sync && aic rebuild`.
  - On `aic rebuild`, the warning shows *before* the pull. This helps you,
    because `rebuild` pulls the currently pinned tag again. You can stop the
    command and run `aic sync` first, so you do not download the stale image
    again.
  - Build-mode projects have no pinned tag, so aic does not check them.
- **VS Code "Reopen / Rebuild in Container"** uses the host-side initializer
  that aic generates. The initializer does these tasks:
  - the same drift check
  - fail-closed config validation
  - seed preparation
  - legacy-session migration

  The output goes to the **Dev Containers output channel**. If the host CLI is
  missing, the start stops and shows an install command. The start stops
  because a silent skip would also skip the security boundary. The
  direct-bootstrap caveat for control files that a repository supplies still
  applies. See [Usage](usage.md).
- **`aic version` / `aic upgrade`** tell you when a newer `aicontainer` is
  published to npm. aic keeps this result in a cache for one day. The check
  fails silently when you are offline. CI runs skip this check.

To silence the two warnings, set `AIC_NO_UPDATE_CHECK=1`.

## Image tags

After publication, a `:vX.Y.Z` tag does not change. It holds the exact image
that CI built at release time.

CI also rebuilds the floating `:latest` tag and a weekly tag. These images get
refreshed base layers and do not use a stale build cache. Managed projects
stay on the immutable version tags.

If you prefer the floating track, use a reviewed `Dockerfile.project` that is
based on `:latest`. Do not edit the managed Compose file for this.

In `--build` mode, `aic rebuild` also does a local build with no cache.

## Sync the managed files

`aic rebuild` alone does not refresh the managed files under
`.devcontainer/`. After you upgrade, do these steps:

1. Run `aic sync`.
2. Review the diff.
3. Rebuild.

Sync does these things:

- It keeps your tool and shell selections.
- It keeps a Docker mode that you gave consent to before.
- It does not change project-owned files.
- It switches modes cleanly, with no stale build artifacts.

## Migration of old projects

The same sync migrates old projects that use the folder name (basename) as
their scope. After sync, the Compose name comes from the canonical project
path, and it is always the same for the same path.

On the next sync, `up`, or VS Code open, aic copies the legacy transcript
volume automatically only when both conditions are true:

- The exact workspace label, project label, and session mount of an existing
  container prove ownership.
- No container with a different owner also mounts the volume.

aic stops a legacy stack only when all of these conditions are true:

- The stack has an exact owned primary container.
- No container has a conflicting owner.
- The stack has no unknown service. Known unlabeled aic sidecars are allowed.
  aic never removes arbitrary orphan containers.

Sometimes no container remains that shows the owner of a basename volume that
projects shared in the past. Then the steps are:

1. Sync does not change the volume.
2. The next interactive `aic up` asks one time if you want to import it.
3. The default answer is no. aic then starts with a fresh volume and keeps the
   old volume.

A direct VS Code start or another non-interactive start stops with the same
`aic up` hint. It stops because an import could disclose transcripts to
another project.

An upgrade with proven ownership needs no new login and no manual volume
command. Two checkouts with the same folder name no longer collide.

aic also migrates the legacy container-side `~/.claude-sessions` layout to the
`~/.aic-sessions` volume path. That path is not specific to one tool.

## Upgrade friction

For an ordinary project, or a project with proven ownership, the full
migration is still one command line:

```bash
npm update -g aicontainer && aic sync && aic rebuild
```

These items carry forward:

- existing logins
- transcripts
- tool and shell choices
- `gh` and npm logins

These items need one decision or one extra step:

- **Docker exposure.** Older releases had no Docker consent record outside the
  repository. So their inherited Docker exposure resets one time to `none`.
  If you need Docker access, enable it again with `aic sync --docker-read` or
  `aic sync --docker`.
- **An ambiguous basename volume from the past.** This adds the other one-time
  decision (see [Migration of old projects](#migration-of-old-projects)).
  Clean generated projects add no prompt.
- **`gh` and npm settings.** Settings in the old shared files (`gh`
  aliases/pager, npm `registry`, …) do not carry forward. They stay behind
  because any project could write them. If you need these settings, set them
  again in each project.

> **Warning:** Sync all your projects. Until you sync a project, an older
> project still mounts that shared config.
