# Vulnerability Database Sync

The OSV Loader (`osvdev-job`) is a Kubernetes CronJob that continuously synchronizes vulnerability intelligence from [osv.dev](https://osv.dev) into the Ortelius evidence store. It is the foundation of Ortelius' post-deployment security model — without it, no CVE matching occurs against your deployed components.

## What It Does

On each run the loader fetches the full list of ecosystems published by osv.dev, then for each ecosystem downloads and processes the vulnerability feed. For every new or updated entry it:

1. Normalizes the vulnerability record — package names, version ranges, CVE/GHSA alias mappings, and CVSS scores
2. Upserts the record into ArangoDB, skipping entries whose modification timestamp has not changed since the last run
3. Builds `cve2purl` hub edges linking each CVE to the package PURLs it affects. `SEMVER` ranges carry parsed major/minor/patch metadata for fast query-time matching. `ECOSYSTEM` ranges (PyPI, Maven, NuGet, RubyGems, Debian, …) use the ecosystem's own version ordering, which is not semver, so their edge carries no numeric parts and every candidate version is validated with the ecosystem-aware `util.IsVersionAffected` (which also honours the advisory's explicit `versions` list). `GIT`-type ranges (commit-SHA based, common for C/C++ advisories) are used for PURL resolution but skipped for edge creation, since commit SHAs can't be compared as versions
4. Rebuilds `release2cve` materialized edges — connecting any existing release records whose SBOM packages fall within the affected version ranges
5. Updates lifecycle tracking records for all active endpoints, recording whether each CVE was disclosed before or after the software was deployed

## How It Fits Into Ortelius

Ortelius correlates the packages listed in your release SBOMs against the vulnerability intelligence ingested by this job. When a new CVE is disclosed against a package you have deployed, Ortelius detects it within the next sync cycle and surfaces it on your dashboard with MTTR tracking, SLA status, and blast-radius analysis across all affected endpoints.

CVE data is refreshed from OSV.dev every 15 minutes by default. The loader uses a high-water-mark per ecosystem so only genuinely new or updated vulnerability records are processed on each run, keeping execution fast even as the OSV dataset grows.

## Supported Ecosystems

All ecosystems published in the OSV ecosystem index are processed automatically, including npm, PyPI, Maven, Go, NuGet, RubyGems, cargo (crates.io), Composer, apk (Alpine/Wolfi), and deb (Debian/Ubuntu). No configuration is required to add a new ecosystem — if OSV publishes it, the loader will pick it up.

## Schedule

The CronJob runs every 15 minutes by default (`*/15 * * * *`) with `concurrencyPolicy: Forbid` to prevent overlapping runs. For regulated or mission-critical environments a tighter interval such as every 6 hours is recommended to minimise exposure window between OSV disclosure and detection in Ortelius.

## State Persistence

The loader tracks the last processed modification timestamp per ecosystem in ArangoDB. This prevents redundant reprocessing and ensures that lifecycle and edge updates are triggered only for genuinely new vulnerability disclosures.

High-water-mark records are stored in the shared `metadata` collection (one document per ecosystem, keyed by ecosystem name, e.g. `npm`, `pypi`) — the same collection the main Ortelius backend exposes generically via `GET/PUT /api/v1/metadata/:key`. Avoid writing to a key that matches an OSV ecosystem name through that API, as it will overwrite this job's high-water mark and force a full reprocess of that ecosystem's feed on the next run.

## Lazy Edges (`LAZY_CVE_EDGES`)

By default the loader writes a `purl` node and a `cve2purl` edge for every package of every advisory, which for container-distro feeds means millions of edges for packages no release contains. With `LAZY_CVE_EDGES=true` it only writes them for packages an SBOM already references (a `purl` node with an `sbom2purl` edge pointing at it). It uses the existing node found by its unique `purl`, and never creates package nodes. A package that is referenced for the first time later gets its edges from the backend (`sbom.EnsureCVEEdgesForPurls`, also `LAZY_CVE_EDGES`).

Both modes store the normalized base purl of each affected entry on the CVE document as `affected[].base_purl`; the backend finds a package's CVEs through an index on it. The CVE document is always written before any edge, which together with the backend's ordering (package and `sbom2purl` edge first, then the CVE lookup) means a CVE is never missed whichever side runs second. The loader skips records whose OSV `modified` time is unchanged, so CVEs ingested before this change do not get `base_purl` until they are repaired (`repair --backfill-base-purls`).

## Data Integrity Repair

After every ingestion run, the job performs a targeted repair pass (`RunRepair`, in `repair.go`) for dangling graph edges — `cve2purl` or `release2cve` edges left pointing at a `purl` or `cve` document that no longer exists (e.g. after manual cleanup or a partial failure elsewhere). It only touches the specific subset of edges currently broken, reusing the same `processEdges`/`newVuln` logic as normal ingestion, so it's safe and cheap to run on every execution — once something is fixed, the detection scan simply stops finding it.

This is configurable via environment variables:

| Variable                          | Default | Description                                                                 |
|------------------------------------|---------|-------------------------------------------------------------------------------|
| `ARANGO_REPAIR_ENABLED`            | `true`  | Set to `false` to skip the repair pass entirely for a run                    |
| `ARANGO_REPAIR_QUERY_MEMORY_LIMIT_MB` | `512`   | Caps memory used by each detection scan; set to `0` to remove the cap        |

## Configuration

The job connects to ArangoDB using the same `ARANGO_HOST` / `ARANGO_PORT` / `ARANGO_USER` / `ARANGO_PASS` environment variables as the main Ortelius backend (see the [backend architecture guide](https://github.com/ortelius/ortelius/blob/main/docs/architecture.md#environment-variables-reference)). The bundled Helm chart also sets a `MITRE_MAPPING_URL` environment variable, but it is not currently read anywhere in this job's code — treat it as unused/reserved rather than a functioning setting.