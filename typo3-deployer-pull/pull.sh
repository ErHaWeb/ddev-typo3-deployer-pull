#!/usr/bin/env bash
#ddev-generated
# SPDX-FileCopyrightText: 2026 Eric Harrer
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

cd -P -- "${DDEV_APPROOT:?Run this script through ddev pull deployer}"
project_root=$PWD
host=${host:?No Deployer host selected}
ssh_host=${DDEV_PROJECT:?No DDEV project selected}
ssh_options=(-T -o RemoteCommand=none)
dump=.ddev/.downloads/db.sql

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

check_programs() {
    local program missing=""
    for program in ddev ssh rsync; do
        command -v "$program" >/dev/null || missing="$missing $program"
    done
    [[ -z "$missing" ]] || die "Missing on this machine:$missing. Nothing has been imported."
}

# Deployer runs only in CI. Read the selected host from .hosts.yml with the yq
# of the DDEV web container, resolving anchors and merge keys as the YAML spec
# and Deployer do, with Deployer's defaults for hostname and bin/php.
read_deployment() {
    local values
    values=$(ddev exec --raw -- env "DEPLOYER_HOST=$host" yq --yaml-fix-merge-anchor-to-spec=true '
        .hosts[strenv(DEPLOYER_HOST)]
        | [.deploy_path, .hostname // strenv(DEPLOYER_HOST), .remote_user, .port, .["bin/php"] // "php"]
        | map((. // "") | to_string | select(test("^[^\\x00-\\x1f\\x7f]*$")))
        | select(length == 5) | .[]
        ' /var/www/html/.hosts.yml) || die "Could not read .hosts.yml with the yq of the DDEV web container."
    { IFS= read -r deploy_path && IFS= read -r ssh_hostname && IFS= read -r ssh_user &&
        IFS= read -r ssh_port && IFS= read -r php_command; } <<< "$values" \
        || die "The settings of host '$host' in .hosts.yml must be single-line values."
    deploy_path=${deploy_path%/}
    [[ "$deploy_path" == /?* ]] || die "No absolute deploy_path for host '$host' in .hosts.yml."
    check_remote_path "$deploy_path"
    # The deployment metadata is used to validate the effective SSH target.
    [[ "$ssh_hostname$ssh_user$ssh_port" != *[[:space:]]* ]] \
        || die "hostname, remote_user and port of host '$host' must not contain whitespace."
    php_command=${php_command//\{\{deploy_path\}\}/"$deploy_path"}
    [[ "$php_command" != *'{{'* ]] || die "bin/php of host '$host' may only use the placeholder {{deploy_path}}."
}

# Remote paths reach the remote shell unquoted, because openrsync drops quotes.
check_remote_path() {
    case "$1" in
        *[!A-Za-z0-9._/@+=,-]*) die "Remote path '$1' may only contain letters, digits and ._/@+=,- characters." ;;
    esac
    case "/${1#/}/" in
        */../*|*/./*|*//*) die "Remote path '$1' must not contain empty, . or .. segments." ;;
    esac
}

explain_ssh_configuration() {
    printf '%s\n' "Check the existing SSH alias in ~/.ssh/config:" "" \
        "Host $ssh_host" \
        "    HostName $ssh_hostname" \
        "    User ${ssh_user:-<deployment-user>}" \
        "    Port ${ssh_port:-22}" \
        "    IdentityFile ~/.ssh/<deployment-key>" \
        "    IdentitiesOnly yes" "" >&2
}

# Keep the project's SSH alias and let OpenSSH resolve all connection settings.
# Only compare explicitly configured user/port; otherwise OpenSSH owns them.
check_ssh_configuration() {
    local config key value rest hostname='' user='' port=''
    if ! config=$(ssh -G "${ssh_options[@]}" -- "$ssh_host"); then
        explain_ssh_configuration
        die "Could not read the SSH configuration for '$ssh_host'."
    fi
    while read -r key value rest; do
        case "$key" in
            hostname) hostname=$value ;;
            user) user=$value ;;
            port) port=$value ;;
        esac
    done <<< "$config"
    if [[ -z "$hostname" || -z "$user" || -z "$port" ]] \
        || ! (shopt -s nocasematch; [[ "$hostname" == "$ssh_hostname" ]]) \
        || [[ -n "$ssh_user" && "$user" != "$ssh_user" ]] \
        || [[ -n "$ssh_port" && "$port" != "$ssh_port" ]]; then
        printf '%s\n' "SSH alias '$ssh_host' does not match Deployer host '$host'." \
            "Effective SSH target: $user@$hostname port $port" >&2
        explain_ssh_configuration
        die "The pull stopped before importing any data in this step."
    fi
}

# SSH uses 255 for transport errors but also forwards remote exit statuses.
# Neither an SSH command nor rsync returning 255 proves a connection failure.
explain_status_255() {
    (($1 == 255)) || return 0
    printf '%s\n' "Exit status 255 for '$ssh_host' (Deployer host '$host') can indicate an SSH connection error or a failed remote command." \
        "See the error output above. If SSH failed, check the network, host key and authentication." >&2
}

resolve_upload_directory() (
    cd -P -- "$project_root/$1" 2>/dev/null \
        || die "$1 does not exist. Run ddev restart or create the directory."
    [[ "$PWD/" == "$project_root/"?* ]] \
        || die "$1 must resolve to a directory inside the project, but resolves to $PWD."
    printf '%s\n' "$PWD"
)

# DDEV lists the effective upload_dirs as container paths in DDEV_FILES_DIRS.
read_upload_directories() {
    local path resolved previous
    local -a paths destinations=()
    [[ -n "${DDEV_FILES_DIRS:-}" ]] || die "DDEV lists no upload directory. Check upload_dirs."
    IFS=, read -r -a paths <<< "$DDEV_FILES_DIRS"
    upload_directories=()
    for path in "${paths[@]}"; do
        path=${path#/var/www/html/}
        # DDEV also uses upload_dirs for Mutagen exclusions such as node_modules.
        case "$path" in
            node_modules|*/node_modules)
                printf 'Skipping dependency directory: %s\n' "$path"
                continue
                ;;
        esac
        [[ "$path" != /* ]] || die "Upload directory '$path' must lie inside the project."
        check_remote_path "$path"
        resolved=$(resolve_upload_directory "$path") || exit 1
        for previous in ${destinations[@]+"${destinations[@]}"}; do
            [[ "$resolved/" != "$previous/"* && "$previous/" != "$resolved/"* ]] \
                || die "Upload directories overlap: $resolved and $previous."
        done
        upload_directories+=("$path")
        destinations+=("$resolved")
    done
}

validate_dump() {
    [[ "$(head -n 2 "$dump")" == $'\n-- Dump of TYPO3 Connection "Default"' ]] \
        && [[ "$(tail -n 1 "$dump")" == '-- Dump completed'* ]] \
        || die "The dump is incomplete or contains unexpected output. The database has not been imported."
}

mirror_upload_directory() (
    local destination
    # Assign first: a failed substitution inside cd would leave cd at "".
    destination=$(resolve_upload_directory "$1") || exit 1
    cd -P -- "$destination"
    echo "Mirroring $1 of $host ($deploy_path) ..."
    rsync -rltz --safe-links --delete --exclude=_processed_/ --exclude=_temp_/ --exclude=node_modules/ -e "ssh ${ssh_options[*]}" \
        -- "$ssh_host:$deploy_path/current/$1/" ./ || {
        status=$?
        explain_status_255 "$status"
        printf '%s\n' "The mirror of $1 may be incomplete. Any database imported by this pull stays in place." \
            "After fixing the cause above, repeat the pull with --skip-db." >&2
        exit "$status"
    }
)

case "${1:-}" in
    check)
        check_programs
        read_deployment
        check_ssh_configuration
        read_upload_directories >/dev/null
        ;;
    export-db)
        read_deployment
        check_ssh_configuration
        echo "Exporting the database of $host ($deploy_path) ..."
        umask 077
        set -o noclobber
        trap 'rm -f -- "$dump"' EXIT
        # Like Deployer, treat bin/php as a trusted command including flags.
        ssh "${ssh_options[@]}" -C -- "$ssh_host" \
            "cd -- $deploy_path/current && $php_command vendor/bin/typo3 --no-interaction database:export -c Default -e 'cache_*' -e '[bf]e_sessions' -e sys_log -e sys_http_report -e sys_file_processedfile" > "$dump" || {
            status=$?
            explain_status_255 "$status"
            printf '%s\n' "The database export of $host failed. The database has not been imported." \
                "If PHP failed, check bin/php for host '$host' in .hosts.yml (default: php)." >&2
            exit "$status"
        }
        validate_dump
        trap - EXIT
        ;;
    import-db)
        validate_dump
        ddev import-db --file="$dump"
        ddev typo3 database:updateschema '*.add,*.change'
        ddev typo3 cache:flush
        rm -- "$dump"
        ;;
    mirror-files)
        read_deployment
        check_ssh_configuration
        read_upload_directories
        for directory in ${upload_directories[@]+"${upload_directories[@]}"}; do
            mirror_upload_directory "$directory"
        done
        ;;
    *)
        die "Unknown pull step: ${1:-}"
        ;;
esac
