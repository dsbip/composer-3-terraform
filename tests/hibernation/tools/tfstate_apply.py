#!/usr/bin/env python3
"""Simulates `terraform apply` for the hibernation test-suite.

Reads a plan rendered by REAL Terraform (`terraform show -json PLAN`) and
applies its resource_changes to a Terraform state file (format v4) without
calling any cloud API: deletes drop instances, creates/updates write the
planned values plus plausible values for the computed attributes that other
resources reference (ids, emails, self links, Composer bucket/prefix).

Usage: tfstate_apply.py PLAN_JSON STATE_FILE [--schema SCHEMA_JSON] [--composer-out FILE]
  --schema       output of `terraform providers schema -json`; computed
                 attributes still unknown after the plan get a typed empty
                 value so a re-plan converges to "No changes"
  --composer-out writes a JSON list of Composer environment changes
  ({action, address, name, project, region, image_version}) so the fake gcloud
  world can be updated consistently.
"""
import argparse
import hashlib
import json
import os
import re
import uuid

PROVIDERS = {
    "google_composer_environment": 'provider["registry.terraform.io/hashicorp/google-beta"]',
}
DEFAULT_PROVIDER = 'provider["registry.terraform.io/hashicorp/google"]'


def split_address(address):
    """module.composer["k"].type.name[idx] -> (module, type, name, index_key)."""
    m = re.match(r'^(?P<module>(?:module\.[^.\[]+(?:\["[^"]*"\])?\.)*)(?P<type>[a-z0-9_]+)\.(?P<name>[a-zA-Z0-9_-]+)(?:\[(?P<idx>[^\]]+)\])?$', address)
    if not m:
        raise ValueError(f"cannot parse address {address}")
    module = m.group("module").rstrip(".") or None
    idx = m.group("idx")
    if idx is not None:
        idx = json.loads(idx) if idx.startswith('"') else int(idx)
    return module, m.group("type"), m.group("name"), idx


def short_hash(text):
    return hashlib.sha256(text.encode()).hexdigest()[:8]


def fill_computed(rtype, v):
    """Adds the computed attributes the module/outputs reference."""
    p = v.get("project") or "proj"
    if rtype == "google_service_account":
        email = f'{v["account_id"]}@{p}.iam.gserviceaccount.com'
        v.update(email=email, id=f"projects/{p}/serviceAccounts/{email}",
                 name=f"projects/{p}/serviceAccounts/{email}", member=f"serviceAccount:{email}",
                 unique_id="1" + short_hash(email))
    elif rtype == "google_compute_network":
        v.update(id=f'projects/{p}/global/networks/{v["name"]}',
                 self_link=f'https://www.googleapis.com/compute/v1/projects/{p}/global/networks/{v["name"]}')
    elif rtype == "google_compute_subnetwork":
        v.update(id=f'projects/{p}/regions/{v["region"]}/subnetworks/{v["name"]}',
                 self_link=f'https://www.googleapis.com/compute/v1/projects/{p}/regions/{v["region"]}/subnetworks/{v["name"]}')
    elif rtype == "google_composer_environment":
        name, region = v["name"], v["region"]
        bucket = f"{region}-{name}-{short_hash(name + str(uuid.uuid4()))}-bucket"
        v["id"] = f"projects/{p}/locations/{region}/environments/{name}"
        cfg = (v.get("config") or [{}])[0]
        cfg.update(dag_gcs_prefix=f"gs://{bucket}/dags", airflow_uri=f"https://{short_hash(name)}-dot-{region}.composer.googleusercontent.com",
                   gke_cluster="")
        sw = (cfg.get("software_config") or [{}])[0]
        if not sw.get("image_version"):
            # What GCP would pick when the YAML leaves image_version unset.
            sw["image_version"] = os.environ.get("FAKE_DEFAULT_IMAGE", "composer-3-airflow-2.10.5-build.20")
        cfg["software_config"] = [sw]
        v["config"] = [cfg]
        if not v.get("storage_config"):
            v["storage_config"] = [{"bucket": bucket}]
    elif "id" not in v or v.get("id") is None:
        v["id"] = f"{rtype}/{short_hash(json.dumps(v, sort_keys=True))}"
    return v


def empty_for(type_):
    if isinstance(type_, list):
        kind = type_[0]
        return {"list": [], "set": [], "map": {}, "object": {}}.get(kind, None)
    return {"string": "", "number": 0, "bool": False}.get(type_, None)


def resolve_unknowns(after, unknown, block):
    """Fills attributes marked unknown in after_unknown using schema types."""
    if not isinstance(unknown, dict) or block is None:
        return after
    attrs = block.get("attributes", {})
    blocks = block.get("block_types", {})
    for key, flag in unknown.items():
        if flag is True and after.get(key) is None:
            if key in attrs:
                after[key] = empty_for(attrs[key]["type"])
            elif key in blocks:
                after[key] = []
        elif isinstance(flag, list) and key in blocks and isinstance(after.get(key), list):
            for i, sub_unknown in enumerate(flag):
                if i < len(after[key]) and isinstance(after[key][i], dict):
                    resolve_unknowns(after[key][i], sub_unknown, blocks[key]["block"])
    return after


def schema_for(schema, rtype):
    if not schema:
        return None
    for prov in schema.get("provider_schemas", {}).values():
        rs = prov.get("resource_schemas", {}).get(rtype)
        if rs:
            return rs["block"]
    return None


def schema_version_for(schema, rtype):
    if not schema:
        return 0
    for prov in schema.get("provider_schemas", {}).values():
        rs = prov.get("resource_schemas", {}).get(rtype)
        if rs:
            return rs.get("version", 0)
    return 0


def find_resource(state, module, rtype, name):
    for r in state["resources"]:
        if r.get("module") == module and r["type"] == rtype and r["name"] == name and r["mode"] == "managed":
            return r
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("plan_json")
    ap.add_argument("state_file")
    ap.add_argument("--composer-out")
    ap.add_argument("--schema")
    a = ap.parse_args()
    schema = json.load(open(a.schema)) if a.schema else None

    plan = json.load(open(a.plan_json))
    if os.path.exists(a.state_file) and os.path.getsize(a.state_file) > 0:
        state = json.load(open(a.state_file))
    else:
        state = {"version": 4, "terraform_version": plan.get("terraform_version", "1.17.2"), "serial": 0,
                 "lineage": str(uuid.uuid4()), "outputs": {}, "resources": [], "check_results": None}

    composer_events = []
    for rc in plan.get("resource_changes", []):
        if rc.get("mode") != "managed":
            continue
        actions = rc["change"]["actions"]
        if actions in (["no-op"], ["read"]):
            continue
        module, rtype, name, idx = split_address(rc["address"])
        res = find_resource(state, module, rtype, name)
        if "delete" in actions and res is not None:
            res["instances"] = [i for i in res["instances"] if i.get("index_key") != idx]
            if not res["instances"]:
                state["resources"].remove(res)
            res = find_resource(state, module, rtype, name)
            if rtype == "google_composer_environment" and actions == ["delete"]:
                before = rc["change"]["before"] or {}
                composer_events.append({"action": "delete", "address": rc["address"], "name": before.get("name"),
                                        "project": before.get("project"), "region": before.get("region")})
        if "create" in actions or "update" in actions:
            after = dict(rc["change"]["after"] or {})
            prior = None
            if res is not None:
                for i in res["instances"]:
                    if i.get("index_key") == idx:
                        prior = i
            if prior is not None and "update" in actions:
                merged = dict(prior["attributes"])
                merged.update({k: v for k, v in after.items() if v is not None})
                after = merged
            else:
                after = fill_computed(rtype, after)
            resolve_unknowns(after, rc["change"].get("after_unknown") or {}, schema_for(schema, rtype))
            inst = {"schema_version": schema_version_for(schema, rtype), "attributes": after,
                    "sensitive_attributes": []}
            if idx is not None:
                inst["index_key"] = idx
            if res is None:
                res = {"module": module, "mode": "managed", "type": rtype, "name": name,
                       "provider": PROVIDERS.get(rtype, DEFAULT_PROVIDER), "instances": []}
                if module is None:
                    del res["module"]
                state["resources"].append(res)
            res["instances"] = [i for i in res["instances"] if i.get("index_key") != idx] + [inst]
            if rtype == "google_composer_environment" and "create" in actions:
                sw = after["config"][0]["software_config"][0]
                composer_events.append({"action": "create", "address": rc["address"], "name": after["name"],
                                        "project": after["project"], "region": after["region"],
                                        "image_version": sw["image_version"],
                                        "service_account": (after["config"][0].get("node_config") or [{}])[0].get("service_account"),
                                        "bucket": after["storage_config"][0]["bucket"],
                                        "dag_gcs_prefix": after["config"][0]["dag_gcs_prefix"]})
    state["serial"] = state.get("serial", 0) + 1
    json.dump(state, open(a.state_file, "w"), indent=1)
    if a.composer_out:
        json.dump(composer_events, open(a.composer_out, "w"), indent=1)


if __name__ == "__main__":
    main()
