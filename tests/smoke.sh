#!/usr/bin/env bash

# Run with DDEV, Docker and rsync on the host. All SSH calls stay in the fixture.
set -euo pipefail

addon=$(cd "$(dirname "$0")/.." && pwd -P)
export TEST_DDEV
export TEST_RSYNC
TEST_DDEV=$(command -v ddev)
TEST_RSYNC=${TEST_RSYNC:-$(command -v rsync)}

work=$(mktemp -d /tmp/deployer-pull.XXXXXXXX)
project="deployer-pull-${work##*.}"
project=$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')
export TEST_PROJECT="$project"
export DDEV_XDG_CONFIG_HOME="$work/config"
export XDG_CONFIG_HOME="$DDEV_XDG_CONFIG_HOME"
export TEST_WORK="$work"
export DDEV_NONINTERACTIVE=true

cleanup() {
    status=$?
    trap - EXIT
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
    else
        echo "Fixture logs: $work" >&2
    fi
    exit "$status"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_failure() {
    local message=$1
    shift
    if "$@" >"$work/failure.log" 2>&1; then
        fail "expected failure: $*"
    fi
    grep -F "$message" "$work/failure.log" || {
        cat "$work/failure.log" >&2
        fail "missing error: $message"
    }
}

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

echo 'Testing install, managed update, customized update and both removal paths'
install_source=${1:-"$addon"}
if [[ $# -gt 0 ]]; then
    shift
fi
get_addon() {
    "$TEST_DDEV" add-on get "$install_source" "$@"
}
provider=.ddev/providers/deployer.yaml
copying=.ddev/typo3-deployer-pull/COPYING
manifest=.ddev/addon-metadata/typo3-deployer-pull/manifest.yaml
get_addon "$@"
cmp "$provider" "$addon/providers/deployer.yaml"
cmp "$copying" "$addon/typo3-deployer-pull/COPYING"
tail -n +5 "$copying" | cmp - "$addon/LICENSE.txt"
test -f "$manifest"
"$TEST_DDEV" pull --help >"$work/help.log"
grep -F 'Pull with deployer' "$work/help.log"
echo '# managed test edit' >>"$provider"
get_addon "$@"
cmp "$provider" "$addon/providers/deployer.yaml"
sed '/^#ddev-generated$/d' "$provider" >"$work/custom.yaml"
echo '# protected test edit' >>"$work/custom.yaml"
cp "$work/custom.yaml" "$provider"
get_addon "$@"
cmp "$provider" "$work/custom.yaml"
"$TEST_DDEV" add-on remove typo3-deployer-pull
cmp "$provider" "$work/custom.yaml"
test ! -e "$manifest"
rm "$provider"
get_addon "$@"
"$TEST_DDEV" add-on remove typo3-deployer-pull
test ! -e "$provider"
test ! -e .ddev/typo3-deployer-pull/pull.sh
test ! -e "$copying"
test ! -e "$manifest"
get_addon "$@"

# Fail rsync lookup with a private PATH, without modifying host executables.
mkdir "$work/no-rsync"
for program in ddev ssh awk sed tr head tail rm; do
    ln -s "$(command -v "$program")" "$work/no-rsync/$program"
done
expect_failure 'Missing on this machine: rsync' env PATH="$work/no-rsync" \
    DDEV_APPROOT="$PWD" DDEV_DOCROOT=public host=production \
    /bin/bash .ddev/typo3-deployer-pull/pull.sh check

# Run real rsync through a fixture-local SSH transport. Run real database imports
# while recording the two TYPO3 CLI calls, so no TYPO3 installation is required.
cat >"$work/bin/ddev" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == typo3 ]]; then
    printf '%s\n' "$*" >>"$TEST_WORK/typo3.log"
else
    exec "$TEST_DDEV" "$@"
fi
BASH
cat >"$work/bin/ssh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == '-G' ]]; then
    shift
    if [[ "$1" == '-F' ]]; then
        [[ "$2" == /dev/null ]]
        printf 'hostname %s\nuser local-user\nport 22\nidentitiesonly no\n' "$TEST_PROJECT"
    elif [[ "${TEST_SSH_CONFIG:-configured}" == defaults ]]; then
        printf 'hostname %s\nuser local-user\nport 22\nidentitiesonly yes\n' "$TEST_PROJECT"
    else
        printf 'hostname %s\nuser deployment-user\nport 22\nidentitiesonly yes\n' "$TEST_PROJECT"
    fi
    exit 0
fi
[[ "$1 $2 $3" == '-T -o RemoteCommand=none' ]]
shift 3
if [[ "$1" == '-C' ]]; then
    shift
fi
if [[ "$1" == '--' ]]; then
    shift
fi
[[ "$1" == "$TEST_PROJECT" && "$#" -ge 2 ]]
shift
touch "$TEST_WORK/ssh-connection"
exec /bin/sh -c "$*"
BASH
cat >"$work/bin/rsync" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${TEST_RSYNC_FAILURE:-}" ]]; then
    printf '%s\n' "rsync: [receiver] mkstemp failed: Illegal byte sequence (92)" >&2
    exit 23
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
exec /bin/bash "$@"
BASH
    chmod +x "$work/$environment/bin/php"
    cat >"$release/vendor/bin/typo3" <<'BASH'
case "${TEST_DUMP:-complete}" in
    noisy) echo 'Unexpected shell output' ;;
    ssh-error) exit 255 ;;
esac
environment=$(basename "$(dirname "$PWD")")
printf '\n-- Dump of TYPO3 Connection "Default"\n'
printf 'CREATE TABLE pull_marker (environment VARCHAR(40));\n'
printf "INSERT INTO pull_marker VALUES ('%s');\n" "$environment"
if [[ "${TEST_DUMP:-complete}" != truncated ]]; then
    printf '%s\n' '-- Dump completed on 2026-01-01'
fi
BASH
done

printf 'hosts:\r\n  production:\r\n    deploy_path: "%s/production"\r\n  staging:\r\n    deploy_path: %s/staging # fixture\r\n' "$work" "$work" >.hosts.yml
printf "set('bin/php', '{{deploy_path}}/bin/php -d memory_limit=128M');\r\n" >deploy.php

"$TEST_DDEV" start
pull() {
    "$TEST_DDEV" pull deployer "$@"
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

echo 'Testing SSH defaults without a deployment destination or identity'
TEST_SSH_CONFIG=defaults expect_failure 'SSH has no deployment destination or identity configured' pull -y
grep -F "Host $TEST_PROJECT" "$work/failure.log"
test ! -e "$work/ssh-connection"
test ! -e "$work/typo3.log"
test -f "$fileadmin/local-only"

echo 'Testing DDEV confirmation, combined pull, host override, skip flags and file mirroring'
if printf 'n\n' | DDEV_NONINTERACTIVE=false "$TEST_DDEV" pull deployer >"$work/confirm.log" 2>&1; then
    fail 'the pull should be cancelled when the user declines'
fi
grep -F 'Pull cancelled' "$work/confirm.log"
test ! -e "$work/typo3.log"
test -f "$fileadmin/local-only"
printf 'y\n' | DDEV_NONINTERACTIVE=false "$TEST_DDEV" pull deployer
check_db production
[[ "$(cat "$fileadmin/from-server")" == production ]]
test ! -e "$fileadmin/local-only"
test -L "$fileadmin/internal-link"
test ! -L "$fileadmin/external-link"
test -f "$fileadmin/_processed_/keep"
test -f "$fileadmin/_temp_/keep"
test ! -e "$fileadmin/_temp_/from-server"
test ! -e "$dump"
printf '%s\n' 'typo3 database:updateschema *.add,*.change' 'typo3 cache:flush' >"$work/expected-cli.log"
cmp "$work/expected-cli.log" "$work/typo3.log"

pull --skip-files --environment=host=staging --skip-confirmation
check_db staging
[[ "$(cat "$fileadmin/from-server")" == production ]]
pull --skip-db --environment=host=staging -y
check_db staging
[[ "$(cat "$fileadmin/from-server")" == staging ]]
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
pull --skip-db --skip-files -y
check_db staging

echo 'Testing failure paths before local changes'
TEST_DUMP=noisy expect_failure 'dump is incomplete' pull -y
TEST_DUMP=truncated expect_failure 'dump is incomplete' pull -y
TEST_DUMP=ssh-error expect_failure 'The SSH session for' pull -y
grep -E 'exit status 255$' "$work/failure.log"
expect_failure 'No usable deploy_path' pull --environment=host=invalid -y
check_db staging
[[ "$(cat "$fileadmin/from-server")" == staging ]]
mv "$fileadmin" "$work/outside"
expect_failure 'does not exist' pull --skip-files -y
ln -s "$work/outside" "$fileadmin"
expect_failure 'must resolve to a directory inside the project' pull -y
check_db staging
test -f "$work/outside/from-server"
rm "$fileadmin"
mv "$work/outside" "$fileadmin"

echo 'Testing an rsync failure, its exit status and a completed database import'
TEST_RSYNC_FAILURE=1 expect_failure 'The mirror of public/fileadmin may be incomplete' pull --skip-db -y
grep -F 'Illegal byte sequence (92)' "$work/failure.log"
grep -E 'exit status 23$' "$work/failure.log"
check_db staging
TEST_RSYNC_FAILURE=1 expect_failure 'Any database imported by this pull stays in place' pull -y
check_db production
[[ "$(cat "$fileadmin/from-server")" == staging ]]

echo 'Testing the effective upload_dirs list, including a path outside the docroot'
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

# openrsync drops the quotes of --rsync-path, so whitespace is refused early.
mkdir 'shared uploads'
printf 'upload_dirs:\n  - fileadmin\n  - "../shared uploads"\n' >.ddev/config.uploads.yaml
expect_failure "DDEV upload directory 'shared uploads' must not contain whitespace" pull --environment=host=staging -y
check_db production
rmdir 'shared uploads'
cat >.ddev/config.uploads.yaml <<'YAML'
upload_dirs:
  - fileadmin
  - uploads
  - ../shared-uploads
YAML

mv public/uploads "$work/outside-uploads"
ln -s "$work/outside-uploads" public/uploads
expect_failure 'public/uploads must resolve to a directory inside the project' pull --environment=host=staging -y
check_db production
[[ "$(cat "$work/outside-uploads/from-server")" == staging ]]
rm public/uploads
mv "$work/outside-uploads" public/uploads
rm .ddev/config.uploads.yaml

echo 'Testing an empty docroot and PHP fallback'
mkdir -p "$work/production/current/fileadmin" fileadmin
touch "$work/production/current/fileadmin/root-docroot"
: >deploy.php
ln -s "$work/production/bin/php" "$work/bin/php"
"$TEST_DDEV" config --docroot=''
printf '<?php echo "fixture";\n' >index.php
TEST_PHP_FLAGS=none pull --skip-files -y
check_db production
pull --skip-db -y
test -f fileadmin/root-docroot

echo 'All isolated DDEV smoke checks passed.'
