# TYPO3 Deployer Pull for DDEV

Bring your local TYPO3 development environment up to date with the database
and uploaded files of a production or staging website:

```bash
ddev pull typo3-deployer
```

This add-on is for Composer-based TYPO3 websites deployed with [Deployer](https://deployer.org/).
It uses your existing SSH connection and TYPO3's own database configuration.
You do not need separate database credentials, a local Deployer installation
or a hosting provider API. The add-on pulls data, not application code, and
does not push changes back to the server.

> [!WARNING]
> A pull replaces your **local database** and can overwrite or delete **local
> uploaded files**. Back up both before pulling. The add-on does not create
> backups or anonymize production data. Only pull data you are authorized to
> use locally.

## Requirements

| Where | What you need |
| --- | --- |
| Local computer | [DDEV](https://ddev.com/) 1.25.0 or later, Bash, OpenSSH and rsync |
| Local project | A Composer-based DDEV project of type `typo3` with compatible PHP and MySQL/MariaDB versions; shared `.hosts.yml` inventory in the project root |
| Deployment server | A Deployer release accessible via SSH, with rsync for file pulls and a compatible MySQL/MariaDB dump client for database pulls |
| Database pulls | [TYPO3 Console](https://github.com/TYPO3-Console/typo3_console) 8 or 9, installed locally and in the remote release |

DDEV supplies the YAML parser (`yq`); no separate installation is needed.

## Quick start

Run these commands from the root of your local DDEV project.

### 1. Install the add-on

```bash
ddev add-on get ErHaWeb/ddev-typo3-deployer-pull
ddev restart
```

### 2. Check TYPO3 Console

For database pulls, make sure TYPO3 Console is installed in both the local
project and the deployed website. If it is missing, add it as a regular
Composer dependency (not a development-only dependency):

```bash
ddev composer require helhum/typo3-console
```

Deploy the updated Composer dependencies through your normal deployment
process before pulling the database. Choose a version compatible with each
TYPO3 installation. Files-only pulls do not need TYPO3 Console.

### 3. Check your Deployer host configuration

The add-on requires a `.hosts.yml` file in the project root. This is a
convention of the add-on, not a requirement of Deployer itself. A shared
YAML host inventory lets both tools use the same deployment settings
without installing Deployer locally or maintaining duplicate configuration.

Reuse your existing inventory if it already follows this convention.
Otherwise, define your deployment hosts in `.hosts.yml`, for example:

```yaml
hosts:
  production:
    hostname: deploy.example.com
    remote_user: deploy
    deploy_path: /srv/example/production
```

Replace the example values with your own. `deploy_path` is the directory
containing Deployer's `current` link, not `current` itself.

In your existing `deploy.php` (in the `Deployer` namespace), load the shared
file using Deployer's native inventory import:

```php
import(__DIR__ . '/.hosts.yml');
```

Keep your deployment tasks and recipes unchanged, and define the hosts in
the inventory rather than duplicating their definitions in PHP. If your
Deployer recipe is written in YAML, include `.hosts.yml` in its `import`
list instead. See [Deployer's host documentation](https://deployer.org/docs/8.x/hosts#yaml-inventory)
for details.

### 4. Check your SSH connection

The add-on uses the **DDEV project name as the SSH alias**. Find the project
name with `ddev describe` (or the `name` setting in `.ddev/config.yaml`).

For a project named `example-typo3`, a typical entry in your local
`~/.ssh/config` looks like this:

```sshconfig
Host example-typo3
    HostName deploy.example.com
    User deploy
    IdentityFile ~/.ssh/example-deploy
    IdentitiesOnly yes
```

Keep your working SSH configuration and key. The provider uses the local
OpenSSH client, so `ddev auth ssh` is not required. Test the connection:

```bash
ssh example-typo3
```

Exit the remote shell before continuing. Check that the alias points to the
intended server: the provider does not verify that a DNS name and an IP
address in the two configuration files identify the same machine.

### 5. Back up and pull

A DDEV snapshot backs up the database, not uploaded files:

```bash
ddev snapshot
```

Make a separate backup of your upload directories outside the project and
verify both backups can be restored. Then run:

```bash
ddev pull typo3-deployer
```

DDEV asks for confirmation in an interactive terminal. Before importing,
the provider displays the selected host (default: `production`), effective
SSH target and release path. It imports the database, updates the schema,
clears local TYPO3 caches and then synchronizes the files.

## Usage

| Command | What it does |
| --- | --- |
| `ddev pull typo3-deployer` | Pull database and files from `production` |
| `ddev pull typo3-deployer --environment=host=staging` | Use the `staging` host from `.hosts.yml` |
| `ddev pull typo3-deployer --skip-files` | Pull only the database |
| `ddev pull typo3-deployer --skip-db` | Pull only the files |
| `ddev pull typo3-deployer --skip-files --skip-import` | Download and validate a SQL dump without importing it |

Add `-y` only to skip confirmation. Non-interactive runs may also proceed
without asking. With `--skip-import`, files are not downloaded because the
provider mirrors them directly during import.

### Select the uploaded files

Normally there is nothing to configure: TYPO3 defaults to `fileadmin` in
DDEV. To mirror additional upload directories, use DDEV's existing
`upload_dirs` setting in `.ddev/config.yaml`:

```yaml
upload_dirs:
  - fileadmin
  - uploads
  - ../private/uploads
```

Paths are relative to the document root (for example `public`). Each actual
upload directory must exist locally and at the corresponding path in the
remote release. Local files that are absent remotely are deleted. Generated
`_processed_` and `_temp_` directories are excluded, as is `node_modules`
(including DDEV entries used only for Mutagen performance).

Do not list source code or other dependency directories as uploads. The
project root, `.git`, `.ddev`, overlapping destinations and paths resolving
outside the project are rejected. See the [technical reference](docs/technical-reference.md#file-synchronization)
for path restrictions and details.

### Choose another deployment environment

Add further hosts to your existing `.hosts.yml`, for example `staging`.
Hosts on the same SSH account can share the project alias and use different
`deploy_path` values. If an environment uses another SSH account or server,
use a separate DDEV project with its own matching SSH alias.

YAML anchors and merge keys are supported. See the
[configuration reference](docs/technical-reference.md#deployer-host-settings)
for an example.

### Use a specific remote PHP version (only if needed)

By default, the provider executes `vendor/bin/typo3` directly on the remote
server. The server's CLI environment selects PHP; the local DDEV PHP version
is independent. To check the version in the same kind of SSH session used
by the provider, adapt this command to your project:

```bash
ssh -T -o RemoteCommand=none example-typo3 \
  'cd /srv/example/production/current && vendor/bin/typo3 --version'
```

If the default PHP is incompatible or you need custom PHP flags, add the
optional `bin/php` setting to the relevant host in `.hosts.yml`:

```yaml
hosts:
  production:
    hostname: deploy.example.com
    remote_user: deploy
    deploy_path: /srv/example/production
    bin/php: '/usr/bin/php8.5-cli -c {{deploy_path}}/shared/php-cli.ini'
```

Use a binary and flags that actually exist on your server. Leave this
setting out when the direct CLI invocation works. The provider does not
execute or parse `deploy.php`.

## Reading the pull output

The provider displays the selected environment, effective SSH target and remote
release path, followed by separate database export, database import and file
synchronization sections. `[..]` means
an operation has started, `[OK]` means it completed successfully and `[SKIP]`
means it was intentionally omitted. Completed transfers and database operations
show elapsed time in whole seconds; the export also shows the SQL dump size.
The provider uses plain text in both terminal sessions and automated logs.
DDEV's own messages and the original errors remain visible.

## Troubleshooting

Read the first underlying error in the output; the final `Pull failed` line
is usually just a summary.

| Problem | What to check |
| --- | --- |
| SSH authentication or connection fails | Test `ssh <DDEV-project-name>`; check your key, network and host key. |
| SSH alias does not match the selected host | Compare the effective SSH user and port (`ssh -G <alias>`) with `remote_user` and `port` in `.hosts.yml`. Different DNS names and IP spellings are allowed; keep your working `HostName` and key. |
| `.hosts.yml` is missing | Create or reuse the shared Deployer inventory as shown in [Quick start, step 3](#3-check-your-deployer-host-configuration). |
| Host or deployment path is invalid | Check the selected host and its absolute `deploy_path` in the project-root `.hosts.yml`. |
| Remote PHP version is incompatible | Run the remote CLI check above; configure `bin/php` only if needed. Exit status 255 alone does not prove an SSH error. |
| `database:export` is unavailable | Install and deploy TYPO3 Console on the remote website. Check the remote CLI and dump client. |
| `database:updateschema` is unavailable | Repair the local Composer installation and install compatible TYPO3 Console. The provider stops before replacing the database. |
| An upload directory is missing | Check DDEV's `upload_dirs` and the selected remote release. Create the correct local directory or fix the deployment. |
| `rsync` is missing | Install it on the local computer or deployment server, as indicated by the error. |
| A dump already exists | Save or remove it securely before retrying. |
| Database dump is incomplete | Check remote CLI output and the connection. The provider rejects incomplete dumps before import. |
| `rsync: mkstemp ... Illegal byte sequence (92)` | The local filesystem may reject non-UTF-8 filenames from the server. See [filename encoding errors](#filename-encoding-errors-on-macos). |
| File synchronization fails | The database may already have been replaced. Fix the cause and retry the same host with `--skip-db` if the database is still current; restore from backup if needed. |
| Import or schema/cache update fails | Check the reported phase. The local database may be incomplete or not fully prepared. Save any needed dump before retrying and restore from backup if necessary. |

Keep any needed SQL dump (`.ddev/.downloads/db.sql`) securely outside DDEV's
downloads directory before retrying. Do not commit dumps or uploads to Git.

### Filename encoding errors on macOS

If a file pull reports errors like these, read the first rsync error rather
than only the final exit status:

```text
rsync: [receiver] mkstemp ".../.Pi\#351ces.pdf.ABC123" failed: Illegal byte sequence (92)
rsync error: some files/attrs were not transferred (code 23)
```

This typically means the local filesystem cannot create a filename received
from the server, not that the add-on is broken. Linux filesystems can store
names containing legacy-encoded bytes that macOS APFS rejects because they
are not valid UTF-8. Accented characters themselves are not a problem when
properly encoded. Rsync displays some bytes using octal escapes such as
`\#351`; the escape is not necessarily part of the actual filename.

1. Identify the affected files and check their filename encoding on the
   server. Ask your hosting provider or developer for help if necessary.
   See the [read-only diagnostic example](docs/technical-reference.md#diagnosing-filename-encoding-errors).
2. Correct the filenames at their source using valid UTF-8. Back up the
   remote files and database first. For TYPO3-managed files, coordinate the
   change through the File Abstraction Layer (FAL) where possible, and verify
   file references, direct URLs and any external import process. Do not
   blindly rename files or convert the entire upload directory.
3. Once the remote files and their references are consistent, retry the pull.
   If only the file transfer failed and the imported database still matches
   the remote data, you can retry only the files:

   ```bash
   ddev pull typo3-deployer --skip-db
   ```

   If fixing the filenames changed remote database records or references,
   run a full pull instead. Keep the same selected deployment host.

Exit code 23 is a general partial-transfer error, not proof of an encoding
problem. Repeated `Illegal byte sequence` diagnostics are grouped: the pull
shows their total count and up to three compact examples, with local path
prefixes removed where possible. These may be rsync temporary filenames,
not the original names. Other rsync errors remain visible. Whenever filename
diagnostics are summarized, the complete stderr log is retained in a private
temporary file and its path is displayed. It may contain sensitive filenames;
delete it when no longer needed. The failure summary shows the elapsed time,
exit status, completed upload directories and a retry command for the same
host. It does not claim that a database was imported, as the database step
may have been skipped. This changes only the reporting, not the transfer or
its exit status.

A failed transfer can leave the local files partly synchronized.
The add-on deliberately does not guess the encoding, rename files, silently
skip rejected files or report an incomplete transfer as successful.

## Why TYPO3 Console?

TYPO3 Console makes the database pull possible **without separately
configuring database credentials**. It uses the connection already resolved
by the remote TYPO3 installation, whether configured through PHP files or
environment variables. The provider does not read or transfer those
credentials itself.

- [`database:export`](https://docs.typo3.org/p/helhum/typo3-console/main/en-us/CommandReference/DatabaseExport.html)
  exports the `Default` connection and allows volatile tables such as caches
  and sessions to be excluded.
- [`database:updateschema safe`](https://docs.typo3.org/p/helhum/typo3-console/main/en-us/CommandReference/DatabaseUpdateschema.html)
  aligns the imported database with the local code using add/change schema
  operations, without explicit rename/drop operations.

TYPO3 Core's `impexp:export` is not a full SQL dump. Its `extension:setup`
command performs additional initialization beyond the schema update. The
provider deliberately avoids those side effects, and uses the native
`cache:flush` command to clear local caches after the schema update.

## Security and limitations

- A pull is not atomic. A successful database import can be followed by a
  failed file transfer. Backups remain your responsibility.
- Restrict access to local copies and backups of production data.
- Only the `Default` database connection is exported. Upgrade wizards and
  extension initialization are not run automatically.
- Avoid pulling during a deployment that changes the `current` release.
- DDEV's preflight does not receive skip flags, so local rsync and valid
  configured upload destinations are required even for database-only pulls.

See the [technical reference](docs/technical-reference.md) for details.

## Update or uninstall

```bash
ddev add-on get ErHaWeb/ddev-typo3-deployer-pull
ddev restart
```

Use `ddev add-on update` for installed add-ons, or `--version <tag>`
with `ddev add-on get` for a specific release. To uninstall:

```bash
ddev add-on remove typo3-deployer-pull
```

Commit the installed add-on files and manifest to share the setup with your
team. DDEV manages files marked `#ddev-generated`; see the
[technical reference](docs/technical-reference.md#installed-files-and-customization)
if you need to customize them.

## Platform support and development

Previous versions were tested on Apple Silicon macOS with OrbStack, DDEV
1.25.0 and 1.25.6, GNU rsync and macOS openrsync. Linux and WSL2 are expected
to work; native Windows with Git Bash usually lacks rsync and is unverified.

Run `bash tests/smoke.sh` for an isolated test without live server access.
See [test details](docs/technical-reference.md#smoke-tests).

## License

Created by [Eric Harrer](https://github.com/ErHaWeb). Licensed under the
[GNU General Public License](LICENSE.txt), version 2 or later
(`GPL-2.0-or-later`). Keep the license and copyright notices with copies.
The warranty disclaimer and limitation of liability apply to the extent
permitted by applicable law. Mandatory liability remains unaffected.
