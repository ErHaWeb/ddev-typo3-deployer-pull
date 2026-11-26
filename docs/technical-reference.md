# Technical reference

This page supplements the [quick start and usage guide](../README.md).

## Deployer host settings

The add-on reads `.hosts.yml` in the DDEV project root using the Mike Farah
`yq` included in the DDEV web container. YAML anchors, aliases and merge keys
are supported using `--yaml-fix-merge-anchor-to-spec=true`.

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

| Setting | Meaning |
| --- | --- |
| `deploy_path` | Required absolute path to the deployment directory containing `current`. |
| `hostname` | Used for SSH configuration hints; defaults to the selected host name. |
| `remote_user` | Optional; if set, must match the effective SSH user. |
| `port` | Optional; if set, must match the effective SSH port. |
| `bin/php` | Optional trusted remote shell command, including PHP flags. Only `{{deploy_path}}` is resolved. |

The provider does not read `deploy.php` or need a local Deployer installation.
Without `bin/php`, the executable Composer CLI `vendor/bin/typo3` selects
its interpreter via its shebang, normally `#!/usr/bin/env php`. A remote
non-interactive shell may have a different `PATH` than an interactive login.

## SSH connection

OpenSSH resolves all connection settings from the alias matching
`DDEV_PROJECT`, including keys, proxies and host-key checks. The provider
uses `ssh -G` to compare explicitly configured `remote_user` and `port`.
Hostnames are not compared or DNS-resolved by the provider; it does not
verify equivalence between the configured Deployer host and the effective
SSH hostname. The user must verify that the alias selects the intended
server. There is no direct-connection fallback.

SSH runs with `-T -o RemoteCommand=none` to disable forced TTYs and remote
commands configured in `~/.ssh/config`. Exit status 255 can mean either a
transport failure or a remote command failure, including a PHP fatal error.

## Database export and import

The provider streams a TYPO3 Console SQL export over compressed SSH from
`<deploy_path>/current`. It uses the `Default` database connection and
excludes `cache_*`, `[bf]e_sessions`, `sys_log`, `sys_http_report` and
`sys_file_processedfile`. Additional dump options belong in the TYPO3 Console
configuration for `database:export`.

The export must exit successfully and contain the expected TYPO3 Console
header and completion footer. These checks detect incomplete or noisy
streams, not every possible SQL or compatibility error.

The SQL dump is created with restrictive permissions at
`.ddev/.downloads/db.sql`. The helper does not overwrite existing dumps or
symlinks and removes only its own failed export. DDEV itself manages the
downloads directory, so preserve any needed dump elsewhere before the next
pull. Treat it as sensitive data.

Before importing, the provider checks that the local TYPO3 CLI supplies
`database:updateschema`. It then runs:

```bash
ddev import-db --file=.ddev/.downloads/db.sql
ddev typo3 --no-interaction database:updateschema safe
ddev typo3 --no-interaction cache:flush
```

The dump is removed only after all three steps succeed. Failed imports,
failed post-import steps or `--skip-import` can leave it on disk. A schema
change can still fail or affect data; `safe` is not a substitute for backups.
The provider does not initialize extensions or execute upgrade wizards.

## File synchronization

The provider mirrors DDEV's effective `upload_dirs` at corresponding paths
relative to the project root on the server. It validates local destinations
and rejects the project root, `.git`, `.ddev`, overlapping paths and paths
that resolve outside the project. Symlinks within the project are resolved
for destination validation. Use only actual upload directories.

DDEV also uses `upload_dirs` for Mutagen exclusions. Entries named
`node_modules` are skipped automatically; nested `node_modules` are
protected from transfer and deletion. A dependency-only list is a no-op.
Other directories outside the docroot remain supported.

Because openrsync drops remote path quoting, `deploy_path` and remote upload
paths may contain only letters, digits and `._/@+=,-`, without empty, `.` or
`..` path segments (DDEV resolves docroot-relative paths first).
`hostname`, `remote_user` and `port` must not contain whitespace.

Before the first rsync, the provider checks that remote rsync is available
and every selected remote upload directory exists. It mirrors content,
timestamps and safe symlinks, using local ownership and permission defaults.
Files absent upstream are deleted. `_processed_/`, `_temp_/` and
`node_modules/` are excluded from transfers and deletions.

## Failure boundaries

DDEV's `auth_command` runs before other steps without access to skip flags.
It checks the host programs, deployment settings, SSH configuration and
local upload paths regardless of which steps are requested. The remote file
preflight runs only in the file-import step; a database-only pull is not
blocked by missing remote upload directories.

| Failed phase | Local state |
| --- | --- |
| Export or local CLI preflight | Database has not been replaced by this pull. |
| Import | Database may be incomplete. |
| Schema update | Database imported; schema update may be incomplete. |
| Cache flush | Database imported and schema updated; caches may not be cleared. |
| Remote file preflight | No upload directory mirrored in this step; database may already be imported. |
| rsync | Files may be partially updated or deleted; earlier database import remains. |

There is no transaction spanning the database and files, no automatic
rollback, and no lock spanning DDEV's separate provider steps. Avoid
concurrent pulls and deployments that change the `current` symlink.

## Installed files and customization

The add-on installs `.ddev/providers/typo3-deployer.yaml`,
`.ddev/typo3-deployer-pull/pull.sh` and `.ddev/typo3-deployer-pull/COPYING`,
plus DDEV's add-on manifest. DDEV replaces or removes installed files that
contain `#ddev-generated`. Remove that marker from each file you customize
if you want DDEV to preserve it during updates and removal. The YAML calls
the helper script; keep both together for an independent copy. Save any
existing standalone provider with the same name outside the providers
directory before installation, if you intend to replace it.

To test the development branch, use `ddev add-on get
ErHaWeb/ddev-typo3-deployer-pull --version main` (on one line). A fixed release
tag is preferable for a reproducible installation.

## Smoke tests

Run `bash tests/smoke.sh` from the repository. It creates a disposable DDEV
project, uses a synthetic MySQL database and fixture-local SSH and TYPO3
commands. It runs actual DDEV and rsync operations, not live server requests.
Use `TEST_RSYNC=/path/to/rsync bash tests/smoke.sh` to select another rsync
client. The test removes the disposable project; detailed logs and fixture
files are retained on failure.
