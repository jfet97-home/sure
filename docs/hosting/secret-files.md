# Secret files

Sure accepts these deployment inputs either directly from the environment or
from a file named by the corresponding environment variable:

| Existing variable | File variable |
| --- | --- |
| `SECRET_KEY_BASE` | `SECRET_KEY_BASE_FILE` |
| `POSTGRES_PASSWORD` | `POSTGRES_PASSWORD_FILE` |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY_FILE` |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY_FILE` |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT_FILE` |

Existing environment-based installations keep their current behavior. Set only
one source for each input: even an empty direct variable conflicts with its file
variable. `POSTGRES_PASSWORD_FILE` also conflicts with `DATABASE_URL`, which can
override Rails' database password. `SECRET_KEY_BASE_FILE` conflicts with
`SECRET_KEY_BASE_DUMMY`. The existing encryption configuration rules still apply:
provide all three explicit encryption keys together, using either input form.
Explicit keys retain their existing priority over Rails credentials.

Files must have absolute paths, be readable regular files, and contain nonblank
UTF-8 text without NUL bytes, at most 64 KiB. Invalid configuration aborts startup;
there is no fallback to a generated key or another source when a file fails.
Errors identify the setting without including file paths, contents or underlying
filesystem errors. Protect the file and its parent directories against other
container users and unauthorized changes.

Contents are used exactly as stored. Sure does not trim whitespace, remove a
trailing newline, parse shell syntax or expand variables. Avoid adding a newline
when preparing a file unless it belongs to the existing value. When switching an
installation, preserve the exact application key, database password and encryption
keys. This changes delivery only: it neither rotates credentials nor migrates
stored encrypted data. Retain the same keys for recovery.

## Boot and process behavior

Sure loads these files inside its Rails application configuration, immediately
after dotenv's `before_configuration` hook. The values are available before
environment configuration, database YAML evaluation, session key initialization
and the existing explicit Active Record encryption initializer. This covers
Rails commands, web startup and Sidekiq without changing the Docker entrypoint:
the web entrypoint still runs `db:prepare`, then executes its normal command.

Docker's recorded container environment contains the configured paths rather
than these input values. Rails necessarily holds the values in its own process
environment and memory after loading; this is not protection against Rails,
host root or Docker administrators. Keep private inputs outside the source tree
and build context. Runtime secrets must not be supplied as build arguments.

## Docker Compose

Compose can supply a file-backed secret or a secret sourced from the existing
host environment. This example shows one input; grant the other four to the web
and worker in the same way:

```yaml
services:
  web:
    environment:
      SECRET_KEY_BASE_FILE: /rails/.secrets/secret_key_base
    secrets:
      - source: secret_key_base
        target: /rails/.secrets/secret_key_base
  worker:
    environment:
      SECRET_KEY_BASE_FILE: /rails/.secrets/secret_key_base
    secrets:
      - source: secret_key_base
        target: /rails/.secrets/secret_key_base

secrets:
  secret_key_base:
    environment: SECRET_KEY_BASE
```

With Sure's image, `/rails` is owned by UID/GID 1000 with mode `0750`. Mounting
application inputs below this directory preserves the boundary against the
Fineco browser's UID/GID 1001 even when Compose supplies root-owned `0444` files.
Verify actual ownership, permissions and read access under both UIDs after
deployment. Do not rely on declared `uid`, `gid` or `mode`: enforcement depends
on Compose and secret source, and file-backed mounts retain host permissions.
See [Docker's secret reference](https://docs.docker.com/reference/compose-file/services/#secrets).

PostgreSQL is a separate consumer. Give its service only the database password
secret and configure the official image's native `POSTGRES_PASSWORD_FILE`, for
example `/run/secrets/postgres_password`. This does not configure Rails; the web
and worker need their own `POSTGRES_PASSWORD_FILE` and grants. PostgreSQL's
entrypoint follows its own file-reading rules. Keep the initialized database
volume and password unchanged when changing delivery.
