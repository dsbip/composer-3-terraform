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
| `snapshot_prefix` | `composer-hibernation` | Folder inside the bucket. Snapshots live in `<prefix>/<project>/<region>/<environment-name>/`. See [moving the snapshot location](#moving-the-snapshot-location) before changing this or `snapshot_bucket`. |
| `snapshot_retention_count` | `7` | Snapshots kept per environment. The current restore point is never pruned. |
| `pin_image_version` | `true` | When the YAML has no `software_config.image_version`, recreate on the Airflow version the snapshot was taken on (`composer-3-airflow-X.Y.Z`, newest build). Snapshots can only be loaded into the same or a later Airflow version. With `false` (and no YAML version) the restore uses GCP's default image, so the shutdown checks that the current default is a Composer 3 image able to load the snapshot, and refuses to delete otherwise. |
| `delete_orphaned_bucket` | `true` | Deleting an environment leaves its auto-created bucket behind and the restore creates a new one. When `true`, the old bucket is deleted after the grace period below. Only buckets named like this environment's auto-created bucket are recorded, and right before deleting one it is checked again against every `storage.bucket` and snapshot bucket in the YAML: buckets in use are never deleted. |
| `orphaned_bucket_retention_days` | `7` | Grace period before an orphaned bucket (and the task logs in it) is deleted. `0` = right after the shutdown. |
| `load_options.skip_pypi_packages_installation` | `true` | Terraform already installed the YAML's PyPI packages. |
| `load_options.skip_environment_variables_setting` | `true` | Terraform already set the YAML's environment variables. |
| `load_options.skip_airflow_overrides_setting` | `true` | Terraform already set the YAML's Airflow overrides. |
| `load_options.skip_gcs_data_copying` | `false` | `true` = do not restore `dags/`, `plugins/`, `data/` (e.g. when a DAG deploy pipeline always runs after startup). |

The three `skip_*: true` defaults keep the YAML the single source of truth (no
Terraform drift after a restore) and avoid the slow PyPI re-installation.

Invalid values (wrong types, unknown keys, retention < 1, bad bucket names,
hibernation on a production environment, …) stop the scripts before they act,
and fail every create/update `terraform plan` (normal deploys and startup)
through a precondition on the Composer resource. Terraform does not evaluate
preconditions in destroy plans, so for the shutdown the scripts' own check —
fed by the same settings module — is the guard.

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

### Moving the snapshot location

`snapshot_bucket` and `snapshot_prefix` decide where the state file lives.
Change them only while the environments are `ACTIVE` (running), or first move
the whole folder `<old location>/` (state file and snapshots) to the new
location. A startup that finds a deployed, hibernated environment without a
state file refuses to create it empty and names the location it expected
(`--allow-initial-create` overrides this).

---

## 2. What protects your environments

Nothing is deleted unless **all** of these hold:

1. `hibernation.enabled: true` and the configuration is valid.
2. The environment is not production (labels/name, see above).
3. The environment is `RUNNING` (transitional states are waited out; `ERROR`
   environments are refused unless `--force-delete-without-snapshot`).
4. Its `google_composer_environment` is in **this** Terraform state and is
   **this** environment: the project/region/name in the state equal what the
   YAML resolves to. This catches a wrong backend, an unapplied rename or
   project move onto an existing environment, and a copy-pasted
   `environment_name` (two YAML keys resolving to one environment are refused).
5. It can be restored tomorrow: the restore image version (YAML's, the pinned
   current Airflow version, or — with `pin_image_version: false` — GCP's
   default image) can still be used to **create** environments (checked
   against the Composer `imageVersions` API, fail-closed) and is not older
   than the running Airflow version.
6. The snapshot operation finished without error, returned its `snapshotPath`,
   and the snapshot folder contains the Airflow database dump (`*.sql.gz`).
7. The snapshot is recorded in the state file.
8. The Terraform destroy plan contains **only** deletions of the selected
   Composer environments, each of them (a mistyped target silently plans
   nothing in Terraform), and each deletion removes the expected
   project/region/name.
9. Only what this run decided counts: a `--work-dir` that still holds an
   earlier run's files is refused.

On startup the Terraform plan may only create/update resources inside the
selected environments' module instances (`module.composer["<key>"]`); a
replacement of an `ERROR` environment is accepted only when it loses nothing —
the snapshot is of that very environment, or the environment is younger than
`HIBERNATE_FRESH_ENV_HOURS` — and only if it is the expected
project/region/name; otherwise only `--force-load` replaces it. The whole module
instance is targeted on purpose: a resource-level
`-target` also pulls in the same-named dependencies of every *other*
environment, so a pending change elsewhere — even in production — would leak
into the plan (verified with real Terraform; see
`tests/hibernation/fixtures/plans/create-resource-target-leak.json`).
Snapshots are loaded only into the same or a later Airflow version, and never
over an environment that has existed for longer than
`HIBERNATE_FRESH_ENV_HOURS` (default 96 h) while the state file says it is
hibernated — that one may hold real work (see the state file below). Before
loading over an environment that was found running, a safety snapshot of it is
taken, so the overwrite can be undone: it is retained by age like any other
snapshot (`snapshot_retention_count`). A safety save that is rejected only
warns; one still running after the wait stops the load (re-run startup). When the outcome of an
earlier load cannot be read (Composer API error), neither script guesses: the
run fails for that environment and can be re-run.

GitLab adds: one `resource_group` shared by shutdown, startup and `dev-apply`
(never two at once), `interruptible: false`, `auto_cancel: none` for
scheduled/manual pipelines so a merge cannot cancel a running shutdown, and
shutdown/startup run only on the default branch.

---

## 3. The state file

Each environment has `<snapshot_location>/hibernation-state.json`:

| Status | Meaning | Next startup, environment absent | Next startup, environment running |
|---|---|---|---|
| `NONE` (no file) | Never hibernated. | Creates it empty — unless the module is deployed and only the Composer resource is gone (hibernated, but the state file is elsewhere: refused, see [moving the snapshot location](#moving-the-snapshot-location)) or was never deployed (`--allow-initial-create`). | Nothing. |
| `SNAPSHOT_SAVED` | Snapshot taken; deletion not (yet) confirmed. | Recreate + load. | The environment the restore point was taken of (same uuid): it was never deleted → `ACTIVE`, nothing loaded. Any other environment (re-created, or never restored — e.g. after a "keep"): like `HIBERNATED`. |
| `HIBERNATED` | Environment deleted; `latest_snapshot` is the restore point. | Recreate + load. | Re-created outside the cycle (e.g. `dev-apply` at night): load into it if it is younger than `HIBERNATE_FRESH_ENV_HOURS`; otherwise refused — `--skip-load` keeps it as it is, `--force-load` loads. |
| `RESTORING` | A startup is in progress or was interrupted. | Recreate + load. | Load — unless the recorded load into this environment already finished (then only `ACTIVE` is written); same age rule as above. |
| `ACTIVE` | Running with the snapshot restored (or created empty). | Deleted outside the cycle: recreated from the last snapshot (the log names its date). | Nothing. |

An environment in `ERROR` (it cannot be snapshotted) is replaced + loaded when
that loses nothing: the snapshot is of that very environment (`SNAPSHOT_SAVED`,
same uuid), or the environment is younger than `HIBERNATE_FRESH_ENV_HOURS`
and never received the snapshot (e.g. startup itself created it into `ERROR`).
An older one, or one the snapshot had already been loaded into (it may hold
work done since), is refused; `--force-load` replaces it. `--skip-load` never
replaces a refused one (a young one is replaced by an empty environment).

When startup refuses to decide (`would overwrite` / `would destroy`), it
records `awaiting_decision` (with that environment's uuid) in the state file,
and every shutdown of that environment fails (leaving it running) until it is
resolved — otherwise the evening shutdown would silently make the decision. A
running environment is resolved by a startup with `HIBERNATE_SKIP_LOAD` or
`HIBERNATE_FORCE_LOAD`; an `ERROR` one by fixing it or `HIBERNATE_FORCE_LOAD`.
The decision is dropped automatically once that environment is gone or
replaced by another one.

A shutdown normally makes its new snapshot the restore point. It keeps the old
one (and stores the new snapshot as secondary, `restore_incomplete: true`) when
the environment never received it: a restore that did not complete
(`RESTORING`), or an environment re-created while `HIBERNATED` /
`SNAPSHOT_SAVED`. An environment running for longer than
`HIBERNATE_FRESH_ENV_HOURS` is assumed to hold real work, and its snapshot
becomes the restore point (the old one stays until retention prunes it). An
environment whose age cannot be read counts as young here ("keep" retains both
snapshots) and as old at startup (refused).
`--skip-load` deliberately starts empty, so the next shutdown's snapshot of
that empty environment becomes the restore point.

The file also records every snapshot (path, time, image/Airflow version,
service account, environment bucket, environment uuid and creation time),
the last load operation (`restore_attempt`), safety snapshots taken before
loading over a running environment (`safety: true`), snapshot saves abandoned
while still running (`pending_saves`; once finished their folders are deleted
by the next prune, `untracked: true`), orphaned buckets
awaiting deletion, the last restore, and a bounded history with the GitLab
pipeline/job of each change.

Both scripts are idempotent and decide what to do from the live environment
state plus this file, so any job can simply be re-run:

* shutdown failed before deleting → the environment keeps running; the next
  run takes a fresh snapshot;
* shutdown deleted the environment but failed afterwards → the next run marks
  it `HIBERNATED`;
* startup failed while creating or loading → state stays `RESTORING`; the next
  run creates/replaces as needed and loads (Composer resumes partial loads);
* the load finished server-side after the job gave up, or the final `ACTIVE`
  write failed → the next startup sees the completed load operation and only
  marks the environment `ACTIVE`; the evening shutdown treats the restore as
  complete;
* a shutdown while a restore is incomplete, or of an environment re-created
  empty while hibernated, never replaces the last good restore point with a
  snapshot of an empty environment — also when its delete then fails and the
  shutdown or the next startup runs again (the decision compares the running
  environment with the restore point's environment);
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
PROJECT_ID=group/composer-3-terraform TIMEZONE=Europe/London \
  scripts/ci/create-hibernation-schedules.sh --set-resource-group-mode
```

Notes from GitLab's behaviour:

* Schedules fire when GitLab's scheduler worker runs (every 5–10 minutes,
  later on busy instances). Startup takes ~25 min (create) + snapshot load;
  start early enough before working hours.
* Optional schedule variable `HIBERNATE_ENVIRONMENTS=composer-dev,composer-qa`
  restricts a schedule to some environments — e.g. different hours per team
  (create more schedules). A value that names no environment (empty, `,`) is
  refused rather than meaning "all"; delete the variable to select every
  enabled environment.
* Every trigger is a pipeline variable (`HIBERNATE_ACTION`), so the project's
  *Settings → CI/CD → Variables → Minimum role to use pipeline variables* must
  allow the schedule owner and whoever runs manual pipelines. Self-managed
  GitLab defaults to Maintainer; GitLab.com projects in namespaces created
  since GitLab 17.7 default to *No one allowed* — change it first, or no
  hibernation job ever runs.
* Create the schedules on the **default branch**: the hibernation jobs do not
  run on any other ref (the helper looks the branch up and refuses another
  `REF`).
* Set the resource group to `oldest_first` once it exists (after the first
  run), so a delayed shutdown can never be overtaken by the next startup:
  `PUT /projects/:id/resource_groups/composer-hibernation-dev?process_mode=oldest_first`
  (the helper's `--set-resource-group-mode` does it).
* The runner's maximum job timeout must allow the jobs' `timeout: 3h`.

Scheduled pipelines run **only** the matching hibernation job; plan/apply/test
jobs are excluded (`tests/ci/test_pipeline_rules.sh` proves this for every
pipeline source).

### 4.4 Manual runs

*Build → Pipelines → Run pipeline* on the **default branch**:

* `HIBERNATE_ACTION=shutdown` / `startup` — runs that job immediately;
* `HIBERNATE_ACTION=dry-run` — read-only rehearsal (plans, no changes);
* no variable — the normal pipeline plus manual buttons for all three.

Recovery options are passed as variables on such a one-off run, together with
`HIBERNATE_ENVIRONMENTS=<key>` (required) so they only touch that environment
— never as schedule, project or group variables (refused on schedules):
`HIBERNATE_SKIP_LOAD`, `HIBERNATE_FORCE_LOAD`, `HIBERNATE_ALLOW_INITIAL_CREATE`
(startup) and `HIBERNATE_FORCE_DELETE_WITHOUT_SNAPSHOT` (shutdown). Prefer this
to running the scripts locally: a local run needs the CI identity's
permissions and does not take the `composer-hibernation-dev` resource-group
lock, so it can overlap a scheduled job or `dev-apply`.

Shutdown and startup do not run on other branches or tags (like `dev-apply`):
they would apply that ref's unreviewed YAML and code to the shared dev state —
for example hibernate an environment that the default branch never restores.
The dry-run is read-only and available on any branch; its startup half only
plans a recreate for environments that are absent, so run it while they are
hibernated to rehearse that plan. These rules guard against accidents, not
against someone who can push a branch (they can edit the rules there). A real
boundary needs a separate WIF provider / service account for the apply and
hibernation jobs with an attribute condition such as
`assertion.ref_protected == "true"`, and a read-only identity for MR plans.

Job artifacts (`.hibernation/`, 30 days) contain the resolved settings, every
Terraform plan (`.tfplan`, `.txt`, `.json`), per-environment logs, copies of
the state files and `summary.json`. Each job writes to its own
`.hibernation/<job>-<job id>/`.

---

## 5. Running the scripts directly

```bash
# authenticated gcloud + Terraform credentials, then:
export TF_BACKEND_BUCKET=my-tfstate-bucket TF_BACKEND_PREFIX=composer-3-state
scripts/hibernation/composer-shutdown.sh --config configs/development.yaml --dry-run
scripts/hibernation/composer-shutdown.sh --config configs/development.yaml
scripts/hibernation/composer-startup.sh  --config configs/development.yaml --env composer-dev
```

Command-line options replace the corresponding environment variables
(`--skip-load` / `--force-load` replace both load variables; the other boolean
recovery variables cannot be switched off from the command line).

| Option | |
|---|---|
| `-c, --config FILE` | The module's YAML (or `HIBERNATE_CONFIG_FILE`). |
| `-e, --env KEY[,KEY]` | Only these environments (repeatable; replaces `HIBERNATE_ENVIRONMENTS`). Default: all with `hibernation.enabled: true`. A value naming no environment is an error. |
| `-n, --dry-run` | Inspect and plan only (or `HIBERNATE_DRY_RUN=true`). |
| `--var-file FILE` | Extra `-var-file` for Terraform (repeatable; replaces `HIBERNATE_TF_VAR_FILES`). |
| `--skip-init` | Terraform is already initialised (or `HIBERNATE_SKIP_INIT=true`). |
| `--work-dir DIR` | Where logs/plans/summary go (or `HIBERNATE_WORK_DIR`). Must be new or empty for every run; default `$TF_ROOT/.hibernation/<mode>-<timestamp>-<pid>`. |
| `--force-delete-without-snapshot` | shutdown: delete `ERROR` environments (restore uses the previous snapshot). Or `HIBERNATE_FORCE_DELETE_WITHOUT_SNAPSHOT=true`. |
| `--allow-initial-create` | startup: allow creating an environment without its hibernation state file (first deployment, or knowingly starting empty). Or `HIBERNATE_ALLOW_INITIAL_CREATE=true`. |
| `--skip-load` | startup: load nothing — recreated environments start empty, running ones are kept as they are; the next shutdown's snapshot becomes the restore point. Never replaces an `ERROR` environment that startup refuses to replace (a young one is replaced by an empty environment). Or `HIBERNATE_SKIP_LOAD=true`. |
| `--force-load` | startup: load the snapshot even into an environment that has existed for longer than `HIBERNATE_FRESH_ENV_HOURS`, or replace such an environment in `ERROR` (overwrites its Airflow database). Or `HIBERNATE_FORCE_LOAD=true`. |

| Environment variable | Default | |
|---|---|---|
| `HIBERNATE_CONFIG_FILE`, `HIBERNATE_ENVIRONMENTS`, `HIBERNATE_DRY_RUN`, `HIBERNATE_SKIP_INIT`, `HIBERNATE_TF_VAR_FILES`, `HIBERNATE_WORK_DIR` | — | Same as the options above (`HIBERNATE_ENVIRONMENTS` set but naming no environment is refused). |
| `HIBERNATE_FORCE_DELETE_WITHOUT_SNAPSHOT` (shutdown), `HIBERNATE_ALLOW_INITIAL_CREATE`, `HIBERNATE_SKIP_LOAD`, `HIBERNATE_FORCE_LOAD` (startup) | `false` | The recovery options above, for a one-off manual GitLab run (each only affects its own script). Refused on scheduled pipelines and without `HIBERNATE_ENVIRONMENTS` / `--env`, so one left behind in a schedule or in the CI/CD variables cannot act on every night or every environment. Active options are logged and recorded in the state file history. |
| `TF_ROOT` | repository root | Terraform root module. |
| `TF_MODULE_ADDRESS` | `module.composer` | Address of the module call (if you wrap this module differently). |
| `TF_BACKEND_BUCKET` / `TF_BACKEND_PREFIX` | — | GCS backend; a git-ignored `backend_override.tf` is generated when the root declares no backend, and init is verified to have selected `gcs`. |
| `TF_LOCK_TIMEOUT` | `20m` | |
| `HIBERNATE_OPERATION_TIMEOUT_MINUTES` | `90` | Snapshot save/load timeout. |
| `HIBERNATE_WAIT_TIMEOUT_MINUTES` | `60` | Waiting for `CREATING`/`UPDATING`/`DELETING`. |
| `HIBERNATE_POLL_SECONDS` | `30` | Polling interval. In the parallel snapshot/load phases each environment's log is printed when its batch finishes (live in `logs/<key>-<phase>.log`). |
| `HIBERNATE_POLL_FAILURE_GRACE_SECONDS` | `900` | Keep polling a running snapshot/load through API or network errors for this long. |
| `HIBERNATE_MAX_PARALLEL` | `4` | Concurrent snapshot/load operations. |
| `HIBERNATE_LOAD_ATTEMPTS` | `2` | A retried load resumes a partial one. |
| `HIBERNATE_FRESH_ENV_HOURS` | `96` | An environment found running while the state file says it is hibernated counts as new and empty up to this age (covers a deploy on Friday evening and a startup after a long weekend). |
| `HIBERNATE_GCLOUD_RETRIES` / `HIBERNATE_RETRY_SLEEP_SECONDS` | `3` / `10` | Attempts per gcloud call and the pause between them (plus jitter). |
| `HIBERNATE_SKIP_IMAGE_CHECK` | `false` | Skip the "can it be re-created?" check. |
| `HIBERNATE_COMPOSER_API` | `https://composer.googleapis.com` | Composer REST endpoint for the image version listing. |
| `HIBERNATE_LOCK_TIMEOUT_SECONDS` | `600` | Wait for the job-local lock that serialises snapshot-bucket IAM changes. |

Exit codes: `0` success or nothing to do; `1` at least one environment failed
(the others are still processed) — including an environment whose own
settings are invalid, production, disabled or not eligible; `2` bad arguments,
an unknown environment key, an unreadable YAML, a reused work dir, or a
Terraform init/state prerequisite failure.

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
  snapshot into it, and a shutdown before that keeps the good restore point.
  If such an environment keeps running for longer than
  `HIBERNATE_FRESH_ENV_HOURS` (e.g. hibernation was disabled for weeks), it is
  assumed to hold real work: startup refuses to overwrite it (decide with
  `HIBERNATE_SKIP_LOAD` / `HIBERNATE_FORCE_LOAD`), and shutdown makes its
  snapshot the restore point — unless a startup already refused, then the
  shutdown waits for that decision. A younger environment is loaded over, but a
  safety snapshot of it is kept first (retained like any other snapshot).
* **Snapshot limits:** Airflow database < 20 GB, < 100,000 objects in
  `dags/`+`plugins/`+`data/`. Use `data_retention` to keep the database small.
* **Outputs while hibernated:** `terraform output` keeps stale values for a
  deleted environment (`airflow_uri`, `gcs_bucket`, …) until the next full apply.
* **Composer "development mode"** environments have native hibernate/resume
  for some Airflow versions, but cannot be created by the Terraform provider and
  have tight limits — this snapshot-based approach works for any Composer 3
  environment the module creates.
* **Holidays:** deactivate the startup schedule for days nobody works. Do not
  empty `HIBERNATE_ENVIRONMENTS` instead: a list naming no environment is
  refused, and deleting the variable selects *every* enabled environment.

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
| startup: `only load into the same or a later Airflow version` | The recreated environment runs an older Airflow version than the snapshot (state stays `RESTORING`). Startup does not change a running environment's image, so a re-run alone does not help: set a compatible `image_version`, apply it with the normal deploy (in-place upgrade) or delete the environment, then re-run startup. |
| `… the Terraform state but the YAML resolves to …` / `disagree on which environment` | The state holds a different environment than the YAML names: apply the pending rename/move first, fix a duplicated `environment_name`, or check the backend. |
| `… is also defined by: …` | Two YAML keys resolve to the same project/region/name. |
| `would overwrite its Airflow database` (startup) | The environment has existed for a long time (or its age is unknown) although the state file says hibernated. Run startup with `HIBERNATE_SKIP_LOAD=true` to keep it (`ACTIVE`) or `HIBERNATE_FORCE_LOAD=true` to load the snapshot over it — on a one-off *Run pipeline* with `HIBERNATE_ENVIRONMENTS=<key>`. Shutdowns of it fail until then. |
| `is in ERROR … cannot be snapshotted, so replacing it would destroy its Airflow database` | Same, for an `ERROR` environment (long-lived, or the snapshot had already been loaded into it): fix it, or `HIBERNATE_FORCE_LOAD=true` to replace it with the snapshot. |
| `waiting for an operator decision` (shutdown) | A startup refused to overwrite this environment; the message says how to resolve it (as above). |
| `recovery variable(s) … must not be set for scheduled pipelines` / `… need HIBERNATE_ENVIRONMENTS` | Remove the variable from the schedule / CI/CD variables; pass it only on a one-off run together with `HIBERNATE_ENVIRONMENTS`. |
| `the safety snapshot of the running environment is still in progress` | The Composer API did not report the safety snapshot finishing in time; nothing was loaded. Re-run startup. |
| `could not check whether the … snapshot load completed` | The Composer API failed while reading the earlier load operation; nothing was changed. Re-run. |
| `no hibernation state file at …` (startup) | The state file is not where the settings point (`snapshot_bucket`/`snapshot_prefix` changed?). Move the old folder there, or `--allow-initial-create` to start empty. |
| `already holds the files of an earlier run` | Use a new, empty `--work-dir` / `HIBERNATE_WORK_DIR` per run. |
| `names no environment` | `--env` or `HIBERNATE_ENVIRONMENTS` is empty; delete the variable for "all enabled environments". |
| `GCP's default image …` | `pin_image_version: false` without a YAML version and GCP's default cannot load the snapshot (or is not Composer 3). Pin `software_config.image_version`. |
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
  Each review finding has a scenario that reproduces it (they fail against the
  scripts before the fix): re-created environments while hibernated, stale
  `RESTORING`, reused work dirs, state/YAML identity mismatches, a moved state
  file, protected orphan buckets, vanished snapshots, API outages while
  polling, and more.
* `tests/hibernation/unit.bats` — library functions and decision tables, plan
  guards against real Terraform plan JSON (`fixtures/plans/`).
* `tests/hibernation/regression.bats` — the `pipefail` + `grep -q` SIGPIPE trap
  on large states.
* `tests/hibernation/resolver.bats` — the offline settings resolver.
* `tests/ci/test_pipeline_rules.sh` — which jobs run for schedule/web/push/MR
  pipelines, on the default branch, another branch and a tag (needs
  [gitlab-ci-local](https://github.com/firecow/gitlab-ci-local)).
* `tests/ci/validate_gitlab_ci.py` — GitLab CI JSON-schema validation.
* `tests/ci/schedules.bats` — the schedule helper against a fake GitLab API.

What the tests cannot cover is real Google Cloud: run
`HIBERNATE_ACTION=dry-run` once, then a manual shutdown/startup of one
environment before enabling the schedules.
