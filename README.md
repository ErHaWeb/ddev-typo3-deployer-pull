# TYPO3 Deployer Pull for DDEV

Refresh a local TYPO3 database and upload directories from an active Deployer
release with `ddev pull deployer`. The provider runs on the host and uses your
existing SSH configuration, agent and host-key checks.

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
ddev add-on get ErHaWeb/ddev-typo3-deployer-pull --version v1.0.1
```

Use `--version main` to try the current development branch. Commit the
installed files and the generated add-on manifest to share the installation
with your team.

To uninstall, run `ddev add-on remove typo3-deployer-pull`.

DDEV replaces or removes installed files that still contain
`#ddev-generated`. Remove that marker from each file you customize to keep
your changes during updates and removal. The provider YAML calls the
installed helper script. Keep both files together if you want an independent
copy. If you already have a standalone `.ddev/providers/deployer.yaml`,
save it outside that directory before installing. DDEV preserves it in place
until you move it.

## Configure the project

- Use a DDEV project of type `typo3`, with TYPO3 Console
  (`helhum/typo3-console` 8 or 9) locally and remotely. Match the local
  database engine and version to the server.
- The host needs Bash, OpenSSH, rsync and the standard
  `awk`, `sed`, `tr`, `head`, `tail` and `rm` tools.
  The server needs rsync and a dump client usable by TYPO3 Console.
- Add an SSH alias named after the DDEV project. All environments in the
  example use that same SSH account.

```sshconfig
Host example-typo3
    HostName deploy.example.invalid
    User deploy
    Port 22
    IdentityFile ~/.ssh/example-typo3
    IdentitiesOnly yes
```

Add your Deployer hosts in the project root. The provider reads this
conventional layout with two spaces for host names and four for
`deploy_path`. Use a single path without whitespace. Plain, single-quoted
and double-quoted paths are supported. CRLF line endings are supported.

```yaml
hosts:
  production:
    deploy_path: /srv/example/production
  staging:
    deploy_path: /srv/example/staging
```

In `deploy.php` the provider recognizes an unindented assignment of a single
PHP command with optional flags. It substitutes `{{deploy_path}}` and falls
back to `php` when the assignment is absent. The configured command runs
in the remote shell, so use trusted project configuration.

```php
set('bin/php', '{{deploy_path}}/bin/php -d memory_limit=128M');
```

Each `<deploy_path>/current` must have `vendor/bin/typo3` and the upload
directories at the same paths relative to the project root as in DDEV.
The provider mirrors DDEV's effective `upload_dirs`. TYPO3 defaults to
`fileadmin` when no custom list is configured. To also mirror `uploads`,
configure both directories in `.ddev/config.yaml`:

```yaml
upload_dirs:
  - fileadmin
  - uploads
```

DDEV resolves these paths relative to the docroot. Each local destination
must already exist and resolve to a distinct directory inside the project.
Like `deploy_path`, upload directory paths must not contain whitespace.

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
ddev pull deployer                              # Production, prompts in an interactive terminal
ddev pull deployer --environment=host=staging   # Select another Deployer host
ddev pull deployer -y                           # Accept replacement without prompting
ddev pull deployer --skip-files                 # Database only
ddev pull deployer --skip-db                    # Files only
ddev pull deployer --skip-files --skip-import   # Fetch and validate a dump without importing
```

The preflight requires rsync and valid upload destinations even with skip flags.
It checks the effective OpenSSH settings for the DDEV project name before
connecting. If the destination and identity settings are all OpenSSH
defaults, add or correct the matching `Host` entry in `~/.ssh/config`.
SSH disables forced TTY and remote commands on the alias. The export reads the
`Default` connection and streams the dump over compressed SSH. Caches,
sessions, `sys_log`, `sys_http_report` and `sys_file_processedfile` are
excluded. Extra dump options belong in TYPO3 Console's configuration for
`database:export`.

The provider requires SSH to succeed and checks the dump's TYPO3 Console
header and completion footer before import. These checks detect interrupted
or contaminated streams. Import can still fail on SQL errors or an
incompatible database. After import, TYPO3 Console updates the schema with
`*.add,*.change`, flushes caches and the provider deletes the dump. Failed
runs and `--skip-import` can leave a restricted-permission dump at
`.ddev/.downloads/db.sql`. Treat it and the imported data as sensitive.

Rsync mirrors content, timestamps and safe symlinks. It deletes local files
absent upstream. It leaves `_processed_/` and `_temp_/` alone and uses local
ownership and permission defaults. Run one pull at a time
per project. The provider handles a single database connection and the
upload directories listed by DDEV.

If rsync fails, the provider shows rsync's error, keeps its exit status and
warns that the mirror may be incomplete. After resolving the error, use
`--skip-db` to retry the files alone.

## Platform coverage

Tested on Apple Silicon macOS with OrbStack, DDEV 1.25.0 and 1.25.6,
Homebrew rsync and the macOS openrsync client. The smoke test uses a
disposable project, a synthetic MySQL database, a local SSH stand-in and
fixtures for TYPO3 Console. Run it with `bash tests/smoke.sh`. Set
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
