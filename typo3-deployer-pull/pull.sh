#!/usr/bin/env bash
#ddev-generated
# SPDX-FileCopyrightText: 2026 Eric Harrer
# SPDX-License-Identifier: GPL-2.0-or-later

set -euo pipefail

cd -P -- "${DDEV_APPROOT:?Run this script through ddev pull typo3-deployer}"
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
    [[ -z "$missing" ]] || die "Missing on this machine:$missing. Install the missing host tools and retry. Nothing has been imported."
}

# Deployer runs only in CI. Read the selected host from .hosts.yml with the yq
# of the DDEV web container, resolving anchors and merge keys as the YAML spec
# and Deployer do. The PHP override is optional; the CLI normally selects PHP.
read_deployment() {
    local values
    [[ -f .hosts.yml && -r .hosts.yml ]] \
        || die "Cannot read .hosts.yml in the DDEV project root ($project_root). Make your Deployer host configuration available there."
    values=$(ddev exec --raw -- env "DEPLOYER_HOST=$host" yq --yaml-fix-merge-anchor-to-spec=true '
        .hosts[strenv(DEPLOYER_HOST)]
        | [.["bin/php"], .deploy_path, .remote_user, .port, .hostname // strenv(DEPLOYER_HOST)]
        | map((. // "") | to_string | select(test("^[^\\x00-\\x1f\\x7f]*$")))
        | select(length == 5) | .[]
        ' /var/www/html/.hosts.yml) || die "Could not read .hosts.yml with the yq of the DDEV web container. Check the YAML syntax and use a supported DDEV version (see the README)."
    { IFS= read -r php_command && IFS= read -r deploy_path && IFS= read -r ssh_user &&
        IFS= read -r ssh_port && IFS= read -r ssh_hostname; } <<< "$values" \
        || die "The settings of host '$host' in .hosts.yml must be single-line values."
    deploy_path=${deploy_path%/}
    [[ "$deploy_path" == /?* ]] || die "No absolute deploy_path for host '$host' in .hosts.yml."
    check_remote_path "$deploy_path"
    # The hostname is only used for SSH configuration hints; user and port are
    # compared when explicitly configured.
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
    printf '%s\n' "Check the existing SSH alias in ~/.ssh/config (example; keep your working hostname and key):" "" \
        "Host $ssh_host" \
        "    HostName ${1:-$ssh_hostname}" \
        "    User ${ssh_user:-<deployment-user>}" \
        "    Port ${ssh_port:-22}" \
        "    IdentityFile ~/.ssh/<deployment-key>" \
        "    IdentitiesOnly yes" "" >&2
}

# Keep the project's SSH alias and let OpenSSH resolve all connection settings.
# Only compare explicitly configured user/port; hostname spellings can differ
# (for example, a DNS name in SSH config and an IP address in .hosts.yml).
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
        || [[ -n "$ssh_user" && "$user" != "$ssh_user" ]] \
        || [[ -n "$ssh_port" && "$port" != "$ssh_port" ]]; then
        printf '%s\n' "SSH alias '$ssh_host' does not match Deployer host '$host'." \
            "Effective SSH target: $user@$hostname port $port" >&2
        [[ -z "$ssh_user" || "$user" == "$ssh_user" ]] \
            || printf 'Expected SSH user from .hosts.yml: %s\n' "$ssh_user" >&2
        [[ -z "$ssh_port" || "$port" == "$ssh_port" ]] \
            || printf 'Expected SSH port from .hosts.yml: %s\n' "$ssh_port" >&2
        explain_ssh_configuration "$hostname"
        die "The pull stopped before importing any data in this step."
    fi
    effective_ssh_target="$user@$hostname (port $port)"
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
    case "$PWD/" in
        "$project_root/.git/"*|"$project_root/.ddev/"*)
            die "Upload directory '$1' resolves to protected project metadata: $PWD." ;;
    esac
    printf '%s\n' "$PWD"
)

# DDEV lists the effective upload_dirs as container paths in DDEV_FILES_DIRS.
read_upload_directories() {
    local path resolved previous
    local -a paths destinations=()
    [[ -n "${DDEV_FILES_DIRS:-}" ]] || die "DDEV lists no upload directory. Check upload_dirs in .ddev/config.yaml and its overrides, then run ddev restart."
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
        case "$path/" in
            .git/*|.ddev/*) die "Upload directory '$path' points to protected project metadata." ;;
        esac
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

# Check every source before the first destructive rsync, not in auth_command:
# DDEV does not expose skip flags there, and database-only pulls need no files.
check_remote_upload_directories() {
    local directory command status
    echo "Checking remote upload directories before synchronizing files ..."
    command="command -v rsync >/dev/null || { echo 'rsync is not available on the deployment server.' >&2; exit 1; };"
    for directory in "${upload_directories[@]}"; do
        command+=" test -d $deploy_path/current/$directory || { echo 'Remote upload directory does not exist: $deploy_path/current/$directory' >&2; exit 1; };"
    done
    ssh "${ssh_options[@]}" -- "$ssh_host" "$command" || {
        status=$?
        explain_status_255 "$status"
        printf '%s\n' 'Remote file preflight failed. No upload directories have been mirrored in this step.' \
            'Check rsync on the server, DDEV upload_dirs and the selected release.' \
            'Any database imported by this pull stays in place. After fixing the cause, repeat the same pull with --skip-db (keep the selected host).' >&2
        exit "$status"
    }
}

check_local_cli() {
    local status
    ddev typo3 --no-interaction help database:updateschema >/dev/null || {
        status=$?
        printf '%s\n' "The local TYPO3 CLI cannot provide 'database:updateschema'." \
            'Check the local PHP version, Composer installation and helhum/typo3-console, which provides the schema update command.' \
            'The database has not been imported.' \
            'If you need to keep the downloaded dump, save it securely outside .ddev/.downloads before another pull.' >&2
        exit "$status"
    }
}

validate_dump() {
    [[ -f "$dump" && ! -L "$dump" ]] \
        && [[ "$(head -n 2 "$dump")" == $'\n-- Dump of TYPO3 Connection "Default"' ]] \
        && [[ "$(tail -n 1 "$dump")" == '-- Dump completed'* ]] \
        || die "The dump is incomplete or contains unexpected output. The database has not been imported."
}

# Keep ordinary rsync errors visible, but group repeated filename diagnostics.
report_rsync_errors() {
    local line count=0 limit=3
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            rsync:*'Illegal byte sequence'*)
                count=$((count + 1))
                ((count <= limit)) || continue
                ;;
        esac
        printf '%s\n' "$line" >&2
    done < "$1"
    if ((count > 0)); then
        printf '\nFilename encoding: %s rsync diagnostics. The receiving filesystem may reject non-UTF-8 filenames from the server.\n' "$count" >&2
        if ((count > limit)); then
            printf 'Showing the first %s filename encoding diagnostics; %s more omitted.\n' "$limit" "$((count - limit))" >&2
            printf 'Complete rsync error log: %s (may contain sensitive filenames; remove when no longer needed).\n' "$1" >&2
            keep_error_log=1
        fi
    fi
}

mirror_upload_directory() (
    local destination error_log status keep_error_log=0
    # Assign first: a failed substitution inside cd would leave cd at "".
    destination=$(resolve_upload_directory "$1") || exit 1
    cd -P -- "$destination"
    # Capture stderr once per transfer; leave stdout and the exit status intact.
    error_log=$(mktemp "${TMPDIR:-/tmp}/typo3-deployer-rsync.XXXXXXXX") \
        || die "Could not create a temporary rsync error log. No files have been mirrored in this directory."
    trap 'if ((keep_error_log == 0)); then rm -f -- "$error_log"; fi' EXIT
    echo "Mirroring $1 of $host ($deploy_path) ..."
    rsync -rltz --safe-links --delete --exclude=_processed_/ --exclude=_temp_/ --exclude=node_modules/ -e "ssh ${ssh_options[*]}" \
        -- "$ssh_host:$deploy_path/current/$1/" ./ 2>"$error_log" || {
        status=$?
        report_rsync_errors "$error_log"
        explain_status_255 "$status"
        printf '%s\n' "The mirror of $1 may be incomplete. Any database imported by this pull stays in place." \
            "See rsync troubleshooting (including filename encoding errors): https://github.com/ErHaWeb/ddev-typo3-deployer-pull#troubleshooting" \
            "After fixing the cause above, repeat the same pull with --skip-db if the database is still current (keep the selected host)." >&2
        exit "$status"
    }
    cat "$error_log" >&2
)

case "${1:-}" in
    check)
        check_programs
        read_deployment
        check_ssh_configuration
        read_upload_directories >/dev/null
        printf 'Local DDEV project: %s\nSelected Deployer host: %s\nSSH target via %s: %s\nRemote release: %s/current\n' \
            "$DDEV_PROJECT" "$host" "$ssh_host" "$effective_ssh_target" "$deploy_path"
        ;;
    export-db)
        read_deployment
        check_ssh_configuration
        echo "Exporting the database of $host ($deploy_path) ..."
        umask 077
        set -o noclobber
        # Register cleanup only after successfully creating our own dump.
        [[ ! -e "$dump" && ! -L "$dump" ]] || die "Database dump '$dump' already exists. Move or remove it before retrying."
        if ! exec 3> "$dump"; then
            die "Could not create database dump '$dump'. The database has not been imported."
        fi
        trap 'rm -f -- "$dump"' EXIT
        # Like Deployer, treat an explicit bin/php as a trusted command including flags.
        # Otherwise execute the Composer binary directly, using its shebang.
        ssh "${ssh_options[@]}" -C -- "$ssh_host" \
            "cd -- $deploy_path/current && ${php_command:+$php_command }vendor/bin/typo3 --no-interaction database:export -c Default -e 'cache_*' -e '[bf]e_sessions' -e sys_log -e sys_http_report -e sys_file_processedfile" >&3 || {
            status=$?
            explain_status_255 "$status"
            printf '%s\n' "The database export of $host failed. The database has not been imported." \
                "Check that vendor/bin/typo3 provides database:export on the server (helhum/typo3-console)." \
                "If PHP failed, check the remote CLI PHP environment or bin/php for host '$host' in .hosts.yml." >&2
            exit "$status"
        }
        exec 3>&-
        validate_dump
        trap - EXIT
        echo "Database export validated."
        ;;
    import-db)
        validate_dump
        echo "Checking local TYPO3 CLI for schema updates ..."
        check_local_cli
        echo "Replacing the local database ..."
        ddev import-db --file="$dump" || {
            status=$?
            printf '%s\n' "Database import failed. The local database may be incomplete. Dump retained: $dump" >&2
            exit "$status"
        }
        echo "Updating the local database schema (add/change operations) ..."
        ddev typo3 --no-interaction database:updateschema safe || {
            status=$?
            printf '%s\n' "Database imported, but schema update failed. Dump retained: $dump" >&2
            exit "$status"
        }
        echo "Flushing local TYPO3 caches ..."
        ddev typo3 --no-interaction cache:flush || {
            status=$?
            printf '%s\n' "Database imported and schema updated, but cache flush failed. Dump retained: $dump" >&2
            exit "$status"
        }
        rm -- "$dump"
        echo "Database import and TYPO3 preparation complete."
        ;;
    mirror-files)
        read_deployment
        check_ssh_configuration
        read_upload_directories
        if [[ -z "${upload_directories[0]:-}" ]]; then
            echo "No upload directories to synchronize after excluding node_modules."
            exit 0
        fi
        check_remote_upload_directories
        for directory in ${upload_directories[@]+"${upload_directories[@]}"}; do
            mirror_upload_directory "$directory"
        done
        echo "Upload directory synchronization complete."
        ;;
    *)
        die "Unknown pull step: ${1:-}"
        ;;
esac
