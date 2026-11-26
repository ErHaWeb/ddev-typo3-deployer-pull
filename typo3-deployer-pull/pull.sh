#!/usr/bin/env bash
#ddev-generated
# SPDX-FileCopyrightText: 2026 Eric Harrer
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

cd -P -- "${DDEV_APPROOT:?Run this script through ddev pull deployer}"
project_root=$PWD
export host="${host:?No Deployer host selected}"
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

check_ssh_configuration() {
    local configured defaults
    # Ignore settings such as a global IdentitiesOnly policy that still leave
    # the destination and identities at the OpenSSH defaults.
    local ssh_fields='^(hostname|user|port|identityfile|identityagent|certificatefile|proxycommand|proxyjump|pkcs11provider|securitykeyprovider|hostkeyalias)$'

    configured=$(ssh -G -T -o RemoteCommand=none -- "$DDEV_PROJECT" | awk -v fields="$ssh_fields" '$1 ~ fields') \
        || die "Could not read SSH settings for '$DDEV_PROJECT'. Check ~/.ssh/config. The pull stopped before importing any data."
    defaults=$(ssh -G -F /dev/null -T -o RemoteCommand=none -- "$DDEV_PROJECT" | awk -v fields="$ssh_fields" '$1 ~ fields') \
        || die "Could not determine the OpenSSH defaults for '$DDEV_PROJECT'. The pull stopped before importing any data."

    if [[ "$configured" == "$defaults" ]]; then
        printf '%s\n' \
            "SSH has no deployment destination or identity configured for DDEV project '$DDEV_PROJECT'." \
            "Add or correct 'Host $DDEV_PROJECT' in ~/.ssh/config." \
            "Set the deployment HostName, User and SSH key or agent settings." >&2
        die "The pull stopped before importing any data."
    fi
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

# DDEV lists the effective upload_dirs as container paths in DDEV_FILES_DIRS.
read_upload_directories() {
    local path
    local -a paths
    [[ -n "${DDEV_FILES_DIRS:-}" ]] || die "DDEV lists no upload directory. Check upload_dirs."
    IFS=, read -r -a paths <<< "$DDEV_FILES_DIRS"
    upload_directories=()
    for path in "${paths[@]}"; do
        path=${path#/var/www/html/}
        case "$path" in
            /*|'') die "DDEV upload directory '$path' must be a subdirectory of the project." ;;
            # openrsync drops the quotes of --rsync-path, so whitespace would
            # split the remote path, as for deploy_path.
            *[[:space:]]*) die "DDEV upload directory '$path' must not contain whitespace." ;;
        esac
        upload_directories+=("$path")
    done
}

enter_upload_directory() {
    cd -P -- "$project_root/$1" 2>/dev/null \
        || die "$1 does not exist. Run ddev restart or create the directory."
    [[ "$PWD/" == "$project_root/"?* ]] \
        || die "$1 must resolve to a directory inside the project, but resolves to $PWD."
}

check_upload_directories() {
    local directory resolved seen=$'\n'
    for directory in "${upload_directories[@]}"; do
        resolved=$(enter_upload_directory "$directory" && pwd -P) || exit 1
        [[ "$seen" != *$'\n'"$resolved"$'\n'* ]] \
            || die "Several DDEV upload directories resolve to $resolved."
        seen+="$resolved"$'\n'
    done
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

mirror_upload_directory() (
    enter_upload_directory "$2"
    echo "Mirroring $2 of $host ($1) ..."
    rsync -rltz --safe-links --delete --exclude=_processed_/ --exclude=_temp_/ \
        -e 'ssh -T -o RemoteCommand=none' \
        --rsync-path="cd -- $(quote_for_remote_shell "$1/current/$2") && rsync" \
        -- "$DDEV_PROJECT:./" ./ || {
        status=$?
        printf '%s\n' "The mirror of $2 may be incomplete. Any database imported by this pull stays in place." \
            "After fixing the cause above, repeat the pull with --skip-db." >&2
        exit "$status"
    }
)

case "${1:-}" in
    check)
        check_programs
        read_deploy_path >/dev/null
        check_ssh_configuration
        read_upload_directories
        check_upload_directories
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
            "cd -- $(quote_for_remote_shell "$deploy_path/current") && ${php_command:-php} vendor/bin/typo3 --no-interaction database:export -c Default -e 'cache_*' -e '[bf]e_sessions' -e sys_log -e sys_http_report -e sys_file_processedfile" > "$dump" || {
            status=$?
            ((status != 255)) || printf '%s\n' "The SSH session for '$DDEV_PROJECT' failed." \
                "Check host, user, host key and authentication in ~/.ssh/config. The database has not been imported." >&2
            exit "$status"
        }
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
        read_upload_directories
        check_upload_directories
        for directory in "${upload_directories[@]}"; do
            mirror_upload_directory "$deploy_path" "$directory"
        done
        ;;
    *)
        die "Unknown pull step: ${1:-}"
        ;;
esac
