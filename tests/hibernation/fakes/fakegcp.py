#!/usr/bin/env python3
"""Simulated Google Cloud for the hibernation test-suite.

Implements exactly the gcloud sub-commands scripts/hibernation uses, against a
directory-backed "world" ($FAKE_GCP_DIR), mimicking gcloud's real output
shapes and error texts (taken from the gcloud SDK source):

  composer environments describe | snapshots save | snapshots load
  composer operations describe
  storage cat | cp | ls [--recursive] | rm --recursive
  storage buckets describe | create | get-iam-policy | add-iam-policy-binding

World layout:
  envs/<project>__<region>__<name>.json   describe JSON (+ "_"-prefixed internals)
  gcs/<bucket>/...                          objects as files
  gcs/<bucket>/.bucket.json                 bucket metadata (+ IAM bindings)
  ops/<id>.json                             long-running operations
  calls.log                                 one JSON argv per invocation
  faults.json                               injected failures (see below)

Faults (faults.json, list of objects):
  {"match": "<regex on the space-joined argv>", "rc": 1,
   "stderr": "ERROR: ...", "times": N}           fail the command N times
  {"match": "...", "op_error": {"code": 9, "message": "..."}}
                                                 operation completes with error
Environment:
  FAKE_OP_POLLS   number of "done": false polls before an operation finishes (1)

Internal sub-commands (not gcloud):
  apply-events FILE      create/delete environments from tfstate_apply.py events
  seed-env KEY=VALUE...  create an environment directly (tests)
"""
import datetime
import json
import os
import re
import shutil
import sys
import uuid

WORLD = os.environ.get("FAKE_GCP_DIR")
if not WORLD:
    sys.stderr.write("FAKE_GCP_DIR not set\n")
    sys.exit(97)


def p(*parts):
    return os.path.join(WORLD, *parts)


def jload(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def jdump(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        json.dump(obj, f, indent=1)
    os.replace(path + ".tmp", path)


def now():
    return datetime.datetime.now(datetime.timezone.utc)


def fail(msg, rc=1):
    sys.stderr.write(msg.rstrip("\n") + "\n")
    sys.exit(rc)


def out(obj):
    sys.stdout.write(json.dumps(obj, indent=2) + "\n")


# ── argument helpers ─────────────────────────────────────────────────────────
def parse_flags(args):
    """Returns (positionals, flags) — supports --k=v, --k v and bare --k."""
    pos, flags, i = [], {}, 0
    bare = {"--async", "--quiet", "--recursive", "-r", "--uniform-bucket-level-access",
            "--public-access-prevention", "--skip-pypi-packages-installation",
            "--skip-environment-variables-setting", "--skip-airflow-overrides-setting",
            "--skip-gcs-data-copying"}
    while i < len(args):
        a = args[i]
        if a.startswith("--") and "=" in a:
            k, v = a.split("=", 1)
            flags[k] = v
        elif a in bare:
            flags[a] = True
        elif a.startswith("--"):
            flags[a] = args[i + 1] if i + 1 < len(args) else True
            i += 1
        else:
            pos.append(a)
        i += 1
    return pos, flags


def check_faults(argv):
    """Applies command faults; returns an op_error to attach, if any."""
    faults = jload(p("faults.json"), [])
    line = " ".join(argv)
    changed, op_error = False, None
    for f in faults:
        if not re.search(f["match"], line):
            continue
        if f.get("times", 1) <= 0:
            continue
        f["times"] = f.get("times", 1) - 1
        changed = True
        if "op_error" in f:
            op_error = f["op_error"]
            break
        jdump(p("faults.json"), faults)
        fail(f.get("stderr", "ERROR: injected failure"), f.get("rc", 1))
    if changed:
        jdump(p("faults.json"), faults)
    return op_error


# ── environments ─────────────────────────────────────────────────────────────
def env_path(project, region, name):
    return p("envs", f"{project}__{region}__{name}.json")


def load_env(project, region, name, cmd):
    env = jload(env_path(project, region, name))
    if env is None:
        fail(f"ERROR: (gcloud.{cmd}) NOT_FOUND: Resource 'projects/{project}/locations/{region}/"
             f"environments/{name}' was not found")
    return env


def public(env):
    return {k: v for k, v in env.items() if not k.startswith("_")}


def describe_env(project, region, name):
    path = env_path(project, region, name)
    env = load_env(project, region, name, "composer.environments.describe")
    # Transitional states: [{"state": "UPDATING", "polls": 2}, ...] then
    # the final "_final_state" (or deletion when it is "GONE").
    trans = env.get("_transitions") or []
    if trans:
        env["state"] = trans[0]["state"]
        trans[0]["polls"] -= 1
        if trans[0]["polls"] <= 0:
            trans.pop(0)
        if not trans:
            final = env.pop("_final_state", "RUNNING")
            env.pop("_transitions", None)
            if final == "GONE":
                os.remove(path)
                out(public(env))
                return
            env["_next_state"] = final
        jdump(path, env)
        out(public(env))
        return
    if env.get("_next_state"):
        env["state"] = env.pop("_next_state")
        jdump(path, env)
    out(public(env))


def make_env(project, region, name, image, sa, bucket=None, state="RUNNING", db=""):
    bucket = bucket or f"{region}-{name}-{uuid.uuid4().hex[:8]}-bucket"
    env = {
        "name": f"projects/{project}/locations/{region}/environments/{name}",
        "state": state,
        "config": {
            "dagGcsPrefix": f"gs://{bucket}/dags",
            "softwareConfig": {"imageVersion": image},
            "nodeConfig": {"serviceAccount": sa},
            "environmentSize": "ENVIRONMENT_SIZE_SMALL",
        },
        "storageConfig": {"bucket": bucket},
        "uuid": str(uuid.uuid4()),
        "createTime": now().isoformat(),
        "_db": db,
        "_loads": [],
    }
    jdump(env_path(project, region, name), env)
    ensure_bucket(bucket, project, region, labels={"goog-composer-environment": name})
    os.makedirs(p("gcs", bucket, "dags"), exist_ok=True)
    os.makedirs(p("gcs", bucket, "plugins"), exist_ok=True)
    os.makedirs(p("gcs", bucket, "data"), exist_ok=True)
    return env


# ── operations ───────────────────────────────────────────────────────────────
def new_op(project, region, op_type, env_name, response=None, error=None):
    op_id = str(uuid.uuid4())
    op = {
        "name": f"projects/{project}/locations/{region}/operations/{op_id}",
        "metadata": {"@type": "type.googleapis.com/google.cloud.orchestration.airflow.service.v1.OperationMetadata",
                     "operationType": op_type, "resource": env_name, "state": "RUNNING"},
        "done": False,
        "_polls": int(os.environ.get("FAKE_OP_POLLS", "1")),
        "_response": response,
        "_error": error,
    }
    jdump(p("ops", op_id + ".json"), op)
    return op


def describe_op(op_id):
    path = p("ops", op_id + ".json")
    op = jload(path)
    if op is None:
        fail(f"ERROR: (gcloud.composer.operations.describe) NOT_FOUND: operation {op_id} not found")
    if op["_polls"] > 0:
        op["_polls"] -= 1
        jdump(path, op)
        out({k: v for k, v in op.items() if not k.startswith("_")})
        return
    res = {k: v for k, v in op.items() if not k.startswith("_")}
    res["done"] = True
    res["metadata"]["state"] = "FAILED" if op["_error"] else "SUCCEEDED"
    if op["_error"]:
        res["error"] = op["_error"]
    elif op["_response"] is not None:
        res["response"] = op["_response"]
    out(res)


# ── storage ──────────────────────────────────────────────────────────────────
def split_gs(url):
    m = re.match(r"^gs://([^/]+)/?(.*)$", url)
    if not m:
        fail(f"ERROR: invalid url {url}")
    return m.group(1), m.group(2)


def bucket_meta_path(bucket):
    return p("gcs", bucket, ".bucket.json")


def ensure_bucket(bucket, project, location, labels=None):
    if jload(bucket_meta_path(bucket)) is None:
        jdump(bucket_meta_path(bucket), {"name": bucket, "project": project, "location": location.upper(),
                                         "labels": labels or {}, "iam": []})


def require_bucket(bucket, cmd):
    if jload(bucket_meta_path(bucket)) is None:
        fail(f"ERROR: (gcloud.{cmd}) gs://{bucket} not found: 404.")


def walk_objects(bucket, prefix):
    base = p("gcs", bucket)
    res = []
    for root, _dirs, files in os.walk(base):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, base)
            if rel == ".bucket.json":
                continue
            if rel.startswith(prefix):
                res.append(rel)
    return sorted(res)


def storage(args):
    sub = args[0]
    pos, flags = parse_flags(args[1:])
    if sub == "cat":
        bucket, obj = split_gs(pos[0])
        path = p("gcs", bucket, obj)
        if jload(bucket_meta_path(bucket)) is None or not os.path.isfile(path):
            fail(f"ERROR: (gcloud.storage.cat) The following URLs matched no objects or files:\n-{pos[0]}")
        sys.stdout.write(open(path).read())
    elif sub == "cp":
        src, dst = pos
        bucket, obj = split_gs(dst)
        require_bucket(bucket, "storage.cp")
        os.makedirs(os.path.dirname(p("gcs", bucket, obj)), exist_ok=True)
        shutil.copyfile(src, p("gcs", bucket, obj))
    elif sub == "ls":
        url = pos[0]
        bucket, prefix = split_gs(url)
        if jload(bucket_meta_path(bucket)) is None:
            fail(f"ERROR: (gcloud.storage.ls) gs://{bucket} not found: 404.")
        if "*" in prefix:
            import fnmatch
            matches = [o for o in walk_objects(bucket, prefix.split("*", 1)[0]) if fnmatch.fnmatchcase(o, prefix)
                       and "/" not in o[len(prefix.rsplit("/", 1)[0]) + 1:]]
            if not matches:
                fail("ERROR: (gcloud.storage.ls) One or more URLs matched no objects.")
            sys.stdout.write("".join(f"gs://{bucket}/{o}\n" for o in matches))
            return
        objs = walk_objects(bucket, prefix)
        if not objs:
            fail("ERROR: (gcloud.storage.ls) One or more URLs matched no objects.")
        if flags.get("--recursive") or flags.get("-r"):
            # gcloud prints "<dir>:" headers followed by the entries.
            dirs = {}
            for o in objs:
                d = o.rsplit("/", 1)[0] + "/" if "/" in o else ""
                dirs.setdefault(d, []).append(o)
            chunks = []
            for d in sorted(dirs):
                chunks.append(f"gs://{bucket}/{d}:\n" + "".join(f"gs://{bucket}/{o}\n" for o in dirs[d]))
            sys.stdout.write("\n".join(chunks))
        else:
            seen = []
            for o in objs:
                rest = o[len(prefix):]
                entry = f"gs://{bucket}/{prefix}{rest.split('/', 1)[0]}" + ("/" if "/" in rest else "")
                if entry not in seen:
                    seen.append(entry)
            sys.stdout.write("".join(e + "\n" for e in seen))
    elif sub == "rm":
        url = pos[0]
        bucket, prefix = split_gs(url)
        if jload(bucket_meta_path(bucket)) is None:
            fail(f"ERROR: (gcloud.storage.rm) gs://{bucket} not found: 404.")
        if prefix == "":
            shutil.rmtree(p("gcs", bucket))
            return
        objs = walk_objects(bucket, prefix)
        if not objs:
            fail("ERROR: (gcloud.storage.rm) The following URLs matched no objects or files:\n-" + url)
        for o in objs:
            os.remove(p("gcs", bucket, o))
        target = p("gcs", bucket, prefix.rstrip("/"))
        if os.path.isdir(target):
            shutil.rmtree(target)
    elif sub == "buckets":
        bsub = args[1]
        pos, flags = parse_flags(args[2:])
        bucket, _ = split_gs(pos[0])
        if bsub == "describe":
            meta = jload(bucket_meta_path(bucket))
            if meta is None:
                fail(f"ERROR: (gcloud.storage.buckets.describe) gs://{bucket} not found: 404.")
            out({"name": bucket, "location": meta["location"], "labels": meta["labels"],
                 "storage_url": f"gs://{bucket}/"})
        elif bsub == "create":
            if jload(bucket_meta_path(bucket)) is not None:
                fail("ERROR: (gcloud.storage.buckets.create) HTTPError 409: Your previous request to create "
                     "the named bucket succeeded and you already own it.")
            ensure_bucket(bucket, flags.get("--project"), flags.get("--location", "US"))
            meta = jload(bucket_meta_path(bucket))
            meta["create_flags"] = sorted(k for k in flags)
            jdump(bucket_meta_path(bucket), meta)
        elif bsub == "get-iam-policy":
            meta = jload(bucket_meta_path(bucket))
            if meta is None:
                fail(f"ERROR: (gcloud.storage.buckets.get-iam-policy) gs://{bucket} not found: 404.")
            groups = {}
            for b in meta["iam"]:
                k = (b["role"], json.dumps(b.get("condition"), sort_keys=True))
                groups.setdefault(k, []).append(b["member"])
            bindings = []
            for (role, cond), members in sorted(groups.items()):
                entry = {"role": role, "members": members}
                if json.loads(cond) is not None:
                    entry["condition"] = json.loads(cond)
                bindings.append(entry)
            out({"bindings": bindings, "etag": "CAE=", "version": 3})
        elif bsub == "add-iam-policy-binding":
            meta = jload(bucket_meta_path(bucket))
            if meta is None:
                fail(f"ERROR: (gcloud.storage.buckets.add-iam-policy-binding) gs://{bucket} not found: 404.")
            # Like gcloud (iam_util.AddBindingToIamPolicyWithCondition): a policy
            # with any conditional binding needs an explicit --condition when
            # prompts are disabled.
            if any(x.get("condition") for x in meta["iam"]) and "--condition" not in flags:
                fail("ERROR: (gcloud.storage.buckets.add-iam-policy-binding) Adding a binding without specifying "
                     "a condition to a policy containing conditions is prohibited in non-interactive mode. Run the "
                     "command again with `--condition=None`")
            b = {"member": flags["--member"], "role": flags["--role"]}
            if b not in meta["iam"]:
                meta["iam"].append(b)
            jdump(bucket_meta_path(bucket), meta)
        else:
            fail(f"fake gcloud: unsupported storage buckets {bsub}", 98)
    else:
        fail(f"fake gcloud: unsupported storage {sub}", 98)


# ── composer ─────────────────────────────────────────────────────────────────
def composer(args, op_error):
    pos, flags = parse_flags(args)
    if pos[:2] == ["environments", "describe"]:
        describe_env(flags["--project"], flags["--location"], pos[2])
    elif pos[:3] == ["environments", "snapshots", "save"]:
        name, project, region = pos[3], flags["--project"], flags["--location"]
        env = load_env(project, region, name, "composer.environments.snapshots.save")
        if env["state"] != "RUNNING":
            fail("ERROR: (gcloud.composer.environments.snapshots.save) FAILED_PRECONDITION: "
                 f"Environment is in {env['state']} state")
        loc = flags.get("--snapshot-location") or f"gs://{env['storageConfig']['bucket']}/snapshots"
        bucket, prefix = split_gs(loc)
        require_bucket(bucket, "composer.environments.snapshots.save")
        meta = jload(bucket_meta_path(bucket))
        sa = env["config"]["nodeConfig"]["serviceAccount"]
        if {"member": f"serviceAccount:{sa}", "role": "roles/storage.objectAdmin"} not in meta["iam"]:
            op_error = op_error or {"code": 7, "message": f"PERMISSION_DENIED: {sa} cannot write to gs://{bucket}"}
        seq = len(os.listdir(p("ops"))) if os.path.isdir(p("ops")) else 0
        folder = f"{project}_{region}_{name}_{now().strftime('%Y-%m-%dT%H-%M-%S')}-{seq:04d}"
        snap = f"{prefix.rstrip('/')}/{folder}"
        response = None
        if op_error is None:
            dst = p("gcs", bucket, snap)
            os.makedirs(dst, exist_ok=True)
            jdump(os.path.join(dst, "metadata.json"), {"imageVersion": env["config"]["softwareConfig"]["imageVersion"],
                                                       "environment": env["name"]})
            # Real snapshots hold a *.sql.gz dump at the top level.
            with open(os.path.join(dst, "airflow-database.sql.gz"), "w") as f:
                f.write(env.get("_db", ""))
            env_bucket = env["storageConfig"]["bucket"]
            for folder_name in ("dags", "plugins", "data"):
                src = p("gcs", env_bucket, folder_name)
                if os.path.isdir(src):
                    shutil.copytree(src, os.path.join(dst, "gcs", folder_name), dirs_exist_ok=True)
            response = {"@type": "type.googleapis.com/google.cloud.orchestration.airflow.service.v1.SaveSnapshotResponse",
                        "snapshotPath": f"gs://{bucket}/{snap}"}
        op = new_op(project, region, "SAVE_SNAPSHOT", env["name"], response, op_error)
        out({k: v for k, v in op.items() if not k.startswith("_")})
    elif pos[:3] == ["environments", "snapshots", "load"]:
        name, project, region = pos[3], flags["--project"], flags["--location"]
        env = load_env(project, region, name, "composer.environments.snapshots.load")
        if env["state"] != "RUNNING":
            fail("ERROR: (gcloud.composer.environments.snapshots.load) FAILED_PRECONDITION: "
                 f"Environment is in {env['state']} state")
        bucket, snap = split_gs(flags["--snapshot-path"])
        src = p("gcs", bucket, snap)
        if op_error is None and not os.path.isfile(os.path.join(src, "metadata.json")):
            op_error = {"code": 5, "message": f"snapshot {flags['--snapshot-path']} not found"}
        if op_error is None:
            env["_db"] = open(os.path.join(src, "airflow-database.sql.gz")).read()
            skips = sorted(k for k in flags if k.startswith("--skip-"))
            env["_loads"].append({"path": flags["--snapshot-path"], "skips": skips})
            if "--skip-gcs-data-copying" not in flags:
                env_bucket = env["storageConfig"]["bucket"]
                gsrc = os.path.join(src, "gcs")
                if os.path.isdir(gsrc):
                    shutil.copytree(gsrc, p("gcs", env_bucket), dirs_exist_ok=True)
            jdump(env_path(project, region, name), env)
        op = new_op(project, region, "LOAD_SNAPSHOT", env["name"], {}, op_error)
        out({k: v for k, v in op.items() if not k.startswith("_")})
    elif pos[:2] == ["operations", "describe"]:
        describe_op(pos[2].rsplit("/", 1)[-1])
    else:
        fail(f"fake gcloud: unsupported composer {' '.join(pos)}", 98)


# ── internal commands ────────────────────────────────────────────────────────
def apply_events(path):
    for ev in jload(path, []):
        if ev["action"] == "delete":
            ep = env_path(ev["project"], ev["region"], ev["name"])
            if os.path.exists(ep):
                os.remove(ep)
        elif ev["action"] == "create":
            make_env(ev["project"], ev["region"], ev["name"], ev["image_version"],
                     ev.get("service_account") or f"{ev['name']}-sa@{ev['project']}.iam.gserviceaccount.com",
                     bucket=ev.get("bucket"), state=os.environ.get("FAKE_CREATE_STATE", "RUNNING"))


def main():
    argv = sys.argv[1:]
    if argv and argv[0] == "apply-events":
        return apply_events(argv[1])
    if argv and argv[0] == "seed-env":
        kv = dict(a.split("=", 1) for a in argv[1:])
        make_env(kv["project"], kv["region"], kv["name"], kv.get("image", "composer-3-airflow-2.10.5-build.20"),
                 kv.get("sa", f"{kv['name']}-sa@{kv['project']}.iam.gserviceaccount.com"),
                 bucket=kv.get("bucket"), state=kv.get("state", "RUNNING"), db=kv.get("db", ""))
        return
    if argv and argv[0] == "gcloud":
        argv = argv[1:]
    with open(p("calls.log"), "a") as f:
        f.write(json.dumps(argv) + "\n")
    op_error = check_faults(argv)
    # Drop global flags that may appear anywhere.
    argv = [a for a in argv if a not in ("--quiet", "-q")]
    if not argv:
        fail("fake gcloud: no command", 98)
    if argv[:2] == ["auth", "print-access-token"]:
        sys.stdout.write("fake-access-token\n")
    elif argv[0] == "composer":
        composer(argv[1:], op_error)
    elif argv[0] == "storage":
        storage(argv[1:])
    else:
        fail(f"fake gcloud: unsupported command {' '.join(argv)}", 98)


if __name__ == "__main__":
    main()
