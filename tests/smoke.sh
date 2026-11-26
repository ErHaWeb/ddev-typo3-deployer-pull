#!/usr/bin/env bash

# Run with DDEV, Docker and rsync on the host. All SSH calls stay in the fixture.
set -euo pipefail

addon=$(cd "$(dirname "$0")/.." && pwd -P)
export TEST_DDEV
export TEST_RSYNC
TEST_DDEV=$(command -v ddev) || { echo 'Smoke tests require DDEV on the host. See the README.' >&2; exit 1; }
TEST_RSYNC=${TEST_RSYNC:-rsync}
TEST_RSYNC=$(command -v "$TEST_RSYNC") || { echo 'Smoke tests require rsync (or an executable TEST_RSYNC override).' >&2; exit 1; }

work=$(mktemp -d /tmp/deployer-pull.XXXXXXXX)
project="deployer-pull-${work##*.}"
project=$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')
export TEST_PROJECT="$project"
export DDEV_XDG_CONFIG_HOME="$work/config"
export XDG_CONFIG_HOME="$DDEV_XDG_CONFIG_HOME"
export TEST_WORK="$work"
export DDEV_NONINTERACTIVE=true

# Keep human-readable progress on the original streams and collect detailed
# command output per scenario. Successful assertions do not repeat log output.
exec 3>&1 4>&2
case_number=0
case_name=''
case_log=''

pass_case() {
    if [[ -n "$case_name" ]]; then
        printf '     PASS: %s\n' "$case_name" >&3
        case_name=''
    fi
}

begin_case() {
    pass_case
    case_number=$((case_number + 1))
    case_name=$1
    case_log="$work/case-$case_number.log"
    printf '\n[%02d] %s\n' "$case_number" "$case_name" >&3
    exec >"$case_log" 2>&1
}

cleanup() {
    status=$?
    trap - EXIT ERR
    exec 1>&3 2>&4
    if [[ "$status" -ne 0 && -n "$case_name" ]]; then
        printf '     FAIL: %s (exit %s)\n' "$case_name" "$status" >&2
        if [[ -f "$case_log" ]]; then
            cat "$case_log" >&2
        fi
    fi
    if [[ -f "$work/project/.ddev/config.yaml" ]]; then
        cd "$work/project"
        if ! "$TEST_DDEV" delete -Oy >"$work/cleanup.log" 2>&1; then
            cat "$work/cleanup.log" >&2
            echo "Fixture cleanup failed. Test directory: $work" >&2
            exit 1
        fi
    fi
    if [[ "$status" -eq 0 ]]; then
        cd /
        rm -rf -- "$work"
        printf '\nAll isolated DDEV smoke checks passed. (%s scenarios)\n' "$case_number"
    else
        echo "Fixture logs: $work" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
# Plain shell assertions (test, cmp, [[ ... ]]) otherwise fail silently.
trap 'printf "Assertion or command failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Log assertions should only print the captured output when they fail.
assert_log_contains() {
    local log=$1
    shift
    grep -q "$@" "$log" || {
        cat "$log" >&2
        fail "missing log match: $*"
    }
}

expect_failure() {
    local message=$1
    shift
    if "$@" >"$work/failure.log" 2>&1; then
        cat "$work/failure.log" >&2
        fail "expected failure: $*"
    fi
    assert_log_contains "$work/failure.log" -F -- "$message"
}

begin_case 'Create an isolated DDEV project (no live server access)'
mkdir -p "$work/project/public/fileadmin" "$work/bin" "$work/config/ddev"
cd "$work/project"
cat >"$work/config/ddev/global_config.yaml" <<'YAML'
omit_containers: [ddev-router, ddev-ssh-agent]
instrumentation_opt_in: false
developer_mode: true
internet_detection_timeout_ms: 0
YAML
"$TEST_DDEV" config --project-type=typo3 --project-name="$project" --docroot=public --database=mysql:8.0
printf '\ndisable_settings_management: true\nperformance_mode: none\n' >>.ddev/config.yaml
printf '<?php echo "fixture";\n' >public/index.php

begin_case 'Install the add-on and verify the provider, license and manifest'
install_source=${1:-"$addon"}
if [[ $# -gt 0 ]]; then
    shift
fi
get_addon() {
    "$TEST_DDEV" add-on get "$install_source" "$@"
}
provider=.ddev/providers/typo3-deployer.yaml
copying=.ddev/typo3-deployer-pull/COPYING
manifest=.ddev/addon-metadata/typo3-deployer-pull/manifest.yaml
get_addon "$@"
cmp "$provider" "$addon/providers/typo3-deployer.yaml"
cmp "$copying" "$addon/typo3-deployer-pull/COPYING"
tail -n +5 "$copying" | cmp - "$addon/LICENSE.txt"
test -f "$manifest"
"$TEST_DDEV" pull --help >"$work/help.log"
assert_log_contains "$work/help.log" -F 'Pull with typo3-deployer'
if grep -Eq '^[[:space:]]+deployer[[:space:]]' "$work/help.log"; then
    fail 'unexpected legacy provider on fresh install'
fi
begin_case 'Upgrade the legacy provider and remove only the managed old file'
# Build a local fixture with the previous install manifest and provider name.
# This works without Git history or network access (including release archives).
legacy_addon="$work/legacy-addon"
legacy_provider=.ddev/providers/deployer.yaml
mkdir -p "$legacy_addon/providers"
cp -R "$addon/typo3-deployer-pull" "$legacy_addon/"
cp "$addon/providers/typo3-deployer.yaml" "$legacy_addon/providers/deployer.yaml"
cat >"$legacy_addon/install.yaml" <<'YAML'
name: typo3-deployer-pull
ddev_version_constraint: '>= v1.25.0'
project_files:
  - providers/deployer.yaml
  - typo3-deployer-pull/pull.sh
  - typo3-deployer-pull/COPYING
YAML
"$TEST_DDEV" add-on remove typo3-deployer-pull
"$TEST_DDEV" add-on get "$legacy_addon"
test -f "$legacy_provider"
test ! -e "$provider"
get_addon "$@"
test ! -e "$legacy_provider"
cmp "$provider" "$addon/providers/typo3-deployer.yaml"
assert_log_contains "$manifest" -F 'providers/typo3-deployer.yaml'
if grep -Fq 'providers/deployer.yaml' "$manifest"; then
    fail 'legacy provider still tracked in manifest'
fi
"$TEST_DDEV" pull --help >"$work/help.log"
assert_log_contains "$work/help.log" -F 'Pull with typo3-deployer'
if grep -Eq '^[[:space:]]+deployer[[:space:]]' "$work/help.log"; then
    fail 'legacy provider still registered after upgrade'
fi
get_addon "$@"
test ! -e "$legacy_provider"

begin_case 'Preserve customized and unrelated legacy provider files during upgrade'
sed '/^#ddev-generated$/d' "$legacy_addon/providers/deployer.yaml" >"$work/custom-legacy.yaml"
cp "$work/custom-legacy.yaml" "$legacy_provider"
get_addon "$@"
cmp "$legacy_provider" "$work/custom-legacy.yaml"
printf '#ddev-generated\n# Unrelated provider\n' >"$work/unrelated-legacy.yaml"
cp "$work/unrelated-legacy.yaml" "$legacy_provider"
get_addon "$@"
cmp "$legacy_provider" "$work/unrelated-legacy.yaml"
rm "$legacy_provider"
ln -s "$work/custom-legacy.yaml" "$legacy_provider"
get_addon "$@"
test -L "$legacy_provider"
cmp "$legacy_provider" "$work/custom-legacy.yaml"
rm "$legacy_provider"

begin_case 'Preserve the old managed provider when its replacement is customized'
cp "$legacy_addon/providers/deployer.yaml" "$legacy_provider"
sed '/^#ddev-generated$/d' "$provider" >"$work/custom-new.yaml"
cp "$work/custom-new.yaml" "$provider"
get_addon "$@"
cmp "$legacy_provider" "$legacy_addon/providers/deployer.yaml"
cmp "$provider" "$work/custom-new.yaml"
rm "$provider"
get_addon "$@"
test ! -e "$legacy_provider"
begin_case 'Update generated files and preserve customized provider files'
echo '# managed test edit' >>"$provider"
get_addon "$@"
cmp "$provider" "$addon/providers/typo3-deployer.yaml"
sed '/^#ddev-generated$/d' "$provider" >"$work/custom.yaml"
echo '# protected test edit' >>"$work/custom.yaml"
cp "$work/custom.yaml" "$provider"
get_addon "$@"
cmp "$provider" "$work/custom.yaml"
begin_case 'Remove the add-on while preserving a customized provider'
"$TEST_DDEV" add-on remove typo3-deployer-pull
cmp "$provider" "$work/custom.yaml"
test ! -e "$manifest"
begin_case 'Remove managed files and reinstall the add-on'
rm "$provider"
get_addon "$@"
"$TEST_DDEV" add-on remove typo3-deployer-pull
test ! -e "$provider"
test ! -e .ddev/typo3-deployer-pull/pull.sh
test ! -e "$copying"
test ! -e "$manifest"
get_addon "$@"

begin_case 'Reject missing host-side rsync before importing anything'
# Fail rsync lookup with a private PATH, without modifying host executables.
mkdir "$work/no-rsync"
for program in ddev ssh; do
    ln -s "$(command -v "$program")" "$work/no-rsync/$program"
done
expect_failure 'Missing on this machine: rsync' env PATH="$work/no-rsync" \
    DDEV_APPROOT="$PWD" DDEV_PROJECT="$project" DDEV_DOCROOT=public host=production \
    /bin/bash .ddev/typo3-deployer-pull/pull.sh check

begin_case 'Create simulated SSH and TYPO3 endpoints and start real DDEV containers'
# Run real rsync through a fixture-local SSH transport. Run real database imports
# while recording TYPO3 CLI calls, so no TYPO3 installation is required.
cat >"$work/bin/ddev" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == typo3 ]]; then
    printf '%s\n' "$*" >>"$TEST_WORK/typo3.log"
    if [[ "${2:-}" == --no-interaction && "${3:-}" == help && "${4:-}" == "${TEST_LOCAL_CLI_MISSING:-}" ]]; then
        printf 'Command "%s" is not defined.\n' "$4" >&2
        exit 1
    fi
    if [[ "${2:-}" == --no-interaction && "${3:-}" == "${TEST_LOCAL_CLI_FAILURE:-}" ]]; then
        exit 42
    fi
elif [[ "${1:-}" == import-db && -n "${TEST_IMPORT_FAILURE:-}" ]]; then
    exit 43
else
    exec "$TEST_DDEV" "$@"
fi
BASH
cat >"$work/bin/ssh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_WORK/ssh.log"
if [[ "$1" == -G ]]; then
    [[ "$*" == "-G -T -o RemoteCommand=none -- $TEST_PROJECT" ]]
    printf '%s\n' "hostname ${TEST_SSH_HOSTNAME:-deployment.example.invalid}" \
        "user ${TEST_SSH_USER:-release}" "port ${TEST_SSH_PORT:-2222}" \
        'identityfile ~/.ssh/fixture-key' 'identitiesonly yes'
    exit 0
fi
[[ "$1 $2 $3" == '-T -o RemoteCommand=none' ]]
shift 3
[[ "$1" != -C ]] || shift
[[ "$1" != -- ]] || shift
[[ "$1" == "$TEST_PROJECT" && "$#" -ge 2 ]]
shift
if [[ -n "${TEST_SSH_FAILURE:-}" ]]; then
    printf '%s\n' 'Permission denied (publickey).' >&2
    exit 255
fi
if [[ "$*" == 'command -v rsync '* && -n "${TEST_REMOTE_RSYNC_MISSING:-}" ]]; then
    echo 'rsync is not available on the deployment server.' >&2
    exit 1
fi
exec /bin/sh -c "$*"
BASH
cat >"$work/bin/rsync" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${TEST_RSYNC_FAILURE:-}" ]]; then
    printf '%s\n' "rsync: [receiver] mkstemp failed: Illegal byte sequence (92)" >&2
    exit "${TEST_RSYNC_STATUS:-23}"
fi
exec "$TEST_RSYNC" "$@"
BASH
chmod +x "$work/bin/ddev" "$work/bin/ssh" "$work/bin/rsync"
export PATH="$work/bin:$PATH"

for environment in production staging; do
    release="$work/$environment/current"
    mkdir -p "$release/public/fileadmin/_temp_" "$release/vendor/bin" "$work/$environment/bin"
    printf '%s\n' "$environment" >"$release/public/fileadmin/from-server"
    ln -s from-server "$release/public/fileadmin/internal-link"
    ln -s ../outside-fileadmin "$release/public/fileadmin/external-link"
    touch "$release/public/fileadmin/_temp_/from-server"
    cat >"$work/$environment/bin/php" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${TEST_PHP_FLAGS:-required}" == required ]]; then
    [[ "$1 $2" == '-d memory_limit=128M' ]]
    shift 2
fi
[[ "$*" == "vendor/bin/typo3 --no-interaction database:export -c Default -e cache_* -e [bf]e_sessions -e sys_log -e sys_http_report -e sys_file_processedfile" ]]
if [[ -n "${TEST_PHP_FAILURE:-}" ]]; then
    printf '%s\n' 'Composer detected issues in your platform:' \
        'Your Composer dependencies require a PHP version ">= 8.5.0". You are running 8.4.28.' >&2
    exit "$TEST_PHP_FAILURE"
fi
exec /bin/bash "$@"
BASH
    chmod +x "$work/$environment/bin/php"
    cat >"$release/vendor/bin/typo3" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "--no-interaction database:export -c Default -e cache_* -e [bf]e_sessions -e sys_log -e sys_http_report -e sys_file_processedfile" ]]
if [[ -n "${TEST_REMOTE_CLI_MISSING:-}" ]]; then
    echo 'Command "database:export" is not defined.' >&2
    exit 1
fi
case "${TEST_DUMP:-complete}" in
    noisy) echo 'Unexpected shell output' ;;
esac
environment=$(basename "$(dirname "$PWD")")
printf '\n-- Dump of TYPO3 Connection "Default"\n'
printf 'CREATE TABLE pull_marker (environment VARCHAR(40));\n'
printf "INSERT INTO pull_marker VALUES ('%s');\n" "$environment"
if [[ "${TEST_DUMP:-complete}" != truncated ]]; then
    printf '%s\n' '-- Dump completed on 2026-01-01'
fi
BASH
    chmod +x "$release/vendor/bin/typo3"
done

sed 's/$/\r/' >.hosts.yml <<YAML
hosts:
  .base: &base
    remote_user: deploy
    port: 2222
    hostname: deployment.example.invalid
    bin/php: '{{deploy_path}}/bin/php -d memory_limit=128M'
  production:
    remote_user: release
    <<: *base
    hostname: "192.0.2.10"
    deploy_path: "$work/production"
  staging:
    <<: *base
    remote_user: release
    deploy_path: $work/staging/ # fixture
YAML
printf "set('bin/php', '/deploy.php/is/not/read');\n" >deploy.php

"$TEST_DDEV" start
pull() {
    "$TEST_DDEV" pull typo3-deployer "$@"
}

db_value() {
    "$TEST_DDEV" mysql -Nse 'SELECT environment FROM pull_marker' | tr -d '\r'
}
check_db() {
    [[ "$(db_value)" == "$1" ]] || fail "expected database marker $1"
}
fileadmin=public/fileadmin
dump=.ddev/.downloads/db.sql
touch "$fileadmin/local-only"
mkdir -p "$fileadmin/_processed_" "$fileadmin/_temp_"
touch "$fileadmin/_processed_/keep" "$fileadmin/_temp_/keep"

begin_case 'Decline the confirmation prompt without changing local data'
if printf 'n\n' | DDEV_NONINTERACTIVE=false "$TEST_DDEV" pull typo3-deployer >"$work/confirm.log" 2>&1; then
    fail 'the pull should be cancelled when the user declines'
fi
assert_log_contains "$work/confirm.log" -F 'Pull cancelled'
test ! -e "$work/ssh.log"
test ! -e "$work/typo3.log"
test -f "$fileadmin/local-only"
# The fixture SSH alias resolves to a DNS name, while production declares
# an IP address. Both database and file pulls must use the existing alias.
begin_case 'Pull production database and files through the SSH alias; verify YAML merges, PHP flags and exclusions'
printf 'y\n' | DDEV_NONINTERACTIVE=false "$TEST_DDEV" pull typo3-deployer >"$work/first-pull.log" 2>&1 || { cat "$work/first-pull.log" >&2; fail 'combined pull failed'; }
for message in "Local DDEV project: $project" 'Selected Deployer host: production' \
    "SSH target via $project: release@deployment.example.invalid (port 2222)" \
    "Remote release: $work/production/current" 'Database export validated.' \
    'Checking local TYPO3 CLI for schema updates' 'Replacing the local database' \
    'Updating the local database schema' 'Flushing local TYPO3 caches' \
    'Database import and TYPO3 preparation complete.' \
    'Checking remote upload directories' 'Upload directory synchronization complete.'; do
    assert_log_contains "$work/first-pull.log" -F "$message"
done
check_db production
[[ "$(cat "$fileadmin/from-server")" == production ]]
test ! -e "$fileadmin/local-only"
test -L "$fileadmin/internal-link"
test ! -L "$fileadmin/external-link"
test -f "$fileadmin/_processed_/keep"
test -f "$fileadmin/_temp_/keep"
test ! -e "$fileadmin/_temp_/from-server"
test ! -e "$dump"
printf '%s\n' 'typo3 --no-interaction help database:updateschema' 'typo3 --no-interaction database:updateschema safe' 'typo3 --no-interaction cache:flush' >"$work/expected-cli.log"
cmp "$work/expected-cli.log" "$work/typo3.log"
# The explicit remote_user wins over the merge key, as in the YAML spec.
assert_log_contains "$work/ssh.log" -F -- "-T -o RemoteCommand=none -C -- $project cd -- $work/production/current && $work/production/bin/php -d memory_limit=128M vendor/bin/typo3"
assert_log_contains "$work/ssh.log" -F -- "-T -o RemoteCommand=none $project rsync --server"

begin_case 'Pull only the staging database; preserve local files'
pull --skip-files --environment=host=staging --skip-confirmation
check_db staging
assert_log_contains "$work/ssh.log" -F -- "-T -o RemoteCommand=none -C -- $project cd -- $work/staging/current &&"
[[ "$(cat "$fileadmin/from-server")" == production ]]
begin_case 'Pull only staging files; preserve the database'
pull --skip-db --environment=host=staging -y
check_db staging
[[ "$(cat "$fileadmin/from-server")" == staging ]]
begin_case 'Skip imports; verify the downloaded SQL dump is private'
pull --skip-files --skip-import
check_db staging
test -s "$dump"
if [[ "$(uname -s)" == Darwin ]]; then
    [[ "$(stat -f '%Lp' "$dump")" == 600 ]]
else
    [[ "$(stat -c '%a' "$dump")" == 600 ]]
fi
pull --skip-import
check_db staging
[[ "$(cat "$fileadmin/from-server")" == staging ]]
begin_case 'Skip both database and files without modifying the database'
pull --skip-db --skip-files -y
check_db staging

begin_case 'Reject noisy or truncated SQL dumps'
TEST_DUMP=noisy expect_failure 'dump is incomplete' pull -y
TEST_DUMP=truncated expect_failure 'dump is incomplete' pull -y
begin_case 'Report SSH authentication failures without losing the exit status'
# Both a transport failure and a remote PHP fatal error may return 255.
TEST_SSH_FAILURE=1 expect_failure 'Permission denied (publickey).' pull -y
assert_log_contains "$work/failure.log" -F 'can indicate an SSH connection error or a failed remote command'
assert_log_contains "$work/failure.log" -E 'exit status 255$'
test ! -e "$dump"
check_db staging
begin_case 'Distinguish remote PHP failures from SSH configuration errors'
for php_status in 255 1; do
    TEST_PHP_FAILURE=$php_status expect_failure 'Composer detected issues in your platform:' pull -y
    assert_log_contains "$work/failure.log" -F "If PHP failed, check the remote CLI PHP environment or bin/php for host 'production' in .hosts.yml"
    assert_log_contains "$work/failure.log" -E "exit status $php_status$"
    if grep -Fq "SSH to '$project'" "$work/failure.log" || grep -Fq "Host $project" "$work/failure.log"; then
        cat "$work/failure.log" >&2
        fail 'remote PHP error must not be diagnosed as an SSH configuration failure'
    fi
    test ! -e "$dump"
    check_db staging
    [[ "$(cat "$fileadmin/from-server")" == staging ]]
done
begin_case 'Reject missing local and remote TYPO3 Console commands; respect skip flags'
# Check the additional schema command only for a database import; no package-name
# or version heuristic is needed. Failure must not replace the local database.
# The native cache:flush command needs no preflight; actual failure is tested below.
TEST_LOCAL_CLI_MISSING=database:updateschema expect_failure "The local TYPO3 CLI cannot provide 'database:updateschema'" pull -y
test -s "$dump"
check_db staging
[[ "$(cat "$fileadmin/from-server")" == staging ]]
TEST_REMOTE_CLI_MISSING=1 expect_failure 'Check that vendor/bin/typo3 provides database:export' pull -y
test ! -e "$dump"
check_db staging
TEST_LOCAL_CLI_MISSING=database:updateschema pull --skip-db --environment=host=staging -y
TEST_LOCAL_CLI_MISSING=database:updateschema pull --skip-files --skip-import -y
check_db staging

begin_case 'Preserve existing SQL dumps and symlinks on export failure'
# DDEV normally manages its downloads directory. Test the helper directly to
# ensure it never truncates or deletes a pre-existing dump on export failure.
helper() {
    env DDEV_APPROOT="$PWD" DDEV_PROJECT="$project" host=production \
        DDEV_FILES_DIRS=/var/www/html/public/fileadmin \
        bash .ddev/typo3-deployer-pull/pull.sh "$@"
}
cp "$dump" "$work/saved-dump"
expect_failure 'already exists' helper export-db
cmp "$dump" "$work/saved-dump"
rm "$dump"
ln -s "$work/saved-dump" "$dump"
expect_failure 'already exists' helper export-db
test -L "$dump"
test -s "$work/saved-dump"
rm "$dump"

begin_case 'Report import, schema and cache failures; retain the dump until successful recovery'
# Phase-specific diagnostics and recovery: keep the valid dump on local failure.
cp "$work/saved-dump" "$dump"
TEST_IMPORT_FAILURE=1 expect_failure 'Database import failed. The local database may be incomplete.' helper import-db
test -s "$dump"
check_db staging
TEST_LOCAL_CLI_FAILURE=database:updateschema expect_failure 'Database imported, but schema update failed.' helper import-db
test -s "$dump"
check_db production
TEST_LOCAL_CLI_FAILURE=cache:flush expect_failure 'Database imported and schema updated, but cache flush failed.' helper import-db
test -s "$dump"
helper import-db
test ! -e "$dump"
check_db production
pull --skip-files --environment=host=staging -y
check_db staging

begin_case 'Reject protected project metadata as a file synchronization destination'
# Protect project metadata even when an upload path is a symlink.
mkdir -p .git
expect_failure 'protected project metadata' env DDEV_APPROOT="$PWD" DDEV_PROJECT="$project" host=production \
    DDEV_FILES_DIRS=/var/www/html/.git bash .ddev/typo3-deployer-pull/pull.sh check
ln -s ../.ddev public/metadata-link
expect_failure 'protected project metadata' env DDEV_APPROOT="$PWD" DDEV_PROJECT="$project" host=production \
    DDEV_FILES_DIRS=/var/www/html/public/metadata-link bash .ddev/typo3-deployer-pull/pull.sh check
rm public/metadata-link
rmdir .git

begin_case 'Reject SSH user or port mismatches before remote transfers'
# Explicit user or port mismatches must stop before any remote transfer or local import.
remote_calls_before=$(grep -c '^-T ' "$work/ssh.log")
for mismatch in TEST_SSH_USER=wrong TEST_SSH_PORT=22; do
    expect_failure "SSH alias '$project' does not match Deployer host 'production'" env "$mismatch" "$TEST_DDEV" pull typo3-deployer -y
    assert_log_contains "$work/failure.log" -F "Host $project"
    assert_log_contains "$work/failure.log" -F 'IdentityFile ~/.ssh/<deployment-key>'
    assert_log_contains "$work/failure.log" -F 'IdentitiesOnly yes'
    assert_log_contains "$work/failure.log" -F 'HostName deployment.example.invalid'
    case "$mismatch" in
        TEST_SSH_USER=*) assert_log_contains "$work/failure.log" -F 'Expected SSH user from .hosts.yml: release' ;;
        TEST_SSH_PORT=*) assert_log_contains "$work/failure.log" -F 'Expected SSH port from .hosts.yml: 2222' ;;
    esac
done
[[ "$(grep -c '^-T ' "$work/ssh.log")" == "$remote_calls_before" ]]
begin_case 'Reject a missing Deployer host configuration with an actionable hint'
mv .hosts.yml "$work/hosts.saved"
expect_failure 'Cannot read .hosts.yml in the DDEV project root' pull -y
assert_log_contains "$work/failure.log" -F 'Make your Deployer host configuration available there.'
mv "$work/hosts.saved" .hosts.yml
check_db staging

begin_case 'Reject unknown hosts and template-only host definitions'
expect_failure "No absolute deploy_path for host 'invalid'" pull --environment=host=invalid -y
expect_failure "No absolute deploy_path for host '.base'" pull --environment=host=.base -y
check_db staging
[[ "$(cat "$fileadmin/from-server")" == staging ]]
begin_case 'Reject missing local directories and symlinks outside the project'
mv "$fileadmin" "$work/outside"
expect_failure 'does not exist' pull --skip-files -y
ln -s "$work/outside" "$fileadmin"
expect_failure 'must resolve to a directory inside the project' pull -y
check_db staging
test -f "$work/outside/from-server"
rm "$fileadmin"
mv "$work/outside" "$fileadmin"

begin_case 'Preserve rsync exit statuses and report partial updates after database import'
TEST_RSYNC_FAILURE=1 expect_failure 'The mirror of public/fileadmin may be incomplete' pull --skip-db -y
assert_log_contains "$work/failure.log" -F 'Illegal byte sequence (92)'
assert_log_contains "$work/failure.log" -E 'exit status 23$'
check_db staging
TEST_RSYNC_FAILURE=1 TEST_RSYNC_STATUS=255 expect_failure 'can indicate an SSH connection error or a failed remote command' pull --skip-db -y
assert_log_contains "$work/failure.log" -E 'exit status 255$'
check_db staging
TEST_RSYNC_FAILURE=1 expect_failure 'Any database imported by this pull stays in place' pull -y
check_db production
[[ "$(cat "$fileadmin/from-server")" == staging ]]

begin_case 'Mirror multiple upload directories, including one outside the docroot'
cat >.ddev/config.uploads.yaml <<'YAML'
upload_dirs:
  - fileadmin
  - uploads
  - ../shared-uploads
YAML
mkdir -p public/uploads shared-uploads
touch public/uploads/local-only shared-uploads/local-only
for environment in production staging; do
    release="$work/$environment/current"
    mkdir -p "$release/public/uploads" "$release/shared-uploads"
    printf '%s\n' "$environment" >"$release/public/uploads/from-server"
    printf '%s\n' "$environment" >"$release/shared-uploads/from-server"
done
pull --skip-db --environment=host=staging -y
check_db production
[[ "$(cat public/uploads/from-server)" == staging ]]
[[ "$(cat shared-uploads/from-server)" == staging ]]
test ! -e public/uploads/local-only
test ! -e shared-uploads/local-only

begin_case 'Reject missing remote upload sources before mirroring; allow database-only pulls'
touch "$fileadmin/preflight-keep"
mv "$work/staging/current/shared-uploads" "$work/staging/missing-uploads"
expect_failure 'Remote upload directory does not exist:' pull --skip-db --environment=host=staging -y
assert_log_contains "$work/failure.log" -F 'No upload directories have been mirrored in this step.'
test -f "$fileadmin/preflight-keep"
# A missing remote upload directory must not block a database-only pull.
pull --skip-files --environment=host=staging -y
check_db staging
mv "$work/staging/missing-uploads" "$work/staging/current/shared-uploads"
pull --skip-files --environment=host=production -y
check_db production
begin_case 'Reject missing remote rsync before changing local files'
TEST_REMOTE_RSYNC_MISSING=1 expect_failure 'rsync is not available on the deployment server.' pull --skip-db --environment=host=staging -y
test -f "$fileadmin/preflight-keep"
pull --skip-db --environment=host=staging -y
test ! -e "$fileadmin/preflight-keep"

begin_case 'Skip configured node_modules directories and protect nested local dependencies'
cat >.ddev/config.uploads.yaml <<'YAML'
upload_dirs:
  - fileadmin
  - ../shared-uploads
  - ../node_modules
  - assets/node_modules
YAML
mkdir -p node_modules public/assets/node_modules public/fileadmin/node_modules
printf '%s\n' local >node_modules/keep
printf '%s\n' local >public/assets/node_modules/keep
printf '%s\n' local >public/fileadmin/node_modules/keep
# Neither excluded entry needs to exist remotely. The nested directory must
# also survive the parent fileadmin mirror with --delete.
: >"$work/ssh.log"
pull --skip-db --environment=host=staging -y >"$work/node-modules.log" 2>&1
assert_log_contains "$work/node-modules.log" -F 'Skipping dependency directory: node_modules'
assert_log_contains "$work/node-modules.log" -F 'Skipping dependency directory: public/assets/node_modules'
[[ "$(cat node_modules/keep)" == local ]]
[[ "$(cat public/assets/node_modules/keep)" == local ]]
[[ "$(cat public/fileadmin/node_modules/keep)" == local ]]
[[ "$(cat shared-uploads/from-server)" == staging ]]
if grep -Fq '/node_modules/' "$work/ssh.log"; then
    cat "$work/ssh.log" >&2
    fail 'node_modules must not be a remote source directory'
fi
begin_case 'Prevent remote node_modules from overwriting or adding local dependencies'
# Existing remote dependencies must not overwrite local dependencies either.
mkdir -p "$work/staging/current/public/fileadmin/node_modules"
printf '%s\n' remote >"$work/staging/current/public/fileadmin/node_modules/keep"
touch "$work/staging/current/public/fileadmin/node_modules/remote-only"
pull --skip-db --environment=host=staging -y
[[ "$(cat public/fileadmin/node_modules/keep)" == local ]]
test ! -e public/fileadmin/node_modules/remote-only

begin_case 'Complete a dependency-only file pull without invoking rsync'
printf 'upload_dirs:\n  - ../node_modules\n' >.ddev/config.uploads.yaml
: >"$work/ssh.log"
pull --skip-db --environment=host=staging -y >"$work/dependency-only.log" 2>&1 || { cat "$work/dependency-only.log" >&2; fail 'dependency-only pull failed'; }
assert_log_contains "$work/dependency-only.log" -F 'No upload directories to synchronize after excluding node_modules.'
[[ "$(cat node_modules/keep)" == local ]]
if grep -Fq 'rsync --server' "$work/ssh.log"; then
    cat "$work/ssh.log" >&2
    fail 'a dependency-only upload list must not invoke rsync'
fi
check_db production

begin_case 'Reject unsafe remote path characters'
# Remote paths reach the remote shell unquoted, so they are refused early.
mkdir 'shared uploads'
printf 'upload_dirs:\n  - fileadmin\n  - "../shared uploads"\n' >.ddev/config.uploads.yaml
expect_failure "Remote path 'shared uploads' may only contain" pull --environment=host=staging -y
check_db production
rmdir 'shared uploads'
cat >.ddev/config.uploads.yaml <<'YAML'
upload_dirs:
  - fileadmin
  - uploads
  - ../shared-uploads
YAML

begin_case 'Reject a secondary upload destination outside the project'
mv public/uploads "$work/outside-uploads"
ln -s "$work/outside-uploads" public/uploads
expect_failure 'public/uploads must resolve to a directory inside the project' pull --environment=host=staging -y
check_db production
[[ "$(cat "$work/outside-uploads/from-server")" == staging ]]
rm public/uploads
mv "$work/outside-uploads" public/uploads
rm .ddev/config.uploads.yaml

begin_case 'Pull with an empty docroot and the default executable TYPO3 CLI'
mkdir -p "$work/production/current/fileadmin" fileadmin
touch "$work/production/current/fileadmin/root-docroot"
printf 'hosts:\n  production:\n    hostname: deployment.example.invalid\n    deploy_path: %s/production\n' "$work" >.hosts.yml
# The default must invoke the executable directly, not prefix it with php.
cat >"$work/bin/php" <<'BASH'
#!/usr/bin/env bash
echo 'Unexpected explicit php invocation' >&2
exit 99
BASH
chmod +x "$work/bin/php"
"$TEST_DDEV" config --docroot=''
printf '<?php echo "fixture";\n' >index.php
pull --skip-files -y
check_db production
assert_log_contains "$work/ssh.log" -F -- "cd -- $work/production/current && vendor/bin/typo3 --no-interaction database:export"
pull --skip-db -y
test -f fileadmin/root-docroot

pass_case
