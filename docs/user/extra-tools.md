# Install extra tools

This page shows two ways to add tools to the container: a temporary install
in the running container, and a persistent install in a project Dockerfile. It
also gives a complete recipe for Playwright.

Select the method that agrees with the tool:

- A tool that you use for a short time: install it ad hoc.
- A tool that the project needs: put it in a project Dockerfile.

**Rule of thumb:** put the tool in `Dockerfile.project` if you do not want to
install it again after each container rebuild. If you only want to try
something, install it ad hoc.

## Install a tool ad hoc in the running container

Use this method for tools that you need for an hour:

```bash
aic shell
uv tool install <python-cli>      # ruff, semgrep, ...
npm install -g <node-cli>
```

`aic destroy` and `aic rebuild` **remove these tools**. This method is good
for exploration. Do not use it for tools that your project needs.

> **Note:** `sudo` inside the container works only for three wrappers with a
> fixed purpose: `aic-chown-volumes`, `aic-lock-user-config`, and
> `aic-firewall`. aic denies bare `apt-get`, `chown`, and similar commands. To
> install apt packages, use a reviewed project Dockerfile (see below) and
> `aic rebuild`.

## Install a tool persistently in a project Dockerfile

Use this method for tools that your project needs. Examples are language
runtimes, DB clients, and linters that other team members also need.

1. Create `.devcontainer/Dockerfile.project`:

   ```dockerfile
   # Match the tag your .devcontainer/docker-compose.yml pins (set by `aic init`
   # to your installed aic version). This tag is project-owned, so `aic sync`
   # never rewrites it — after `npm update -g aicontainer`, sync re-pins
   # docker-compose.yml and WARNS that this FROM has drifted; run
   # `aic sync --bump-base` to rewrite it to match. (If it drifts and an override
   # build: points here, the stale base is what actually runs — see below.)
   FROM ghcr.io/stefanoginella/aicontainer:vX.Y.Z

   USER root
   RUN apt-get update && apt-get install -y --no-install-recommends \
         postgresql-client redis-tools terraform \
       && rm -rf /var/lib/apt/lists/*

   USER vscode
   RUN uv tool install ruff \
       && uv tool install pre-commit
   ```

2. Refer to the Dockerfile from `.devcontainer/docker-compose.override.yml`.
   This file is safe from `aic sync`. Do not edit the managed Compose file.

   ```yaml
   services:
     devcontainer:
       # Required: give the build its own tag. Compose names a build's output
       # after whatever `image:` resolves to, and the managed Compose file
       # resolves it to the SHARED ghcr.io/stefanoginella/aicontainer:vX.Y.Z —
       # so without this line the build silently re-tags the base image on your
       # machine and hands this project's image to every other aic project. aic
       # refuses a build tagged like the shared image.
       image: myproject-devcontainer:vX.Y.Z
       build:
         context: .
         dockerfile: Dockerfile.project
   ```

3. Run `aic sync`.
4. Examine the resolved warning.
5. Run `aic trust` one time.
6. Run `aic rebuild`.

> **Note:** `aic up` is not sufficient here. It uses the cached image again
> (`pull_policy: missing`) and never runs the build. Thus the container starts
> on the plain base image without your additions.

The tools then stay after rebuilds. The project keeps their versions with the
project files.

### Why a custom build needs `aic trust`

A project Dockerfile runs as root while Docker builds the image. It can
replace each sandbox helper. Thus aic treats each custom build as an expansion
of the host boundary. This is also true when its `FROM` is the official base.

The trust is for the exact hash of the related config. If you change the
Dockerfile or the override, aic asks you to review again.

### Keep the build context in `.devcontainer/`

The example uses `context: .` on purpose. It limits the build context to
`.devcontainer/`, so the persistent trust hash covers its contents.

A build context outside that directory (for example, `context: ..`) can change
through any project file. Thus `aic trust` does not keep a persistent approval
for it. Each reviewed `aic up` or `aic rebuild` must then use
`--allow-unsafe`.

### Build mode

If you ran `aic init --build`, do these steps instead:

- Use `FROM aicontainer-base:latest`.
- Put only `build.dockerfile: Dockerfile.project` in the override.

The same explicit trust step applies.

## Recipe: Playwright (browser tests, automation, MCP)

You *cannot* add a browser ad hoc in this container, for two reasons:

- Chromium needs apt system libraries, and aic blocks `sudo apt` at runtime.
- If you enabled the [firewall](network-allowlist.md), the CDN for the
  browser download is not on the allowlist.

`Dockerfile.project` solves both problems. Image builds have full network
access. Thus Chromium goes into the image and works offline after the build.
This is also true with the firewall on.

```dockerfile
# .devcontainer/Dockerfile.project
FROM ghcr.io/stefanoginella/aicontainer:vX.Y.Z   # match your pinned tag

# Pin to the Playwright version your project uses (the @playwright/test in
# package.json), so the baked browser revision matches what resolves at runtime.
ARG PLAYWRIGHT_VERSION=1.50.0

USER root
# Chromium's system libraries. apt is root-only and runtime `sudo apt` is
# blocked, so this step has to live in the image.
RUN eval "$(fnm env)" \
    && npx --yes playwright@${PLAYWRIGHT_VERSION} install-deps chromium

USER vscode
# Download Chromium into ~/.cache/ms-playwright, baked into the image layer.
# This explicit step is REQUIRED: the base image sets NPM_CONFIG_IGNORE_SCRIPTS
# =true, so `npm i @playwright/test` won't auto-download the browser via its
# postinstall — you have to run `playwright install` yourself.
RUN eval "$(fnm env)" \
    && npx --yes playwright@${PLAYWRIGHT_VERSION} install chromium
```

Then:

1. Add the project-owned override `build:` block from
   [step 2 above](#install-a-tool-persistently-in-a-project-dockerfile).
2. Run `aic sync`.
3. Run `aic trust`.
4. Run `aic rebuild`.

### Notes for Playwright

- **If Chromium does not start, disable its sandbox.** The capability and
  seccomp setup of your Docker runtime can prevent the Chromium sandbox from
  starting inside the container. If you get launch errors, set
  `chromiumSandbox: false` in `playwright.config.ts`. For ad-hoc launches, use
  `--no-sandbox`. This is the standard fix for Chromium in Docker.
- **Tests on `localhost` need no firewall change.** Loopback is always
  allowed. Thus you can test your own dev server also when the allowlist is
  enabled. You must add hosts to `.devcontainer/firewall-allowlist` only when
  the browser goes to the public internet with the firewall on.
- **Playwright [MCP](https://github.com/microsoft/playwright-mcp)**
  (`@playwright/mcp`) uses the same Chromium in the image. Add it to
  `mcpServers`. aic seeds it from your host config like all other MCP servers.
  Thus one recipe is sufficient for `playwright test` and for browsing through
  MCP.
