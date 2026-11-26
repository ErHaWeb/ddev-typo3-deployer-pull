# TYPO3 Deployer Pull for DDEV

Refresh a local TYPO3 database and upload directories from an active Deployer
release with `ddev pull typo3-deployer`. Deployer itself does not run the pull;
the provider uses its deployment layout. The provider runs on the host and
uses your existing SSH configuration, agent and host-key checks. Database pulls use
TYPO3 Console and the remote application's existing database connection;
no separate database credentials or provider-specific API are required by
this add-on.

> [!WARNING]
> **Use this add-on at your own risk. A pull can permanently destroy local data.**
> It replaces the local database and mirrors the configured upload directories.
> Local uploads and edits can be overwritten or deleted. Verify the upstream
> host and local project. Back up the database and upload directories first.

## Install, update and remove

Use DDEV 1.25.0 or later. Install or update to the latest stable GitHub
release from your DDEV project directory.

```bash
ddev add-on get ErHaWeb/ddev-typo3-deployer-pull
```

To install a specific release, pass its tag.

```bash
ddev add-on get ErHaWeb/ddev-typo3-deployer-pull --version v3.0.0
```

Use `--version main` to try the current development branch. Commit the
installed files and the generated add-on manifest to share the installation
with your team.

To uninstall, run `ddev add-on remove typo3-deployer-pull`.

DDEV replaces or removes installed files that still contain
`#ddev-generated`. Remove that marker from each file you customize to keep
your changes during updates and removal. The provider YAML calls the
installed helper script. Keep both files together if you want an independent
copy. If you already have a standalone `.ddev/providers/typo3-deployer.yaml`,
save it outside that directory before installing. DDEV preserves it in place
until you move it.

## Configure the project

- Use a DDEV project of type `typo3`, with TYPO3 Console
  (`helhum/typo3-console` 8 or 9) locally and remotely for database pulls.
  Match the local database engine and version to the server.
- The host needs Bash, OpenSSH and rsync. The provider reads `.hosts.yml`
  with the `yq` of the DDEV web container, so nothing else is installed.
  The server needs rsync and a dump client usable by TYPO3 Console.

### Why TYPO3 Console is required

TYPO3 Console (`helhum/typo3-console`) enables database pulls without
separately configuring database credentials in the provider. The add-on
uses the existing SSH connection to run the TYPO3 CLI on the deployment
server. TYPO3 Console uses the database connection settings resolved by
TYPO3 at runtime, regardless of whether the project configures them through
PHP configuration files or environment variables.

The provider does not read or transfer database credentials, maintain a
separate `.my.cnf`, or depend on a hosting provider's API. The existing
TYPO3 installation remains the single source of truth for database access.
This follows Convention over Configuration and separation of concerns:
OpenSSH authenticates access to the server, TYPO3 provides the database
connection settings, and TYPO3 Console handles the database export.
A compatible MySQL or MariaDB dump client must still be available remotely.

TYPO3 Console extends the native TYPO3 CLI with the two database commands
used by this provider:

- **Remote:** [`database:export`](https://docs.typo3.org/p/helhum/typo3-console/main/en-us/CommandReference/DatabaseExport.html)
  exports the `Default` database connection using TYPO3's resolved connection
  settings and allows the provider to exclude volatile tables such as caches
  and sessions. TYPO3 Core's `impexp:export` exports records, not a complete
  SQL database dump, and is not a substitute for this command.
- **Local:** [`database:updateschema safe`](https://docs.typo3.org/p/helhum/typo3-console/main/en-us/CommandReference/DatabaseUpdateschema.html)
  reconciles the imported database with the local code using add/change
  operations, without explicit rename/drop operations. It does not initialize
  extensions. The native `extension:setup` command also performs other setup
  operations, such as static data imports, which are outside the scope of a pull.

The native TYPO3 Core command `cache:flush` clears local caches after the
schema update; it does not require TYPO3 Console. Files-only pulls do not
need either database command.

If TYPO3 Console is missing, add it to the project's Composer dependencies
using the version compatible with its TYPO3 installation:

```bash
ddev composer require helhum/typo3-console
```

Keep it in `require`, not `require-dev`, so the remote release also includes
it when deployed with `composer install --no-dev`. Deploy the updated
Composer dependencies through your normal CI pipeline. Local and remote
installations can use different compatible versions of TYPO3 Console.

### Deployer host configuration

The provider reads the Deployer hosts from `.hosts.yml` in the project root,
the file your `deploy.php` imports. Deployer itself only runs in CI and is
not needed locally. YAML anchors, aliases and merge keys work as in
Deployer, including hidden template hosts such as `.base`:

```yaml
hosts:
  .base: &base
    hostname: deploy.example.invalid
    remote_user: deploy
    port: 2222
  production:
    <<: *base
    deploy_path: /srv/example/production
  staging:
    <<: *base
    deploy_path: /srv/example/staging
```

It uses these settings of the selected host:

- `deploy_path` (required) and `hostname` (default: the host name, used
  only for SSH configuration hints).
- `remote_user` and `port` (default: whatever OpenSSH uses for that
  project alias).
- `bin/php` (optional). By default the provider invokes `vendor/bin/typo3`
  directly, so the Composer binary's shebang selects the interpreter
  (usually `#!/usr/bin/env php`, using the remote shell's `PATH`). Set
  `bin/php` only if you need a specific PHP binary or flags, such as a custom
  `php.ini`. `{{deploy_path}}` is resolved; other placeholders are refused.
  The override runs in the remote shell as a trusted command, as in Deployer.
  Deployer itself applies host settings the same way. The provider does not
  read `deploy.php`.

For a conventional setup, leave `bin/php` out of `.hosts.yml`. Verify the
CLI in the same non-interactive SSH environment used by the provider:

```bash
ssh -T -o RemoteCommand=none example-typo3 \
  'cd /srv/example/production/current && vendor/bin/typo3 --version'
```

The PHP version and configuration on the remote server must meet the
requirements of that release. A working interactive login does not guarantee
that the non-interactive shell has the same `PATH` or PHP configuration.
If the direct invocation fails, fix the server's CLI environment or set the
optional override. A project that needs additional PHP flags can, for example,
use `bin/php: '/usr/bin/php8.5-cli -c {{deploy_path}}/shared/php-cli.ini'`.
The local DDEV PHP version is independent of the remote CLI.

SSH and rsync connect using the existing alias named after the DDEV project
(`DDEV_PROJECT`). OpenSSH resolves the hostname, user, port, keys, proxies
and host key checks from `~/.ssh/config` and the agent. For example, for a
DDEV project named `example-typo3`:

```sshconfig
Host example-typo3
    HostName deploy.example.invalid
    User deploy
    Port 2222
    IdentityFile ~/.ssh/example-deploy
    IdentitiesOnly yes
```

The provider uses `ssh -G` to read the effective SSH configuration and
compare any explicitly configured `remote_user` and `port` with the selected
Deployer host before exporting or mirroring. A user or port mismatch stops
the pull. Hostnames are not compared or resolved by the provider: the SSH
alias may use a DNS name while `.hosts.yml` uses an IP address, or vice versa.
OpenSSH remains responsible for the connection and host-key verification.
The project alias must point to the intended deployment server; the provider
does not verify that both hostnames identify the same server. There is no
direct-connection fallback. Hosts sharing the same SSH target can use the
same alias with different `deploy_path` values. For different SSH targets,
use separate DDEV projects with their own existing aliases.

`deploy_path` and the upload directories reach the remote shell unquoted,
because openrsync drops quotes. They may only contain letters, digits and
`._/@+=,-`, without empty, `.` or `..` segments. `hostname`, `remote_user`
and `port` must not contain whitespace.

For database pulls, `<deploy_path>/current` must contain the TYPO3 Composer
CLI at `vendor/bin/typo3` (executable when no `bin/php` override is set).
For file pulls it must contain the upload directories at the same paths
relative to the project root as in DDEV. The provider mirrors DDEV's effective `upload_dirs`, except directories
named `node_modules`. TYPO3 defaults to
`fileadmin` when no custom list is configured. To also mirror `uploads`,
configure both directories in `.ddev/config.yaml`:

```yaml
upload_dirs:
  - fileadmin
  - uploads
```

DDEV resolves these paths relative to the docroot. Each local destination
must already exist and resolve to a directory inside the project that does
not overlap with another upload directory. The project root and project
metadata directories `.git` and `.ddev` (including symlinks into them) are
not valid upload destinations. Do not list local source or dependency
directories as uploads, other than the documented `node_modules` exception.

DDEV also uses `upload_dirs` to exclude directories from Mutagen syncing.
Entries named `node_modules` (for example `../node_modules` with a `public`
docroot) are skipped automatically, even if they do not exist on the server.
Nested `node_modules` directories within mirrored uploads are also excluded
from transfer and deletion. Other upload directories, including those outside
the docroot, are still mirrored. If only `node_modules` entries are configured,
the files step is a no-op.

## Use

### Before you pull

- **Verify the local project and the upstream host.** The default upstream
  host is `production`. Use this add-on in disposable development environments.
- **Back up the database and upload directories separately.** A DDEV snapshot
  covers the database. Keep a separate copy of the upload directories outside
  the project and verify that both backups can be restored. See [DDEV database snapshots](https://docs.ddev.com/en/stable/users/usage/database-management/#snapshots).
- **Plan for partial failure.** The database is replaced before files are
  mirrored. A failed import can leave an incomplete database. An interrupted
  file transfer can leave the new database paired with partly updated or
  deleted files. Recover local changes from your backups.
- **Check automation.** `-y` skips confirmation. Non-interactive runs can
  also proceed without prompting.
- **Protect production data.** Dumps and uploads may contain personal or
  confidential information. Pull only data you are authorized to store and
  use locally, and restrict access to the copies and backups.

### Pull commands

```bash
ddev pull typo3-deployer                               # Production, prompts in an interactive terminal
ddev pull typo3-deployer --environment=host=staging    # Select another Deployer host
ddev pull typo3-deployer -y                            # Accept replacement without prompting
ddev pull typo3-deployer --skip-files                  # Database only
ddev pull typo3-deployer --skip-db                     # Files only
ddev pull typo3-deployer --skip-files --skip-import    # Fetch and validate a dump without importing
```

DDEV runs the preflight before anything else and does not tell it about
skip flags. So it always requires rsync, a valid host in `.hosts.yml` and
valid upload destinations. If the SSH configuration cannot be read, is
incomplete, or has a user or port mismatch, the provider shows the `Host`
block above with a placeholder for the key. Exit status 255 can indicate an
SSH connection error or a failed remote command (including a PHP fatal error).
Check the original error output; for a PHP error, verify the remote CLI
PHP environment or optional `bin/php` in `.hosts.yml`. The remote CLI must
provide `database:export` (normally from TYPO3 Console).
The PHP version in the local DDEV container does not control the remote
export. SSH disables a forced TTY and remote commands from `~/.ssh/config`.
The export reads the `Default` connection and streams the dump over
compressed SSH. Caches,
sessions, `sys_log`, `sys_http_report` and `sys_file_processedfile` are
excluded. Extra dump options belong in TYPO3 Console's configuration for
`database:export`.

The provider requires SSH to succeed and checks the dump's TYPO3 Console
header and completion footer before import. These checks detect interrupted
or contaminated streams. Import can still fail on SQL errors or an
incompatible database. Before replacing the local database, the provider
checks that the local TYPO3 CLI can provide `database:updateschema`.
A local CLI that cannot bootstrap must be repaired first. The native Core
command `cache:flush` needs no separate availability check. After import,
the provider runs `database:updateschema safe` (add/change operations, not
rename/drop) and the native `cache:flush`. It does not initialize extensions or run upgrade
wizards. The dump is deleted after all three local steps succeed. Failed
imports or post-import steps and `--skip-import` can leave a restricted-
permission dump at `.ddev/.downloads/db.sql`. A failed export removes only the
dump it created; the helper refuses to overwrite an existing dump. DDEV itself
manages the downloads directory, so save any dump you need to keep outside it
before another pull. Treat dumps and imported data as sensitive.

Rsync mirrors content, timestamps and safe symlinks. It deletes local files
absent upstream. It leaves `_processed_/`, `_temp_/` and `node_modules/` alone and uses local
ownership and permission defaults. Run one pull at a time
per project. The provider handles a single database connection and the
upload directories listed by DDEV.

Before the first rsync, the files step checks that rsync is available remotely
and all requested remote upload directories exist. This avoids starting a
partial file mirror when a later source is already missing. Because DDEV's
preflight has no skip flags and the files step runs after the database import,
a remote file preflight failure can still leave the new local database in place.
It does not block database-only pulls. If rsync fails, the provider shows its
error, keeps its exit status and warns that the mirror may be incomplete.
After resolving the error, use `--skip-db` to retry the files alone. A running
pull is not atomic; avoid concurrent pulls and deployments that change the
`current` symlink while pulling.

## Platform coverage

Previous releases were tested on Apple Silicon macOS with OrbStack, DDEV
1.25.0 and 1.25.6, Homebrew rsync and the macOS openrsync client. The smoke
test uses a disposable project, a synthetic MySQL database, a local SSH
stand-in and fixtures for TYPO3 Console. Run a fresh smoke test for changes
with `bash tests/smoke.sh`. Set
`TEST_RSYNC=/path/to/rsync` to test another rsync implementation.

Linux and WSL2 are expected to work with the required host tools. Native
Windows with the standard Git Bash installation typically lacks rsync.

## License and liability

Created by [Eric Harrer](https://github.com/ErHaWeb).

The add-on is licensed under the [GNU General Public License](LICENSE.txt),
version 2 or any later version (`GPL-2.0-or-later`). The DDEV installation
includes the license in `.ddev/typo3-deployer-pull/COPYING`. Keep the
license and copyright notices with any copies you distribute.

The warranty disclaimer and limitation of liability apply to the extent
permitted by applicable law. Mandatory liability remains unaffected.
