"""The container Git config, sandbox commit signing, the root-owned install of
the staged user config (lock_config), and the Git identity check.

See "Commit signing" in docs/contributing/seeds-and-auth.md.
"""

import subprocess
from pathlib import Path

from .post_create_common import AUTH, HOME, HOST_SEED_GIT, _load_sanitized_seed, log
from .post_create_overlays import P10K_STAGING, SHELL_RC_STAGING, STATUSLINE_VARIANTS
from .post_create_seeds import GIT_SEED_KEYS

# post-create writes the dynamic config as vscode to this fixed staging path;
# aic-lock-user-config validates and atomically installs it into the root-owned
# destination without granting a general-purpose privileged copy primitive.
GITCONFIG_STAGING = HOME / ".aic-gitconfig.staging"
GITCONFIG_MANAGED = Path("/etc/aic/user-config/gitconfig")
GITIGNORE_MANAGED = Path("/etc/aic/gitignore")

# Sandbox commit-signing material, provisioned by `aic signing` and persisted
# in the aic-auth-global volume (so the pubkey is registered on GitHub once and
# survives rebuilds). The host's own signing key is never forwarded; see
# setup_commit_signing().
SIGNING = AUTH / "signing"
SIGNING_KEY = SIGNING / "id_ed25519"             # private key (0600, vscode-owned)
SIGNING_MODE = SIGNING / "mode"                  # "auto" | "byok" | "disabled"
SIGNING_ALLOWED = SIGNING / "allowed_signers"    # for in-container verification

# HTTPS push/fetch credentials for GitHub, through the gh login made inside the
# container. This is the block that `gh auth setup-git` writes; gh cannot write
# it here, because the managed global config is root-owned 0444. The empty
# `helper =` resets helpers from earlier config scopes, so only gh answers for
# these URLs. The helper names the apt-installed, root-owned /usr/bin/gh by
# absolute path, never a bare `gh`: ~/.local/bin is agent-writable and comes
# first on PATH. It gives the agent no new power, because the agent already
# can read the gh token in ~/.config/gh/hosts.yml. aic-lock-user-config accepts
# only this exact block (REQUIRED_EXACT_VALUE_LISTS); keep the two aligned.
# There is no helper for other hosts (GitHub Enterprise, GitLab).
GH_CREDENTIAL_HELPER = "!/usr/bin/gh auth git-credential"
GH_CREDENTIAL_URLS = ("https://github.com", "https://gist.github.com")
GH_CREDENTIAL_CONFIG = "".join(
    f'[credential "{url}"]\n    helper =\n    helper = {GH_CREDENTIAL_HELPER}\n'
    for url in GH_CREDENTIAL_URLS
)


def _host_git_config(key: str) -> str:
    """Read one value from the fixed-key JSON git seed."""
    value = _load_sanitized_seed(HOST_SEED_GIT).get(key.lower(), "")
    return value if isinstance(value, str) else ""


def setup_commit_signing() -> str:
    """Return the container-local commit-signing config to append to
    the managed gitconfig after sanitized host preferences (so it overrides the
    host's signing intent inside the sandbox only).

    Why this exists: the host's signing key never enters the container (~/.ssh
    and the SSH agent are deliberately not forwarded), so a host configured for
    SSH/GPG commit signing would otherwise fail every `git commit` here with
    "Couldn't find key in agent". Instead `aic signing` provisions a
    sandbox-only ed25519 signing key in the aic-auth-global volume; this wires
    it up when present. Mode (set by `aic signing`, persisted in the volume):

      - key present (auto/byok) -> sign with it via gpg.format=ssh, regardless
        of whether the host signed with SSH or GPG (the switch is container-only).
      - mode 'disabled'         -> signing off in the sandbox (quiet).
      - host signs, but no key  -> signing off + LOUD notice (the safe default,
        so commits don't fail cryptically before a key is set up).
      - host doesn't sign       -> nothing.

    Takes effect on container (re)create only: the config is installed fresh
    into a root-owned directory, so a mode change via `aic signing` lands on the
    next rebuild without a privileged unlock primitive."""
    off = "[commit]\n    gpgsign = false\n[tag]\n    gpgsign = false\n"
    mode = SIGNING_MODE.read_text().strip() if SIGNING_MODE.is_file() else ""

    if mode == "disabled":
        log("commit signing: disabled in sandbox (your choice via 'aic signing')")
        return off

    if SIGNING_KEY.is_file():
        # ssh-keygen refuses keys with loose perms; we own the file (it's
        # created as vscode by `aic signing`), so tighten it each create.
        try:
            SIGNING_KEY.chmod(0o600)
        except OSError as e:
            log(f"warning: could not chmod signing key: {e}")
        block = (
            "[gpg]\n    format = ssh\n"
            f"[user]\n    signingkey = {SIGNING_KEY}\n"
            "[commit]\n    gpgsign = true\n"
        )
        # Also wire verification so in-container `git log --show-signature`
        # works instead of erroring on the host's allowedSignersFile (a
        # host-only path). Best-effort; signing itself doesn't need it.
        email = _host_git_config("user.email")
        pub = SIGNING_KEY.with_suffix(".pub")
        if email and pub.is_file():
            try:
                SIGNING_ALLOWED.write_text(f"{email} {pub.read_text().strip()}\n")
                block += f'[gpg "ssh"]\n    allowedSignersFile = {SIGNING_ALLOWED}\n'
            except OSError as e:
                log(f"warning: could not write allowed_signers: {e}")
        fp = ""
        try:
            r = subprocess.run(["ssh-keygen", "-lf", str(pub)], capture_output=True, text=True)
            if r.returncode == 0:
                fp = r.stdout.split()[1]
        except (FileNotFoundError, IndexError):
            pass
        log(f"commit signing: sandbox ssh key{(' ' + fp) if fp else ''} (mode={mode or 'auto'})")
        return block

    if _host_git_config("commit.gpgsign").lower() == "true":
        log("commit signing: host enables it but no sandbox key — commits are "
            "UNSIGNED here. Run 'aic signing' to provision a sandbox signing key "
            "(or 'aic signing disable' to silence this).")
        return off

    return ""


def setup_gitconfig() -> None:
    """Stage the dynamic global git config for privileged fixed-target install.

    The sanitizer emitted only fixed non-executable host keys. Git itself writes
    those values into the staging file so arbitrary names/emails are escaped
    correctly; aic's own settings and signing override are appended last.
    """
    if GITCONFIG_MANAGED.is_file():
        # Re-running post-create in the same container must not replace the
        # already-installed security config. A rebuild starts from a fresh image.
        return

    if GITCONFIG_STAGING.is_symlink() or GITCONFIG_STAGING.exists():
        if GITCONFIG_STAGING.is_dir():
            log(f"warning: refusing non-file gitconfig staging path {GITCONFIG_STAGING}")
            return
        GITCONFIG_STAGING.unlink()
    GITCONFIG_STAGING.touch(mode=0o600)

    seeded = _load_sanitized_seed(HOST_SEED_GIT)
    for key in GIT_SEED_KEYS:
        value = seeded.get(key.lower())
        if not isinstance(value, str):
            continue
        try:
            subprocess.run(
                ["git", "config", "--file", str(GITCONFIG_STAGING), key, value],
                check=True,
                capture_output=True,
                text=True,
            )
        except (OSError, subprocess.CalledProcessError) as e:
            log(f"warning: could not seed git preference {key}: {e}")

    # Container settings and signing go last so they override seeded values.
    # The GitHub credential helper is the last block. The seed never holds a
    # credential.* key, and the validator accepts only its exact value list.
    signing = setup_commit_signing()
    with GITCONFIG_STAGING.open("a") as local:
        local.write(
            f"\n# aicontainer container-local git config\n"
            f"[core]\n"
            f"    excludesfile = {GITIGNORE_MANAGED}\n"
            f"    pager = delta\n"
            f"[interactive]\n    diffFilter = delta --color-only\n"
            f"[delta]\n    navigate = true\n    line-numbers = true\n"
            f"[merge]\n    conflictstyle = diff3\n"
            f"[diff]\n    colorMoved = default\n"
            f"{signing}"
            f"{GH_CREDENTIAL_CONFIG}"
        )
    # The staging config contains only the sanitizer's non-secret fixed-key
    # preferences plus aic-owned constants. Root intentionally lacks broad
    # DAC_OVERRIDE in the long-running container, so make this one file
    # readable by the fixed sudo helper while its ownership/inode/link checks
    # still prevent path substitution.
    GITCONFIG_STAGING.chmod(0o644)
    log(f"staged {GITCONFIG_STAGING} for root-owned install")


def lock_config() -> None:
    """Install every staged fixed-target config through the narrow
    aic-lock-user-config helper (validated gitconfig plus the optional verbatim
    personal shell + statusline overlay). The helper deliberately lacks
    DAC_OVERRIDE, so the unprivileged owner removes its own staging files after
    the atomic install."""
    try:
        subprocess.run(["sudo", "/usr/local/bin/aic-lock-user-config"], check=True)
        log(f"installed root-owned user config under {GITCONFIG_MANAGED.parent}")
    except (OSError, subprocess.CalledProcessError) as e:
        log(f"warning: aic-lock-user-config failed: {e}")
    finally:
        staged = [GITCONFIG_STAGING, SHELL_RC_STAGING, P10K_STAGING]
        staged.extend(staging for _, staging in STATUSLINE_VARIANTS)
        for staging in staged:
            try:
                staging.unlink()
            except FileNotFoundError:
                pass


def verify_git_identity() -> None:
    """Loudly flag a missing commit identity at create time, so it surfaces here
    instead of cryptically mid-session on the first `git commit` ("Author
    identity unknown").

    The sandbox has NO identity of its own: the root-only sanitizer copies only
    user.name/user.email from the host seed. A missing identity can't be fixed
    from inside: `git config --global` writes to the root-managed config, and
    `git config --local` writes to /workspace/.git/config, which is mounted
    read-only. The only fix is on the host, so that's where we point. Non-fatal —
    matches the rest of post-create's defensive degradation."""
    def configured(key: str) -> bool:
        # cwd=HOME (not a repo) reads system + managed-global only, with no repo-local config or
        # dubious-ownership checks to muddy the result.
        try:
            r = subprocess.run(
                ["git", "config", "--get", key],
                capture_output=True, text=True, cwd=str(HOME),
            )
        except FileNotFoundError:
            return True  # no git to check with — don't cry wolf
        return r.returncode == 0 and bool(r.stdout.strip())

    if configured("user.name") and configured("user.email"):
        return
    log("git identity: no user.name/user.email is configured — commits here will "
        "fail with 'Author identity unknown' (unless the repo sets its own). The "
        "sandbox inherits its identity "
        "from the sanitized host ~/.gitconfig seed, which was empty/unset "
        "when this container was built. Fix it on the HOST, then 'aic rebuild' — "
        f"it can't be fixed from inside ({GITCONFIG_MANAGED} is root-managed and "
        "/workspace/.git/config is read-only): "
        "git config --global user.name '<you>' && "
        "git config --global user.email '<you@example.com>'.")
