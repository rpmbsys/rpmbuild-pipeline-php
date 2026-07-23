# rpmbuild-pipeline-php

Dependency-ordered rebuild orchestrator for the `rpmbsys` **php-pear + PECL
extension** family. It does not build anything itself — it dispatches each
package repo's `build.yaml` in the correct order and waits for each to finish
before starting its dependents.

## Why

The extension repos build `FROM` each other's published base images
(`aursu/pearbuild:*`, `aursu/peclbuild:*-php-<x>-8.N`). If a downstream repo
builds before its base has been (re)published, it fails at `docker pull` — not
on its own code. This is acute after an OS bump, when the whole family must be
rebuilt in order. This repo gives that a single button.

## Build DAG

Verified from each repo's `Dockerfile` `FROM` and its `docker-compose.php*.yml`
base selector:

```
pear                                        publishes aursu/pearbuild:<os>-php-8.N
 ├─ apcu ── igbinary ── msgpack ──┬─ memcached
 │  (spine; base publishers)      └─ redis6
 ├─ geoip                                   leaves off pear (FROM pearbuild),
 ├─ amqp                                    run in parallel, block nothing
 ├─ imagick
 ├─ pcov
 ├─ xdebug
 └─ ssh2
```

- `apcu` publishes `peclbuild:<os>-php-apcu-8.N`; `igbinary` and `msgpack` both
  RPM-build on that base, so both come after `apcu`.
- `msgpack`'s base-publisher builds on `igbinary`'s base → `igbinary` before
  `msgpack`.
- `memcached` and `redis6` build on `msgpack`'s base.

`rpmbuild-php-8.{2..5}` (the PHP-minor RPMs) are upstream of `pear` and are not
driven here — they must already have published `aursu/php8Nbuild:<os>-build`.

## Setup (one-time)

1. **GitHub App** `rpmbsys-ci-orchestrator` (org → Developer settings → GitHub
   Apps), permissions **Actions: Read and write**, **Contents: Read-only**,
   **Metadata: Read-only**; installed on this repo + all 12 target repos.
   These exact permissions are load-bearing — all triggers use `workflow_dispatch`
   (Actions:write), never `repository_dispatch` (which needs Contents:write). See
   [`docs/permissions.md`](docs/permissions.md).
2. **Org secrets/variables** (rpmbsys → Settings → Secrets and variables →
   Actions), scoped to this repo:
   - variable `CI_APP_ID` — the App's numeric ID
   - secret `CI_APP_PRIVATE_KEY` — the App private key (`.pem` contents)
3. **Each target repo's `build.yaml`** must be dispatchable — add to its `on:`:
   ```yaml
   on:
     push:
     workflow_dispatch:
   ```

> Prefer a fine-grained PAT over the App? Store it as secret
> `CI_DISPATCH_TOKEN` and, in `dispatch-and-wait.yml`, drop the token-minting
> step and set `GH_TOKEN: ${{ secrets.CI_DISPATCH_TOKEN }}`.

## Two pipelines

### A. Per-PHP-version pipeline (`php-8.5.yml` → `rebuild-php.yml`)

For a single PHP minor: rebuild only the extensions the runtime/dev images
install (apcu, geoip, memcached, redis6, imagick) plus the build-spine they need
(pear, igbinary, msgpack), then build that PHP repo's runtime + dev images.

```
rpmbuild-php-8.5 build.yaml (push)         pipeline-php                 rpmbuild-php-8.5
  test + build ──php85-base-ready──▶ php-8.5.yml → rebuild-php.yml
  (RPMs + base image)                  pear→apcu→igbinary→msgpack→{memcached,redis6}
                                       + geoip, imagick
                                          └─ all uploaded ──▶ dispatch images.yaml ──▶ runtime→dev
```

- **Auto:** push to `rpmbuild-php-8.5` master → its `notify` job fires
  `php85-base-ready` here.
- **Manual:** Actions → *PHP 8.5 pipeline* → Run (`ref`, default `master`).

Extensions `amqp/pcov/xdebug/ssh2` are **excluded** (not in the runtime image).
See `docs/php-build-pipeline-architecture.md` in the crytek-platform repo.

### B. All-versions family rebuild (`rebuild-family.yml`)

Blanket rebuild of all 12 extensions across all PHP minors (e.g. after an
OS bump). Actions → *Rebuild PECL/PEAR family (ordered)* → Run (`ref`).

## Files

- `.github/workflows/php-8.5.yml` — 8.5 entry (wrapper over `rebuild-php.yml`).
- `.github/workflows/rebuild-php.yml` — reusable per-version DAG (8 repos +
  the `images` dispatch back to the PHP repo). One wrapper per minor.
- `.github/workflows/rebuild-family.yml` — all-versions, all-12 DAG.
- `.github/workflows/dispatch-and-wait.yml` — reusable wrapper: checkout, mint
  the App token, then run the script below (optional `php` selector).
- `.github/scripts/dispatch-and-wait.sh` — dispatch one repo's workflow and
  block on its conclusion (`gh run watch --exit-status`). Standalone:
  `GH_TOKEN=… .github/scripts/dispatch-and-wait.sh <org> <repo> <ref> [workflow] [php]`.
  Detailed walkthrough + known sharp edges: [`docs/dispatch-and-wait.md`](docs/dispatch-and-wait.md).

Per-version prerequisites (beyond the family setup above): the App must also be
installed on the PHP repos, and `CI_APP_ID`/`CI_APP_PRIVATE_KEY` readable by
them (the PHP repo's `notify` job mints a token to dispatch this repo). Each
in-scope extension `build.yaml` carries a `php` input + `.github/scripts/php-matrix.py`.
