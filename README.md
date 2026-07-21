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

## Usage

- **Manual full rebuild:** Actions → *Rebuild PECL/PEAR family (ordered)* →
  Run workflow → set `ref` (default `master`).
- **Auto-trigger** from `rpmbuild-php-8.N` after it republishes its base:
  ```
  gh api repos/rpmbsys/rpmbuild-pipeline-php/dispatches \
     -f event_type=php-base-updated
  ```

## Files

- `.github/workflows/rebuild-family.yml` — the DAG (one job per repo, `needs:`).
- `.github/workflows/dispatch-and-wait.yml` — reusable wrapper: checkout, mint
  the App token, then run the script below.
- `.github/scripts/dispatch-and-wait.sh` — dispatch one repo's build and block
  on its conclusion (`gh run watch --exit-status`). Standalone:
  `GH_TOKEN=… .github/scripts/dispatch-and-wait.sh <org> <repo> <ref> [workflow]`.
