#!/usr/bin/env bash
# The declarative firewall and the fixed allowlist presets of aic-firewall.
#
# - The preset table is fixed in the root-owned helper. A project selects names
#   in .devcontainer/firewall-presets; it never names a host through them.
# - The preset hosts are opt-in only: none is on the default allowlist.
# - The helper and the host validator know the same preset names.
# - `auto` enables only when .devcontainer/firewall-enable exists, and it has
#   no way to remove a rule.
# - The managed start command runs `auto` on every start and stops the
#   container when it fails; postStartCommand waits for it.
#
# The parsers run on the host: this test sources the helper (its main() runs
# only when it is executed) and replaces the iptables/DNS functions.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIREWALL="$ROOT/template/aic-firewall"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Read before the helper makes PATH a fixed system PATH.
NODE=$(command -v node) || fail "node is required"
validator_presets=$("$NODE" --input-type=module -e "
  const m = await import(process.argv[1]);
  console.log(m.FIREWALL_PRESETS.join(' '));
" "$ROOT/lib/validate.mjs")
TMP=$(mktemp -d)
TMP=$(cd -P "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

# A non-root run must stop before it reads anything.
if out=$(bash "$FIREWALL" auto 2>&1) && [ "$(id -u)" -ne 0 ]; then
  fail "aic-firewall ran without root"
fi
if [ "$(id -u)" -ne 0 ]; then
  case "$out" in
    *"must run via sudo"*) ;;
    *) fail "a non-root aic-firewall run did not refuse: $out" ;;
  esac
fi

# shellcheck source=../template/aic-firewall
# shellcheck disable=SC1091
source "$FIREWALL"
set +e
set -uo pipefail

# macOS realpath has no -e. Only the checks below use this stand-in; the helper
# runs with GNU realpath in the image.
if ! realpath -e -- / >/dev/null 2>&1; then
  realpath() {
    while [ "$#" -gt 1 ]; do shift; done
    local file="$1" dir
    [ -e "$file" ] || return 1
    dir=$(cd -P -- "$(dirname -- "$file")" && pwd -P) || return 1
    if [ -L "$file" ]; then
      printf '%s/%s\n' "$dir" "$(readlink -- "$file")"
    else
      printf '%s/%s\n' "$dir" "$(basename -- "$file")"
    fi
  }
fi

# --- The fixed table ----------------------------------------------------------
expected_table='crates index.crates.io static.crates.io
go proxy.golang.org sum.golang.org
maven repo.maven.apache.org
nodejs nodejs.org
packagist repo.packagist.org
rubygems rubygems.org index.rubygems.org
semgrep semgrep.dev'
table=""
for name in $PRESET_NAMES; do
  hosts=$(preset_domains "$name" | tr '\n' ' ')
  table="${table}${name} ${hosts% }
"
done
[ "${table%
}" = "$expected_table" ] \
  || fail "the preset table changed; review each host from the registry documentation, then update this test:
$table"

case_names=$(sed -n '/^preset_domains() {/,/^}/p' "$FIREWALL" \
  | sed -n 's/^[[:space:]]*\([a-z0-9-]*\))[[:space:]].*/\1/p' | sort | tr '\n' ' ')
sorted_names=$(printf '%s\n' $PRESET_NAMES | sort | tr '\n' ' ')
[ "$case_names" = "$sorted_names" ] \
  || fail "PRESET_NAMES ($sorted_names) and the preset_domains() cases ($case_names) differ"
[ "$(printf '%s\n' $validator_presets | sort | tr '\n' ' ')" = "$sorted_names" ] \
  || fail "lib/validate.mjs FIREWALL_PRESETS ($validator_presets) and aic-firewall PRESET_NAMES ($PRESET_NAMES) differ"
if preset_domains "unknown" >/dev/null || preset_domains "" >/dev/null; then
  fail "preset_domains accepted a name that is not in the table"
fi

for name in $PRESET_NAMES; do
  for host in $(preset_domains "$name"); do
    [[ "$host" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] \
      || fail "preset $name has a host that is not a plain domain: $host"
    for default in "${DEFAULT_ALLOWLIST[@]}"; do
      [ "$host" != "$default" ] \
        || fail "preset host $host is on the default allowlist; presets must stay opt-in"
    done
  done
done
echo "OK: the preset table is fixed, opt-in, and equal to the validator list"

# --- The preset file parser ---------------------------------------------------
LOADED=""
resolve_domain_into_set() { LOADED="${LOADED}$2 "; }

PRESETS_FILE="$TMP/firewall-presets"
LOADED=""
load_preset_domains test-set >/dev/null 2>&1 || fail "a missing preset file failed the enable"
[ -z "$LOADED" ] || fail "a missing preset file loaded hosts: $LOADED"

printf '# registries\ncrates\n  go   # module proxy\r\n\n' > "$PRESETS_FILE"
LOADED=""
load_preset_domains test-set >/dev/null 2>&1 || fail "known presets were refused"
[ "$LOADED" = "index.crates.io static.crates.io proxy.golang.org sum.golang.org " ] \
  || fail "known presets loaded the wrong hosts: $LOADED"

for bad in evil.example.com Go 'crates io' 'go,crates' ../crates 'nodejs.org' \
    "$(printf 'x%.0s' $(seq 40))"; do
  printf 'crates\n%s\n' "$bad" > "$PRESETS_FILE"
  if err=$(load_preset_domains test-set 2>&1 >/dev/null); then
    fail "preset file line '$bad' was accepted"
  fi
  case "$err" in
    *"unknown firewall preset"*) ;;
    *) fail "preset file line '$bad' was refused without the preset message: $err" ;;
  esac
  # Drop the file path first: the random mktemp name can contain a short bad
  # line such as "Go".
  case "${err//"$PRESETS_FILE"/}" in
    *"$bad"*) fail "the refusal echoes the raw preset line: $err" ;;
  esac
done

printf 'crates\n' > "$TMP/real-presets"
rm -f "$PRESETS_FILE"
ln -s "$TMP/real-presets" "$PRESETS_FILE"
if load_preset_domains test-set >/dev/null 2>&1; then
  fail "a symlinked preset file was accepted"
fi
rm -f "$PRESETS_FILE"
mkdir "$PRESETS_FILE"
if load_preset_domains test-set >/dev/null 2>&1; then
  fail "a preset directory was accepted"
fi
rmdir "$PRESETS_FILE"
mkdir "$TMP/real-dir"
printf 'crates\n' > "$TMP/real-dir/firewall-presets"
ln -s "$TMP/real-dir" "$TMP/linked-dir"
PRESETS_FILE="$TMP/linked-dir/firewall-presets"
if load_preset_domains test-set >/dev/null 2>&1; then
  fail "a preset file below a symlinked directory was accepted"
fi
echo "OK: firewall-presets selects fixed names only; hosts, unknown names, and links abort the enable"

# --- /etc/hosts pins ---------------------------------------------------------------
# A CDN name resolves to other valid addresses on each resolver. enable pins
# each allowlist name to its allowed addresses, so a later lookup in the
# container cannot get an address that the rules block.
is_prohibited_v4() { [[ "$1" == 169.254.* ]]; }
ipset() { :; }
HOSTS_FILE="$TMP/hosts"
docker_hosts='127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
172.18.0.3	abc123
192.168.65.254	host.docker.internal'
printf '%s\n' "$docker_hosts" > "$HOSTS_FILE"
# shellcheck disable=SC2034 # read by add_resolved_ipv4 in the sourced helper
PIN_SET=aic-allowed-v4-a
PIN_LINES=()
PROHIBITED_RESOLUTION=0
add_resolved_ipv4 aic-allowed-v4-a index.crates.io 52.85.185.102
add_resolved_ipv4 aic-allowed-v4-a index.crates.io 151.101.2.137
add_resolved_ipv4 aic-allowed-v4-a index.crates.io 151.101.2.137
add_resolved_ipv4 aic-allowed-v4-a api.github.com 140.82.121.5
add_resolved_ipv4 aic-allowed-v4-a evil.example 169.254.169.254 2>/dev/null
add_resolved_ipv4 aic-status-v4-a host.docker.internal 192.168.65.254
add_resolved_ipv4 aic-proxy-v4-a socket-proxy 172.18.0.2
[ "$PROHIBITED_RESOLUTION" = 1 ] || fail "a prohibited address was not refused"
pin_hosts || fail "pin_hosts failed on a writable hosts file"
expected_hosts="$docker_hosts
$HOSTS_BEGIN
140.82.121.5 api.github.com
151.101.2.137 index.crates.io
52.85.185.102 index.crates.io
$HOSTS_END"
[ "$(cat "$HOSTS_FILE")" = "$expected_hosts" ] \
  || fail "pin_hosts did not pin exactly the allowlist set addresses:
$(cat "$HOSTS_FILE")"

# shellcheck disable=SC2034 # read by pin_hosts in the sourced helper
PIN_LINES=("151.101.66.137 index.crates.io")
pin_hosts || fail "a second pin_hosts failed"
[ "$(cat "$HOSTS_FILE")" = "$docker_hosts
$HOSTS_BEGIN
151.101.66.137 index.crates.io
$HOSTS_END" ] || fail "a second enable kept old pins or added a second block:
$(cat "$HOSTS_FILE")"
unpin_hosts || fail "unpin_hosts failed"
[ "$(cat "$HOSTS_FILE")" = "$docker_hosts" ] \
  || fail "unpin_hosts changed lines outside the managed block:
$(cat "$HOSTS_FILE")"

printf '%s\n' "$docker_hosts" > "$TMP/real-hosts"
rm -f "$HOSTS_FILE"
ln -s "$TMP/real-hosts" "$HOSTS_FILE"
if pin_hosts || unpin_hosts; then
  fail "the pins followed a symlinked hosts file"
fi
[ "$(cat "$TMP/real-hosts")" = "$docker_hosts" ] || fail "the symlink target of the hosts file changed"
rm -f "$HOSTS_FILE"

# The write is never a truncate first (the file is never empty), and the
# signals that sudo relays from the agent are ignored while it writes.
if grep -Eq '(^|[^<])>>?[[:space:]]*"\$HOSTS_FILE"' "$FIREWALL"; then
  fail "aic-firewall truncates /etc/hosts with a > redirect; use write_hosts_file"
fi
printf 'old line one that is long\nold line two that is long\n' > "$HOSTS_FILE"
truncate() { trap -p TERM INT HUP TSTP > "$TMP/traps-during-write"; command truncate "$@"; }
write_hosts_file "short"$'\n' || fail "write_hosts_file failed"
unset -f truncate
[ "$(cat "$HOSTS_FILE")" = "short" ] || fail "write_hosts_file left old content: $(cat "$HOSTS_FILE")"
for sig in TERM INT HUP TSTP; do
  grep -Eq "^trap -- '' (SIG)?$sig\$" "$TMP/traps-during-write" \
    || fail "write_hosts_file does not ignore $sig while it writes: $(cat "$TMP/traps-during-write")"
done
[ -z "$(trap -p TERM)" ] || fail "write_hosts_file did not restore the TERM handler"
rm -f "$HOSTS_FILE"

# --- Internal names never get the all-port allowlist rule ----------------------
for name in host.docker.internal gateway.docker.internal host.containers.internal \
    metadata.google.internal localhost foo.localhost socket-proxy aic-auth-sync \
    aic-seed-sanitizer devcontainer aic-proj-0123abcd-socket-proxy-1; do
  is_internal_name "$name" || fail "is_internal_name accepted $name"
done
for name in index.crates.io socket-proxy.example.com internal.example.com api.github.com; do
  if is_internal_name "$name"; then fail "is_internal_name refused the public name $name"; fi
done
for name in $PRESET_NAMES; do
  for host in $(preset_domains "$name"); do
    if is_internal_name "$host"; then fail "preset $name has the internal host $host"; fi
  done
done
for d in "${DEFAULT_ALLOWLIST[@]}"; do
  if is_internal_name "$d"; then fail "the default allowlist has the internal host $d"; fi
done
# normalize_domain needs bash 4 (${x,,}); macOS /bin/bash is 3.2. CI runs this
# part, and the static check below runs everywhere.
printf '%s\n' "$(sed -n '/^load_extra_domains() {/,/^}/p' "$FIREWALL")" \
  | grep -A1 -F 'normalize_domain "$domain") || return 1' | grep -Fq 'if is_internal_name "$domain"; then' \
  || fail "load_extra_domains does not refuse internal names right after normalize_domain"
EXTRA_FILE="$TMP/firewall-allowlist"
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
for bad in host.docker.internal Socket-Proxy localhost aic-proj-0123abcd-socket-proxy-1; do
  printf 'example.com\n%s\n' "$bad" > "$EXTRA_FILE"
  LOADED=""
  if load_extra_domains test-set >/dev/null 2>&1; then
    fail "firewall-allowlist line '$bad' was accepted"
  fi
done
printf 'example.com\n' > "$EXTRA_FILE"
LOADED=""
load_extra_domains test-set >/dev/null 2>&1 || fail "a public firewall-allowlist name was refused"
[ "$LOADED" = "example.com " ] || fail "firewall-allowlist loaded the wrong hosts: $LOADED"
rm -f "$EXTRA_FILE"
fi

# An address of the host gateway or a managed service in the allowlist set
# (a raw address line, or a name that resolves to it) aborts the enable.
internal_addresses_v4() { printf '%s\n' 172.18.0.1 192.168.65.254 172.18.0.2; }
ipset_members_v4() { printf '%s\n' 151.101.2.137 140.82.121.5; }
refuse_internal_addresses_v4 test-set 2>/dev/null || fail "a public allowlist set was refused"
ipset_members_v4() { printf '%s\n' 151.101.2.137 192.168.65.254; }
if refuse_internal_addresses_v4 test-set 2>/dev/null; then
  fail "an allowlist set with the host-gateway address was accepted"
fi
ipset_members_v4() { printf '%s\n' 172.18.0.2/32; }
if refuse_internal_addresses_v4 test-set 2>/dev/null; then
  fail "an allowlist set with the socket-proxy address was accepted"
fi
enable_body=$(sed -n '/^enable_policy() {/,/^}/p' "$FIREWALL")
printf '%s\n' "$enable_body" | grep -Fq 'refuse_internal_addresses_v4 "$allow_set" || exit 1' \
  || fail "enable_policy does not refuse internal addresses in the allowlist set"
echo "OK: internal names and addresses never get the all-port allowlist rule"

# Order in enable_policy: remove the old pins before the first lookup (getent
# reads /etc/hosts), and pin only after the switch to the new rules.
enable_body=$(sed -n '/^enable_policy() {/,/^}/p' "$FIREWALL")
line_of() { printf '%s\n' "$enable_body" | grep -n -m1 -- "$1" | cut -d: -f1; }
unpin_at=$(line_of 'unpin_hosts')
pin_set_at=$(line_of 'PIN_SET="$allow_set"')
resolve_at=$(line_of 'resolve_domain_into_set')
switch_at=$(line_of 'switch_chain_v4 OUTPUT')
pin_at=$(line_of '! pin_hosts')
[ -n "$unpin_at" ] && [ -n "$pin_set_at" ] && [ -n "$resolve_at" ] && [ -n "$switch_at" ] && [ -n "$pin_at" ] \
  && [ "$unpin_at" -lt "$resolve_at" ] && [ "$pin_set_at" -lt "$resolve_at" ] && [ "$switch_at" -lt "$pin_at" ] \
  || fail "enable_policy must unpin before it resolves and pin after the IPv4 switch"
echo "OK: enable pins the allowlist names to the allowed addresses only, and replaces the old pins"

# --- auto: enable only on the marker; never weaken -------------------------------
CALLS=""
ACTIVE=""
lock_firewall() { CALLS="${CALLS}lock "; }
enable_policy() { CALLS="${CALLS}enable "; }
active_chain_v4() { printf '%s\n' "$ACTIVE"; }

ENABLE_MARKER="$TMP/firewall-enable"
CALLS=""
cmd_auto >/dev/null || fail "auto without the marker failed"
[ -z "$CALLS" ] || fail "auto without the marker took the lock or enabled: $CALLS"

: > "$ENABLE_MARKER"
CALLS=""; ACTIVE=""
cmd_auto >/dev/null || fail "auto with the marker failed"
[ "$CALLS" = "lock enable " ] || fail "auto with the marker did not enable under the lock: $CALLS"

CALLS=""; ACTIVE=AIC_OUT_B
cmd_auto >/dev/null || fail "auto with an active generation failed"
[ "$CALLS" = "lock " ] || fail "auto replaced an active generation instead of keeping it: $CALLS"

rm -f "$ENABLE_MARKER"
ln -s "$TMP/missing" "$ENABLE_MARKER"
CALLS=""; ACTIVE=""
cmd_auto >/dev/null || fail "auto with a dangling marker link failed"
[ "$CALLS" = "lock enable " ] || fail "a dangling marker link did not enable (a marker only restricts): $CALLS"

auto_body=$(sed -n '/^cmd_auto() {/,/^}/p' "$FIREWALL")
if printf '%s\n' "$auto_body" | grep -Eq '(^|[[:space:]])(ipt|ip6t|iptables|ip6tables|ipset)[[:space:]]'; then
  fail "cmd_auto changes rules directly; it may only call enable_policy"
fi
dispatch=$(sed -n '/^main() {/,/^}/p' "$FIREWALL" | sed -n 's/^[[:space:]]*\([a-z-]*\)) cmd_.*/\1/p' | tr '\n' ' ')
[ "$dispatch" = "enable auto block-metadata status " ] \
  || fail "aic-firewall subcommands changed ($dispatch); there must be no disable or flush"
# The devcontainer drops NET_RAW. iptables `-m set` needs it to open its ipset
# socket, so a set match would make every enable (and so every start with the
# marker) fail in the real container.
if grep -Eq -- '-m[[:space:]]+set|--match-set' "$FIREWALL"; then
  fail "aic-firewall uses an ipset match, which needs NET_RAW; use accept_set_members_v4"
fi
echo "OK: auto enables only on the marker, keeps an active generation, and the helper has no disable"

# --- The start path ---------------------------------------------------------------
start_block='    command:
      - /bin/sh
      - -c
      - |
        if [ -e /workspace/.devcontainer/firewall-enable ] || [ -L /workspace/.devcontainer/firewall-enable ]; then
          /usr/bin/sudo -n /usr/local/bin/aic-firewall auto || {
            echo "aic: .devcontainer/firewall-enable is set, but the firewall could not be enabled. The container stops." >&2
            exit 1
          }
        fi
        exec sleep infinity'
for template in docker-compose.pull.yml docker-compose.build.yml; do
  grep -Fq -- "$start_block" "$ROOT/template/$template" \
    || fail "template/$template does not run the fail-closed firewall start command"
  grep -Fq -- '- ../.devcontainer:/workspace/.devcontainer:ro' "$ROOT/template/$template" \
    || fail "template/$template does not mount the marker read-only"
done
grep -Fqx '  "postStartCommand": "if [ -e /workspace/.devcontainer/firewall-enable ] || [ -L /workspace/.devcontainer/firewall-enable ]; then /usr/bin/sudo -n /usr/local/bin/aic-firewall auto; fi",' \
  "$ROOT/template/devcontainer.json" \
  || fail "devcontainer.json does not wait for the declared firewall after each start"
# The marker test keeps a project without the marker startable on an older
# image (a build-mode project after aic sync, before aic rebuild).
post_start=$(sed -n 's/^  "postStartCommand": "\(.*\)",$/\1/p' "$ROOT/template/devcontainer.json")
marker_dir="$TMP/post-start/workspace/.devcontainer"
mkdir -p "$marker_dir"
fake_root="$TMP/post-start"
run_post_start() {
  # Run the real command text against a fake root; the helper is a stub that
  # records the call and exits with $1.
  local cmd="${post_start//\/workspace/$fake_root/workspace}"
  cmd="${cmd//\/usr\/bin\/sudo -n \/usr\/local\/bin\/aic-firewall auto/stub_auto}"
  STUB_RC="$1" /bin/sh -c "stub_auto() { echo called >> '$fake_root/calls'; return \$STUB_RC; }; $cmd"
}
: > "$fake_root/calls"
run_post_start 2 || fail "postStartCommand failed without the marker"
[ ! -s "$fake_root/calls" ] || fail "postStartCommand ran aic-firewall without the marker"
: > "$marker_dir/firewall-enable"
if run_post_start 1; then fail "postStartCommand hid a failed declared firewall"; fi
run_post_start 0 || fail "postStartCommand failed with a working declared firewall"
[ "$(grep -c called "$fake_root/calls")" = 2 ] || fail "postStartCommand did not run aic-firewall with the marker"
grep -Eq '^  "waitFor": "postStartCommand"$' "$ROOT/template/devcontainer.json" \
  || fail "VS Code can open a terminal before the declared firewall is on"
echo "OK: every start enables a declared firewall or stops the container"
