#!/usr/bin/env bash
#ddev-generated
# SPDX-FileCopyrightText: 2026 Eric Harrer
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

cd -P -- "${DDEV_APPROOT:?Run this script through ddev pull deployer}"
project_root=$PWD
export host="${host:?No Deployer host selected}"
files="${DDEV_DOCROOT:+${DDEV_DOCROOT}/}fileadmin"
dump=.ddev/.downloads/db.sql

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

check_programs() {
    local program missing=""
    for program in ddev ssh rsync awk sed tr head tail rm; do
        command -v "$program" >/dev/null || missing="$missing $program"
    done
    [[ -z "$missing" ]] || die "Missing on this machine:$missing. Nothing has been imported."
}

enter_fileadmin() {
    cd -P -- "./$files" 2>/dev/null \
        || die "$files does not exist. Run ddev restart or create the directory."
    case "$PWD/" in
        "$project_root/"?*) ;;
        *) die "$files must resolve to a directory inside the project, but resolves to $PWD." ;;
    esac
}

read_deploy_path() {
    awk '
        { sub(/\r$/, "") }
        /^[^ #]/ {
            in_hosts = ($0 ~ /^hosts:[[:space:]]*(#.*)?$/)
            selected = 0
        }
        in_hosts && /^  [^ #]/ {
            name = $1
            sub(/:$/, "", name)
            hosts = hosts " " name
            selected = (name == ENVIRON["host"])
        }
        selected && /^    deploy_path:[[:space:]]/ {
            path = $2
            if (NF > 2 && $3 !~ /^#/) {
                print "deploy_path must be a single path without whitespace" > "/dev/stderr"
                exit 1
            }
            if (path ~ /^".*"$/ || path ~ /^\047.*\047$/) {
                path = substr(path, 2, length(path) - 2)
            }
            if (path != "" && path !~ /^#/) {
                print path
                found = 1
            }
            exit
        }
        END {
            if (!found) {
                print "No usable deploy_path for " ENVIRON["host"] " in .hosts.yml. Hosts:" hosts > "/dev/stderr"
                exit 1
            }
        }
    ' .hosts.yml
}

# The remote login shell interprets a command string, not an argv array.
quote_for_remote_shell() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

validate_dump() {
    [[ "$(head -n 2 "$dump")" == $'\n-- Dump of TYPO3 Connection "Default"' ]] \
        && [[ "$(tail -n 1 "$dump")" == '-- Dump completed'* ]] \
        || die "The dump is incomplete or contains unexpected output. The database has not been imported."
}

case "${1:-}" in
    check)
        check_programs
        read_deploy_path >/dev/null
        enter_fileadmin
        ;;
    export-db)
        deploy_path=$(read_deploy_path)
        php_command=$(tr -d '\r' < deploy.php | sed -n "s/^set('bin\/php', '\(.*\)');$/\1/p")
        php_command=${php_command//\{\{deploy_path\}\}/"${deploy_path}"}
        [[ "$php_command" != *$'\n'* ]] || die "Expected one bin/php assignment in deploy.php."
        # Deployer treats bin/php as a trusted command, including PHP flags.
        echo "Exporting the database of $host ($deploy_path) ..."
        umask 077
        set -o noclobber
        ssh -T -o RemoteCommand=none -C -- "$DDEV_PROJECT" \
            "cd -- $(quote_for_remote_shell "$deploy_path/current") && ${php_command:-php} vendor/bin/typo3 --no-interaction database:export -c Default -e 'cache_*' -e '[bf]e_sessions' -e sys_log -e sys_http_report -e sys_file_processedfile" > "$dump"
        validate_dump
        ;;
    import-db)
        validate_dump
        ddev import-db --file="$dump"
        ddev typo3 database:updateschema '*.add,*.change'
        ddev typo3 cache:flush
        rm -- "$dump"
        ;;
    mirror-files)
        deploy_path=$(read_deploy_path)
        enter_fileadmin
        echo "Mirroring fileadmin of $host ($deploy_path) ..."
        rsync -rltz --safe-links --delete --exclude=_processed_/ --exclude=_temp_/ \
            -e 'ssh -T -o RemoteCommand=none' \
            --rsync-path="cd -- $(quote_for_remote_shell "$deploy_path/current/$files") && rsync" \
            -- "$DDEV_PROJECT:./" ./
        ;;
    *)
        die "Unknown pull step: ${1:-}"
        ;;
esac
