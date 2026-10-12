"""The strict login-entry grammars of gh hosts.yml and npm npmrc for the
credential bridge.

See "Rules for gh and npm login entries" in docs/contributing/seeds-and-auth.md.
"""

import re

# npm registry login: `//<host>[:port][/path]/:<key>=<value>` with only the
# four keys `npm login` writes. Values are literal (no `${VAR}` expansion, no
# escapes, no ini comment characters), so a synced line cannot read another
# project's environment or change any other setting. npm writes a value that
# contains `=` (base64 `_auth`/`_password`) in double quotes.
_NPMRC_VALUE = r"[A-Za-z0-9_.~+/=@-]{1,4096}"
_NPMRC_CREDENTIAL = re.compile(
    r"(//[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(?::[0-9]{1,5})?"
    r"(?:/[A-Za-z0-9_.~%-]{1,128}){0,16}/:(?:_authToken|_auth|username|_password))"
    rf"[ \t]*=[ \t]*(?:({_NPMRC_VALUE})|\"({_NPMRC_VALUE})\")",
    re.ASCII,
)
# gh hosts.yml: per host, only the active token/user, the git protocol, and the
# per-account tokens that `gh auth login` writes without a keyring.
_GH_HOST = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(?::[0-9]{1,5})?", re.ASCII)
_GH_USER = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9_])?", re.ASCII)
# gh_/github_pat_ tokens, plus the JWT-style GitHub App installation tokens.
_GH_TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,4095}", re.ASCII)
_GH_GIT_PROTOCOLS = frozenset({"https", "ssh"})
# One `key:` or `key: scalar` line of a plain block mapping. Anything else
# (lists, anchors, block/flow collections, tabs) makes the file unreadable.
_YAML_ENTRY = re.compile(
    r"( *)(\"[^\"\\\\]*\"|'[^']*'|[^\s#'\"\[\]{},&*!|>%@`?:-][^\s]*?):(?: +(\S.*?))? *",
    re.ASCII,
)


def _split_npmrc(text: str) -> tuple[dict[str, str], list[str]]:
    """Split an npmrc into its top-level login entries and all other lines.

    Mirrors the ini parser npm uses: lines end at CR or LF and a later duplicate
    key wins. Keys after the first `[section]` header belong to that section,
    so only lines before it can be login entries.
    """
    logins: dict[str, str] = {}
    others: list[str] = []
    top_level = True
    for line in re.split(r"[\r\n]+", text):
        stripped = line.strip()
        if stripped.startswith("["):
            top_level = False
        match = _NPMRC_CREDENTIAL.fullmatch(stripped) if top_level else None
        if match:
            logins[match.group(1)] = match.group(2) or match.group(3)
        elif line:
            others.append(line)
    return logins, others


def _merge_npmrc(raw: bytes | None, login: bytes) -> bytes:
    """Replace the login entries of a project npmrc and keep its other lines.

    The canonical login lines go first, so no `[section]` header can capture
    them.
    """
    _logins, others = _split_npmrc(raw.decode("utf-8") if raw else "")
    lines = login.decode("utf-8").splitlines() + others
    return "".join(f"{line}\n" for line in lines).encode("utf-8")


def _yaml_scalar(value: str) -> str | None:
    """Return a one-line YAML scalar's value, or None for any other value."""
    inner = value[1:-1]
    if value[0] == "'":
        if len(value) < 2 or value[-1] != "'" or "'" in inner.replace("''", ""):
            return None
        return inner.replace("''", "'")
    if value[0] == '"':
        if len(value) < 2 or value[-1] != '"' or "\\" in inner or '"' in inner:
            return None  # gh never writes escapes in hosts.yml
        return inner
    if value[0] in "|>&*!{[#%@`" or (value[0] in "-?:" and value[1:2] in ("", " ")):
        return None
    if ": " in value or value.endswith(":"):
        return None
    return value


def _yaml_plain_mapping(text: str) -> dict | None:
    """Parse the plain block-mapping YAML that gh writes, or return None.

    Every line must be `key:` (opens a nested mapping) or `key: scalar`. Lists,
    anchors, tags, flow or multi-line values, tabs, and duplicate keys make the
    whole file unreadable, so the result never depends on YAML features that gh
    does not write.
    """
    if text.strip() in ("", "{}"):
        return {}
    root: dict = {}
    stack: list[tuple[int, dict]] = [(0, root)]
    opened: dict | None = None
    for line in text.split("\n"):
        line = line.removesuffix("\r")
        if "\t" in line or "\r" in line:
            return None
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        entry = _YAML_ENTRY.fullmatch(line)
        if entry is None:
            return None
        indent, key = len(entry.group(1)), entry.group(2)
        if key[0] in "\"'":
            key = key[1:-1]
        if opened is not None and indent > stack[-1][0]:
            stack.append((indent, opened))
        opened = None
        while indent < stack[-1][0]:
            stack.pop()
        mapping = stack[-1][1]
        if indent != stack[-1][0] or key in mapping:
            return None
        if entry.group(3) is None:
            mapping[key] = opened = {}
            continue
        value = _yaml_scalar(entry.group(3))
        if value is None:
            return None
        mapping[key] = value
    return root


def _gh_hosts_logins(text: str) -> dict[str, dict] | None:
    """Return only the login entries of a gh hosts.yml, or None if unreadable."""
    root = _yaml_plain_mapping(text)
    if root is None:
        return None
    logins: dict[str, dict] = {}
    for host, entry in root.items():
        if not isinstance(entry, dict) or not _GH_HOST.fullmatch(host):
            continue
        accounts: dict[str, str] = {}
        users = entry.get("users")
        for user, account in (users.items() if isinstance(users, dict) else ()):
            token = account.get("oauth_token") if isinstance(account, dict) else None
            if _GH_USER.fullmatch(user) and isinstance(token, str) and _GH_TOKEN.fullmatch(token):
                accounts[user] = token
        login: dict = {}
        token, user = entry.get("oauth_token"), entry.get("user")
        if isinstance(token, str) and _GH_TOKEN.fullmatch(token):
            login["oauth_token"] = token
        if not login and not accounts:
            continue  # a host without a token is not a login
        if isinstance(user, str) and _GH_USER.fullmatch(user):
            login["user"] = user
        if entry.get("git_protocol") in _GH_GIT_PROTOCOLS:
            login["git_protocol"] = entry["git_protocol"]
        if accounts:
            login["users"] = accounts
        logins[host] = login
    return logins


def _render_gh_hosts(logins: dict[str, dict]) -> str:
    # Quote every value: an all-digit user or token must stay a string.
    lines: list[str] = []
    for host in sorted(logins):
        login = logins[host]
        lines.append(f'"{host}":')
        for key in ("git_protocol", "oauth_token", "user"):
            if key in login:
                lines.append(f'    {key}: "{login[key]}"')
        if "users" in login:
            lines.append("    users:")
            for user in sorted(login["users"]):
                lines.append(f'        "{user}":')
                lines.append(f'            oauth_token: "{login["users"][user]}"')
    return "".join(f"{line}\n" for line in lines)


def _canonical_login(fmt: str, raw: bytes) -> bytes | None:
    """Return a gh/npm file's login entries in canonical form.

    b"" means the file holds no login; None means it cannot be read safely.
    """
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if "\x00" in text:
        return None
    if fmt == "npmrc":
        logins, _others = _split_npmrc(text)
        # Quote a value with `=` the way npm's ini writer does.
        return "".join(
            f'{key}="{value}"\n' if "=" in value else f"{key}={value}\n"
            for key, value in sorted(logins.items())
        ).encode()
    hosts = _gh_hosts_logins(text)
    return None if hosts is None else _render_gh_hosts(hosts).encode()
