#!/usr/bin/env bash
# Isolated integration tests: no Docker, Nginx, host configuration, or network changes.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT_DIR/webhostcli"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export WEBHOSTCLI_ROOT="$TMP/root" WEBHOSTCLI_TEST_MODE=1
ok=0
pass(){ printf 'ok - %s\n' "$1"; ((ok+=1)); }
must(){ "$@" >/dev/null; }
must_fail(){ if "$@" >/dev/null 2>&1; then echo "expected failure: $*" >&2; exit 1; fi; }

bash -n "$CLI"; pass 'Bash syntax'
if command -v shellcheck >/dev/null; then shellcheck -S warning "$CLI"; pass 'ShellCheck'; else echo 'skip - ShellCheck unavailable'; fi
must "$CLI" install --repair; [[ -x "$TMP/root/usr/local/bin/webhostcli" ]]; pass 'installation file generation'
INST="$TMP/root/usr/local/bin/webhostcli"
must "$INST" install --repair; pass 'idempotent install'
mkdir -p "$TMP/root/etc/hosting-platform"
cat >"$TMP/root/etc/hosting-platform/platform.env" <<'EOF'
WEB_PORT_START=8500
WEB_PORT_END=8502
SFTP_PUBLIC_PORT_START=22500
SFTP_PUBLIC_PORT_END=22502
SFTP_BACKEND_PORT_START=32500
SFTP_BACKEND_PORT_END=32502
CUSTOMER_UID_START=12000
CUSTOMER_UID_END=12002
EOF
touch "$TMP/root/etc/hosting-platform/bootstrap.complete"
must "$INST" install --repair; pass 'existing bootstrap detection and platform.env parsing'
must "$INST" account create generic01 example.test --profile generic --alias www.example.test
must_fail "$INST" account create generic01 other.test --profile generic
pass 'duplicate account rejection'
must_fail "$INST" account create another example.test --profile generic
pass 'duplicate domain rejection'
[[ "$(sqlite3 "$TMP/root/var/lib/webhostcli/webhostcli.db" 'select uid from accounts where account="generic01";')" == 12000 ]]
[[ "$(sqlite3 "$TMP/root/var/lib/webhostcli/webhostcli.db" 'select web_backend from ports where account="generic01";')" == 8500 ]]
pass 'UID and port allocation'
grep -q 'no-new-privileges' "$TMP/root/srv/hosting/customers/generic01/compose.yaml"
pass 'generic profile generation and security flags'
must_fail "$INST" account create framework01 framework.test --profile laravel
must "$INST" shell generic01 php -v
must "$INST" composer generic01 --version
pass 'universal application shell and no framework-specific profile'
must "$INST" account verify generic01; pass 'compose and Nginx generated files'
docker compose -f "$TMP/root/srv/hosting/customers/generic01/compose.yaml" config >/dev/null
grep -q 'server_name example.test www.example.test;' "$TMP/root/etc/webhostcli/nginx/generic01.conf"
pass 'Compose YAML and Nginx template validation'
before="$(wc -c <"$TMP/root/var/log/webhostcli/audit.log")"
must "$INST" sftp password-reset generic01
! grep -q "$(grep '^SFTP_PASSWORD=' "$TMP/root/etc/webhostcli/secrets/generic01.env" | cut -d= -f2-)" "$TMP/root/var/log/webhostcli/audit.log"
pass 'password generation and non-disclosure in audit log'
must "$INST" account suspend generic01 --reason 'test suspension'
[[ "$(sqlite3 "$TMP/root/var/lib/webhostcli/webhostcli.db" 'select full_suspended from suspensions where account="generic01";')" == 1 ]]
must "$INST" account unsuspend generic01
[[ "$(sqlite3 "$TMP/root/var/lib/webhostcli/webhostcli.db" 'select full_suspended from suspensions where account="generic01";')" == 0 ]]
pass 'suspension and unsuspension'
must "$INST" metrics-collect
[[ "$(sqlite3 "$TMP/root/var/lib/webhostcli/webhostcli.db" 'select count(*) from metrics;' )" -ge 1 ]]
must "$INST" usage current generic01
pass 'metrics writes and disk usage reporting'
mkdir -p "$TMP/root/var/log/webhostcli/nginx"
printf '%s\n' '{"timestamp":"2026-01-02T00:00:00Z","request_length":10,"body_bytes_sent":20,"status":200}' >"$TMP/root/var/log/webhostcli/nginx/generic01.access.log"
must "$INST" usage rebuild generic01
[[ "$(sqlite3 "$TMP/root/var/lib/webhostcli/webhostcli.db" 'select http_out from bandwidth_daily where account="generic01";' )" == 20 ]]
pass 'bandwidth aggregation'
id="$($INST backup create generic01)"
must "$INST" backup verify "$id"
[[ -f "$TMP/root/srv/hosting/backups/$id/SHA256SUMS" ]]
pass 'backup manifest generation'
must_fail "$INST" account create ../unsafe unsafe.test --profile generic
pass 'safe path validation'
json="$($INST account list --json)"
python3 -c 'import json,sys; assert isinstance(json.load(sys.stdin),list)' <<<"$json"
pass 'JSON output validity'
printf 'legacy01\tlegacy.test\t12003\t8503\t22503\t32503\tgeneric\t\n' >"$TMP/root/etc/hosting-platform/accounts.tsv"
must "$INST" account import-existing
[[ "$(sqlite3 "$TMP/root/var/lib/webhostcli/webhostcli.db" 'select count(*) from accounts where account="legacy01";')" == 1 ]]
pass 'accounts.tsv migration'
printf 'passed %d isolated checks\n' "$ok"
