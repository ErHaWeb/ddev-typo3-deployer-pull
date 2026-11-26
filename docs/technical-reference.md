# Technical reference

This page supplements the [quick start and usage guide](../README.md).

## Deployer host settings

The project-root `.hosts.yml` is the add-on's required shared inventory
convention, not a mandatory Deployer file. Deployer supports other file
names and PHP or YAML recipes; the provider intentionally does not discover
or evaluate those recipes. Import the shared inventory into your deployment
recipe as shown in the [quick start](../README.md#3-check-your-deployer-host-configuration).
Settings needed by the provider must be present in this inventory (including
values inherited through YAML merge keys), rather than defined only in a
Deployer recipe or callback.

The add-on reads the inventory using the Mike Farah `yq` included in the
DDEV web container. YAML anchors, aliases and merge keys
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

Each rsync transfer captures stderr in a private temporary file. On failure,
repeated `Illegal byte sequence` diagnostics are counted, with at most three
examples printed; unrelated diagnostics and the original exit status are
preserved. The complete log is retained only when diagnostics are omitted.
The pull still stops at the first failed directory, rather than starting
further destructive transfers after an error.

### Diagnosing filename encoding errors

In an rsync diagnostic, `\#351` is the octal escape for byte `0xE9` (decimal
233), which may represent `é` in ISO-8859-1 or Windows-1252 but is not a valid
standalone UTF-8 byte. The displayed escape alone does not establish the
source encoding; the receiver's `Illegal byte sequence (92)` is the relevant
filesystem error. See the [rsync manual](https://download.samba.org/pub/rsync/rsync.1.html)
and [Apple's APFS filename documentation](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html).

If Python 3 is available on the remote server, the following optional
read-only diagnostic lists names that cannot be decoded as UTF-8. Connect
using the existing SSH alias, change into the selected release and adapt
`public/fileadmin` to the affected upload directory before running it:

```bash
python3 - <<'PYTHON'
import os


def fail(error):
    raise error


for root, directories, files in os.walk(b'public/fileadmin', onerror=fail):
    for name in directories + files:
        try:
            name.decode('utf-8')
        except UnicodeDecodeError:
            print(repr(os.path.join(root, name)))
PYTHON
```

The scan reads names as bytes, not file contents, and makes no changes. It
reports invalid UTF-8, not the original character encoding. An empty result
only means no invalid UTF-8 names were found in the scanned tree. Python is
not an add-on dependency.

A permanent fix should preserve the consistency of the remote files and
TYPO3's [FAL records and references](https://docs.typo3.org/m/typo3/reference-coreapi/main/en-us/ApiOverview/Fal/UsingFal/ExamplesFileFolder.html).
Check the import source as well, so legacy names do not reappear.
GNU rsync supports `--iconv=LOCAL,REMOTE`, but a single charset conversion
is not reliable for mixed encodings and may produce local paths that differ
from TYPO3's imported file identifiers. The provider does not enable it
implicitly. Changing the locale or switching rsync implementations does not
make invalid UTF-8 filenames valid on APFS. See the
[recovery instructions](../README.md#filename-encoding-errors-on-macos).

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

## Progress reporting

The provider uses line-oriented Bash logging with ASCII status markers. ANSI
colors are enabled only when stdout is a terminal, `TERM` is set and is not
`dumb`, and `NO_COLOR` is unset or empty. DDEV may capture stdout, in which case
the provider intentionally emits plain text. Timings use Bash `SECONDS` within
each provider step; the SQL dump size uses the standard `wc -c` utility and is
informational (rounded down to whole KiB or MiB when appropriate). There is no
cross-step timer, animated progress indicator or additional rsync option, so
GNU rsync and openrsync retain the same invocation and exit-status semantics.

## Smoke tests

Run `bash tests/smoke.sh` from the repository. It creates a disposable DDEV
project, uses a synthetic MySQL database and fixture-local SSH and TYPO3
commands. It runs actual DDEV and rsync operations, not live server requests.
Use `TEST_RSYNC=/path/to/rsync bash tests/smoke.sh` to select another rsync
client. The test removes the disposable project; detailed logs and fixture
files are retained on failure.
