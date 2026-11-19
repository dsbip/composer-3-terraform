# Composer 3 hibernation — shut down non-production environments out of hours

Cloud Composer 3 has no "stop" button: an environment bills for its scheduler,
web server, workers and database for as long as it exists. This feature deletes
non-production environments outside working hours and brings them back in the
morning **with their Airflow state intact**:

```
 19:00 (GitLab schedule)                              07:00 (GitLab schedule)
 composer-shutdown.sh                                 composer-startup.sh
 ───────────────────                                  ──────────────────
 1. guard-rails (enabled? non-prod? restorable?)      1. guard-rails, read state file
 2. snapshot  → gs://<snapshot bucket>/…  ──────────▶ 2. terraform apply (targeted) from the SAME YAML
 3. verify snapshot (Airflow DB dump present)         3. load snapshot (Airflow DB + dags/plugins/data)
 4. terraform destroy (targeted: Composer env only)   4. state file → ACTIVE
 5. state file → HIBERNATED, housekeeping
```

The environment is recreated by Terraform from the **same YAML file the module
already consumes**, so the morning environment is exactly what the YAML says —
network, service account, workloads, PyPI packages, Airflow overrides and
environment variables included. The snapshot only restores what Terraform
cannot: the Airflow metadata database (DAG runs, task history, variables,
connections, pools, XComs, users) and the `dags/`, `plugins/` and `data/`
folders.

Only the `google_composer_environment` resource is deleted. The VPC, subnet,
NAT, firewall rules, service account, IAM bindings and KMS keys stay, so
nothing else is recreated and the KMS `prevent_destroy` lifecycle is never hit.

---

## 1. Enable it in the YAML

Hibernation is **opt-in per environment** and is refused for production
environments. Settings resolve like every other setting of the module:
per-environment value → global value → default.

```yaml
project_id: "my-dev-project"

hibernation:                     # global defaults for every environment
  enabled: false

environments:
  composer-dev:
    labels: { env: dev }
    hibernation:
      enabled: true              # this one sleeps at night

  composer-prod:
    labels: { env: production }  # hibernation can never be enabled here
```

`configs/hibernation.yaml` is a fully commented example; `configs/development.yaml`
and `configs/multi-environment.yaml` show it in context.

### All settings

| Setting | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Take part in hibernation. |
| `snapshot_bucket` | `<project_id>-composer-snapshots` | Bucket for snapshots and the state file. Created by the scripts if missing (uniform bucket-level access, public access prevention). One bucket can serve many environments. Must differ from `storage.bucket`. |
| `snapshot_bucket_location` | environment region | Location used when the bucket is created. |
| `create_snapshot_bucket` | `true` | `false` = the bucket must already exist. |
| `snapshot_prefix` | `composer-hibernation` | Folder inside the bucket. Snapshots live in `<prefix>/<project>/<region>/<environment-name>/`. |
| `snapshot_retention_count` | `7` | Snapshots kept per environment. The current restore point is never pruned. |
| `pin_image_version` | `true` | When the YAML has no `software_config.image_version`, recreate on the Airflow version the snapshot was taken on (`composer-3-airflow-X.Y.Z`, newest build). Snapshots can only be loaded into the same or a later Airflow version. |
| `delete_orphaned_bucket` | `true` | Deleting an environment leaves its auto-created bucket behind and the restore creates a new one. When `true`, the old bucket is deleted after the grace period below. Buckets set with `storage.bucket` are never deleted. |
| `orphaned_bucket_retention_days` | `7` | Grace period before an orphaned bucket (and the task logs in it) is deleted. `0` = right after the shutdown. |
| `load_options.skip_pypi_packages_installation` | `true` | Terraform already installed the YAML's PyPI packages. |
| `load_options.skip_environment_variables_setting` | `true` | Terraform already set the YAML's environment variables. |
| `load_options.skip_airflow_overrides_setting` | `true` | Terraform already set the YAML's Airflow overrides. |
| `load_options.skip_gcs_data_copying` | `false` | `true` = do not restore `dags/`, `plugins/`, `data/` (e.g. when a DAG deploy pipeline always runs after startup). |

The three `skip_*: true` defaults keep the YAML the single source of truth (no
Terraform drift after a restore) and avoid the slow PyPI re-installation.

Invalid values (wrong types, unknown keys, retention < 1, bad bucket names,
hibernation on a production environment, …) fail `terraform plan` through a
precondition on the Composer resource and stop the scripts before they act.

### Production detection

An environment is production when any of its (merged) labels `env`,
`environment`, `tier` or `stage` is `prod`, `production` or `prd`. If none of
those labels is set, its name is checked for a `prod` / `production` / `prd`
token (`composer-prod`, `prod-composer`; but not `composer-preprod` or
`composer-product`). Explicit labels always win: `composer-prod-replica` with
`env: test` is not production.

### Recommended: a persistent custom bucket

Every recreated environment normally gets a new, randomly named bucket. Google
explicitly recommends a [custom bucket](https://cloud.google.com/composer/docs/composer-3/custom-bucket)
for environments that are deleted and re-created regularly:

```yaml
  composer-dev:
    storage:
      bucket: "my-dev-project-composer-dev"   # same region, Standard class, no retention policy
```

The bucket (and therefore `dag_gcs_prefix`, task logs and anything your DAG
deploy pipeline points at) then survives every cycle and nothing is orphaned.
The environment's service account needs object admin on it.

### Pin the image version

Pin `software_config.image_version` to an alias such as
`composer-3-airflow-2.10.5` (newest build of that Airflow version) for
hibernating environments. With `image_version: null` the first creation uses
whatever GCP considers the default, and Google is still rolling out the switch
of that default from Composer 2 to Composer 3. Builds can be used to create
environments for 12–18 months after release: a version that is fine for a
running environment can become impossible to *re-create* — the shutdown script
checks this before deleting anything (see below).

---

## 2. What protects your environments

Nothing is deleted unless **all** of these hold:

1. `hibernation.enabled: true` and the configuration is valid.
2. The environment is not production (labels/name — and a Terraform precondition).
3. The environment is `RUNNING` (transitional states are waited out; `ERROR`
   environments are refused unless `--force-delete-without-snapshot`).
4. Its `google_composer_environment` is in **this** Terraform state (protects
   against a wrong backend/state).
5. It can be restored tomorrow: the restore image version (YAML's, or the
   pinned current Airflow version) can still be used to **create**
   environments (checked against the Composer `imageVersions` API, fail-closed)
   and is not older than the running Airflow version.
6. The snapshot operation finished without error, returned its `snapshotPath`,
   and the snapshot folder contains the Airflow database dump (`*.sql.gz`).
7. The snapshot is recorded in the state file.
8. The Terraform destroy plan contains **only** deletions of the selected
   Composer environments, and each of them (a mistyped target silently plans
   nothing in Terraform).

On startup the Terraform plan may only create/update resources inside the
selected environments' module instances (`module.composer["<key>"]`); a
replacement is accepted only for an environment that is in `ERROR` during a
restore. The whole module instance is targeted on purpose: a resource-level
`-target` also pulls in the same-named dependencies of every *other*
environment, so a pending change elsewhere — even in production — would leak
into the plan (verified with real Terraform; see
`tests/hibernation/fixtures/plans/create-resource-target-leak.json`).
Snapshots are loaded only into the same or a later Airflow version.

GitLab adds: one `resource_group` shared by shutdown, startup and `dev-apply`
(never two at once), `interruptible: false`, and `auto_cancel: none` for
scheduled/manual pipelines so a merge cannot cancel a running shutdown.

---

## 3. The state file

Each environment has `<snapshot_location>/hibernation-state.json`:

| Status | Meaning | Next startup |
|---|---|---|
| `SNAPSHOT_SAVED` | Snapshot taken; deletion not (yet) confirmed. | Restores it if the environment is gone, otherwise nothing. |
| `HIBERNATED` | Environment deleted; `latest_snapshot` is the restore point. | Recreate + load. |
| `RESTORING` | A startup is in progress or was interrupted. | Resumes: creates if missing, replaces if `ERROR`, loads. |
| `ACTIVE` | Running with the snapshot restored. | Nothing. |

It also records every snapshot (path, time, image/Airflow version, service
account, environment bucket), orphaned buckets awaiting deletion, the last
restore, and a bounded history with the GitLab pipeline/job of each change.

Both scripts are idempotent and decide what to do from the live environment
state plus this file, so any job can simply be re-run:

* shutdown failed before deleting → the environment keeps running; the next
  run takes a fresh snapshot;
* shutdown deleted the environment but failed afterwards → the next run marks
  it `HIBERNATED`;
* startup failed while creating or loading → state stays `RESTORING`; the next
  run creates/replaces as needed and loads (Composer resumes partial loads);
* a shutdown while a restore is incomplete never replaces the last good
  restore point with a snapshot of an empty environment;
* someone ran the normal deploy pipeline at night (fresh, empty environment) →
  startup still loads the snapshot into it.

---

## 4. GitLab setup

Files:

| File | Purpose |
|---|---|
| `.gitlab-ci.yml` | Stages, workflow rules (schedules/web/MR/branch), checks and tests. |
| `pipelines/dev.yml` | `dev-plan` / `dev-apply` — same structure as your existing `pipelines/dev.yml` (variables, `.id_tokens`, WIF cred-config, GCS backend, plan artifacts + terraform report). |
| `pipelines/composer-hibernation.yml` | `dev-composer-shutdown`, `dev-composer-startup`, `dev-composer-hibernation-dry-run`. |
| `scripts/ci/ensure-tools.sh` | Installs terraform (SHA-256 verified) / jq only if the image lacks them. |
| `scripts/ci/create-hibernation-schedules.sh` | Creates/updates the two schedules through the GitLab API (idempotent). |

### 4.1 Variables

In `pipelines/dev.yml` replace `DEV_PROJECT_ID`, `DEV_BUCKET` (Terraform state
bucket), `DEV_BUCKET_PREFIX` and `DEV_CONFIG_FILE`. As in your other pipelines,
set the CI/CD variables `GCP_DEV_WIF_PROVIDER` and `GCP_DEV_WIF_SERVICE_ACCOUNT`.
`id_tokens.aud` defaults to `${CI_SERVER_URL}`; use whatever audience your WIF
provider allows. Set `CI_IMAGE` (CI/CD variable) to your usual runner image.

The OIDC token and credential file are written under `.wif/` with **absolute**
paths, so Terraform and gcloud work from any directory (no need to copy the
token next to the Terraform code), and are removed in `after_script`.

### 4.2 Permissions of the CI service account

On top of what `dev-apply` already needs:

* `roles/composer.admin` — describe, snapshot save/load, delete, create, operations;
* `roles/iam.serviceAccountUser` on the environments' service accounts;
* on the snapshot bucket (or the project): create bucket, set its IAM policy,
  read/write/delete objects — e.g. `roles/storage.admin` on the bucket;
* delete on the environment buckets if `delete_orphaned_bucket` is on.

The **environment's** service account performs the snapshot I/O; the scripts
grant it `roles/storage.objectAdmin` on the snapshot bucket. Snapshots contain
the environment's fernet key, so keep the snapshot bucket private to the CI
identity and the environment service accounts.

### 4.3 Schedules

Create two pipeline schedules on the protected default branch (CI/CD →
Schedules), owned by a long-lived service user (a schedule whose owner leaves
becomes inactive):

| Description | Cron | Timezone | Variable |
|---|---|---|---|
| `Composer hibernation: shutdown` | `0 19 * * 1-5` | `Europe/London` | `HIBERNATE_ACTION=shutdown` |
| `Composer hibernation: startup` | `0 7 * * 1-5` | `Europe/London` | `HIBERNATE_ACTION=startup` |

Mon–Fri covers weekends: Friday's shutdown is followed by Monday's startup.
Or let the helper do it:

```bash
GITLAB_API_URL=https://gitlab.example.com/api/v4 GITLAB_TOKEN=<api token> \
PROJECT_ID=group/composer-3-terraform REF=main TIMEZONE=Europe/London \
  scripts/ci/create-hibernation-schedules.sh --set-resource-group-mode
```

Notes from GitLab's behaviour:

* Schedules fire when GitLab's scheduler worker runs (every 5–10 minutes,
  later on busy instances). Startup takes ~25 min (create) + snapshot load;
  start early enough before working hours.
* Optional schedule variable `HIBERNATE_ENVIRONMENTS=composer-dev,composer-qa`
  restricts a schedule to some environments — e.g. different hours per team
  (create more schedules).
* Setting schedule variables requires the project's "minimum role to use
  pipeline variables" (Maintainer by default).
* Set the resource group to `oldest_first` once it exists (after the first
  run), so a delayed shutdown can never be overtaken by the next startup:
  `PUT /projects/:id/resource_groups/composer-hibernation-dev?process_mode=oldest_first`
  (the helper's `--set-resource-group-mode` does it).
* The runner's maximum job timeout must allow the jobs' `timeout: 3h`.

Scheduled pipelines run **only** the matching hibernation job; plan/apply/test
jobs are excluded (`tests/ci/test_pipeline_rules.sh` proves this for every
pipeline source).

### 4.4 Manual runs

*Build → Pipelines → Run pipeline*:

* `HIBERNATE_ACTION=shutdown` / `startup` — runs that job immediately;
* `HIBERNATE_ACTION=dry-run` — read-only rehearsal (plans, no changes);
* no variable — the normal pipeline plus manual buttons for all three.

Job artifacts (`.hibernation/`, 30 days) contain the resolved settings, every
Terraform plan (`.tfplan`, `.txt`, `.json`), per-environment logs, copies of
the state files and `summary.json`.

---

## 5. Running the scripts directly

```bash
# authenticated gcloud + Terraform credentials, then:
export TF_BACKEND_BUCKET=my-tfstate-bucket TF_BACKEND_PREFIX=composer-3-state
scripts/hibernation/composer-shutdown.sh --config configs/development.yaml --dry-run
scripts/hibernation/composer-shutdown.sh --config configs/development.yaml
scripts/hibernation/composer-startup.sh  --config configs/development.yaml --env composer-dev
```

| Option | |
|---|---|
| `-c, --config FILE` | The module's YAML (or `HIBERNATE_CONFIG_FILE`). |
| `-e, --env KEY[,KEY]` | Only these environments (or `HIBERNATE_ENVIRONMENTS`). Default: all with `hibernation.enabled: true`. |
| `-n, --dry-run` | Inspect and plan only. |
| `--var-file FILE` | Extra `-var-file` for Terraform (repeatable). |
| `--skip-init` | Terraform is already initialised. |
| `--work-dir DIR` | Where logs/plans/summary go. |
| `--force-delete-without-snapshot` | shutdown: delete `ERROR` environments (restore uses the previous snapshot). |
| `--allow-initial-create` | startup: allow creating an environment Terraform has never deployed. |
| `--skip-load` | startup: recreate without loading the snapshot. |

| Environment variable | Default | |
|---|---|---|
| `TF_ROOT` | repository root | Terraform root module. |
| `TF_MODULE_ADDRESS` | `module.composer` | Address of the module call (if you wrap this module differently). |
| `TF_BACKEND_BUCKET` / `TF_BACKEND_PREFIX` | — | GCS backend; a git-ignored `backend_override.tf` is generated when the root declares no backend, and init is verified to have selected `gcs`. |
| `TF_LOCK_TIMEOUT` | `20m` | |
| `HIBERNATE_OPERATION_TIMEOUT_MINUTES` | `90` | Snapshot save/load timeout. |
| `HIBERNATE_WAIT_TIMEOUT_MINUTES` | `60` | Waiting for `CREATING`/`UPDATING`/`DELETING`. |
| `HIBERNATE_POLL_SECONDS` | `30` | Also the log heartbeat interval. |
| `HIBERNATE_MAX_PARALLEL` | `4` | Concurrent snapshot/load operations. |
| `HIBERNATE_LOAD_ATTEMPTS` | `2` | A retried load resumes a partial one. |
| `HIBERNATE_SKIP_IMAGE_CHECK` | `false` | Skip the "can it be re-created?" check. |

Exit codes: `0` success or nothing to do, `1` at least one environment failed
(the others are still processed), `2` usage/configuration error.

Requirements: bash 4.3+, terraform ≥ 1.6, gcloud, jq, curl, coreutils.

---

## 6. Things to know

* **Catch-up runs.** The restored database is as of the evening snapshot. DAGs
  with `catchup=True` create runs for every interval missed overnight; with
  `catchup=False` only the latest interval runs once. Consider
  `scheduler-catchup_by_default: "False"` in `airflow_config_overrides` for
  hibernating environments. Tasks running at shutdown time are interrupted.
* **DAG deployment.** The load copies the snapshot's `dags/` into the new
  bucket. If a separate DAG-deploy pipeline exists, run it after startup (or
  set `load_options.skip_gcs_data_copying: true` and always deploy after startup).
* **Not in a snapshot:** task logs in the bucket (`logs/` — Cloud Logging still
  has them, and the orphaned bucket is kept for the grace period), Secret
  Manager secrets (unaffected), Composer user-workloads Secrets/ConfigMaps.
* **Regular deploys while hibernated** (`dev-apply` at night) recreate the
  environment without data; the next startup detects this and loads the
  snapshot into it.
* **Snapshot limits:** Airflow database < 20 GB, < 100,000 objects in
  `dags/`+`plugins/`+`data/`. Use `data_retention` to keep the database small.
* **Outputs while hibernated:** `terraform output` keeps stale values for a
  deleted environment (`airflow_uri`, `gcs_bucket`, …) until the next full apply.
* **Composer "development mode"** environments have native hibernate/resume
  for some Airflow versions, but cannot be created by the Terraform provider and
  have tight limits — this snapshot-based approach works for any Composer 3
  environment the module creates.
* **Holidays:** deactivate the startup schedule (or remove the environment from
  `HIBERNATE_ENVIRONMENTS`) for days nobody works.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `not deleting: image version … can no longer be used to create environments` | The version would fail to re-create tomorrow. Set `software_config.image_version` to a supported version with the same or a later Airflow version, apply, then hibernate. |
| `restore image … could not load a snapshot of the running …` | The YAML pins an older Airflow version than the environment runs. Align the YAML. |
| `… is not in the Terraform state (wrong backend/state?)` | Check `TF_BACKEND_BUCKET`/`TF_BACKEND_PREFIX` and `TF_MODULE_ADDRESS`. |
| `no resources of module.composer["…"] in the Terraform state` (startup) | Same; or a brand-new environment → `--allow-initial-create`. |
| `plan guard: …` | The plan wanted to change something outside the hibernating environments (pending YAML changes, drift). Apply them through the normal pipeline first. |
| `environment is in ERROR state` (shutdown) | Fix it, or `--force-delete-without-snapshot` (restores the previous snapshot). |
| startup: `only load into the same or a later Airflow version` | The recreated environment runs an older Airflow version than the snapshot; fix `image_version` and re-run startup (state stays `RESTORING`). |
| `PERMISSION_DENIED` on snapshot save/load | The environment's service account lacks access to the snapshot bucket (the scripts grant it; check org policies / custom bucket IAM). |
| Job killed after 1 h | Raise the runner's maximum timeout (jobs need up to 3 h). |

---

## 8. Tests

```bash
tests/hibernation/run.sh      # everything below
terraform test                # module/root tests incl. hibernation settings & guard-rail preconditions
```

* `tests/hibernation/e2e.bats` — runs the real scripts end to end. Terraform is
  the **real binary** producing real plans of a converged state (offline: the
  only API it needs, `data.google_project`, is served by a local stub); only
  `apply` and Google Cloud are simulated. Covers the full cycle with data
  round-trip, idempotency, retention, orphaned buckets, every failure point
  (snapshot, Terraform, plan guard, load, ERROR environments, interrupted
  restores, version/creatability checks), dry-runs and guard-rails.
* `tests/hibernation/unit.bats` — library functions and decision tables, plan
  guards against real Terraform plan JSON (`fixtures/plans/`).
* `tests/hibernation/resolver.bats` — the offline settings resolver.
* `tests/ci/test_pipeline_rules.sh` — which jobs run for schedule/web/push/MR
  pipelines (needs [gitlab-ci-local](https://github.com/firecow/gitlab-ci-local)).
* `tests/ci/validate_gitlab_ci.py` — GitLab CI JSON-schema validation.
* `tests/ci/schedules.bats` — the schedule helper against a fake GitLab API.

What the tests cannot cover is real Google Cloud: run
`HIBERNATE_ACTION=dry-run` once, then a manual shutdown/startup of one
environment before enabling the schedules.
