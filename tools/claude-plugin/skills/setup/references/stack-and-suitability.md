# Stack detection and suitability: the judgment

The stack → files mapping is **not** here. It lives in the user guide,
`docs/user/stack-reference.md` (fetched in SKILL.md Step 1): marker files per
language, toolchain lines, named volumes + `chown-paths`, post-create steps,
editor extensions, firewall presets, the shared files, how to combine stacks,
and the fit matrix. Keep it there — one rule in one place.

This file carries only what a marker table can't: reading signals that need
judgment, and what to do with a project that doesn't fit.

## 1. Signals beyond the marker files

The page's "Detect a stack" table maps manifests and lockfiles to stack
sections. Also read these — they shape the plan but aren't a language:

| Signal | Inference |
|---|---|
| `docker-compose.yml` services (postgres, redis, mysql, mongo, …) | The app depends on those services → host-service wiring (`host.docker.internal` in the override) or sibling containers |
| `.env.example` / `.env.sample` keys (`DATABASE_URL`, `REDIS_URL`, `*_HOST`) | Same — the service must be reachable; wire it via the override with **literal** dev values, never a host-variable pass-through |
| ORM / migration config (Alembic, Prisma, Rails `db/`, Django `migrations/`) | A DB is expected at dev time; ask whether it runs on the host |
| `@playwright/test` / `cypress` / `puppeteer` in deps | Browser e2e → `Dockerfile.project`; the page links the Playwright recipe |
| `.md` design docs (ARCHITECTURE, PRD, TECH-STACK, DESIGN, specs, `docs/`, `_bmad-output`, `.specstral`, `.specify/`) | Authoritative when code is sparse — a spec naming the stack is a real signal |
| `*.csproj` / `*.sln`, `mix.exs`, `pubspec.yaml`, `Package.swift`, `*.xcodeproj` | A stack the page has no section for (or a likely non-fit) — see section 2 |

When the entire manifest glob comes back **empty** (greenfield /
pre-first-commit repos — e.g. a repo holding only `.git` and `.specstral/`),
the design-doc row stops being a supplement and becomes the *primary* signal: a
ratified spec (`.specstral/architecture.md`, an ADR, a pinned TECH-STACK) can
carry the full version-pinned stack. Read it before falling back to asking the
user; only ask when even the docs are silent. Greenfield also means the
post-create steps must be guarded on the manifest existing — the page's steps
already are; keep them that way.

Output of this step: **language(s) + package manager(s) + runtime versions +
services + test tooling + GUI/mobile/native/hardware flags.**

## 2. Projects the page doesn't cover, or that don't fit

- **Version pins the page can't meet.** The page's toolchains come from the
  base image or Ubuntu packages (Ruby 3.2, PHP 8.3, JDK 21 or 17, Go via
  `GOTOOLCHAIN=auto`). A `.ruby-version` asking for Ruby 3.3, say, is outside
  it. Say so; don't silently hand-roll a version manager into
  `Dockerfile.project`.
- **Stacks with no section** (.NET 5+, Elixir, Dart, Swift on Linux) can fit,
  but nothing on the page is tested for them. Offer only the common files and
  the pattern of the stack sections, mark the toolchain lines as untested, and
  get an explicit yes.
- **Non-fits** (the page's "Check the fit" list): state it plainly, name what
  specifically won't work, and look for a **partial** win — a repo is often a
  non-fit *frontend* plus a perfectly-sandboxable *backend/service*. Sandbox
  what you can; tell the user to do the rest on the host. Never silently emit a
  config that can't work.
