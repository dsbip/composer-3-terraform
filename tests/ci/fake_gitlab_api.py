#!/usr/bin/env python3
"""Stateful, in-memory fake of the GitLab REST API v4 endpoints used by
scripts/ci/create-hibernation-schedules.sh (for tests/ci/schedules.bats).

Endpoints (under /api/v4, PRIVATE-TOKEN header required, else 401):

  GET    /projects/:id                                 (default_branch)
  GET    /projects/:id/pipeline_schedules              (page / per_page)
  POST   /projects/:id/pipeline_schedules
  GET    /projects/:id/pipeline_schedules/:sid         (incl. "variables")
  PUT    /projects/:id/pipeline_schedules/:sid
  POST   /projects/:id/pipeline_schedules/:sid/variables
  PUT    /projects/:id/pipeline_schedules/:sid/variables/:key
  DELETE /projects/:id/pipeline_schedules/:sid/variables/:key
  GET    /projects/:id/resource_groups/:key
  PUT    /projects/:id/resource_groups/:key            (process_mode)

:id is the numeric project id or the URL-encoded path ("group%2Fproject");
an unencoded path ("group/project") does not match, as on GitLab.
Request bodies may be application/x-www-form-urlencoded or JSON. Lists are
paginated like GitLab (default per_page 20, max 100) with X-Page,
X-Per-Page, X-Next-Page, X-Prev-Page, X-Total and X-Total-Pages headers.

Every API request is appended to --log as one JSON object per line:
  {"method", "path", "query", "form", "status", "auth"}
("auth" is whether the token matched; the token itself is never logged).

Test control endpoints (no auth, not logged):
  GET  /__control/state   full state as JSON (schedules incl. variables)
  POST /__control/state   replace the state (same shape as --seed)

Seed / state shape:
  {"project": {"id": 42, "path": "group/project", "default_branch": "main"},
   "schedules": [{"id": 1, "description": "...", "ref": "main",
                  "cron": "...", "cron_timezone": "UTC", "active": true,
                  "variables": [{"key": "K", "value": "V"}]}],
   "resource_groups": [{"key": "composer-hibernation-dev",
                        "process_mode": "unordered"}],
   "pagination_headers": true}

Usage:
  fake_gitlab_api.py --token TOKEN --log FILE [--seed FILE]
                     [--port 0] [--ready-fifo FIFO]
The bound port is written to --ready-fifo (or stdout) once listening.
"""

import argparse
import copy
import datetime
import json
import re
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

API = "/api/v4"
CRON_FIELD = re.compile(r"^[0-9A-Za-z*/,?#-]+$")
PROCESS_MODES = ("unordered", "oldest_first", "newest_first", "newest_ready_first")
TZ_NAME = re.compile(r"^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$")
TZ_AREAS = {"Africa", "America", "Antarctica", "Arctic", "Asia", "Atlantic", "Australia",
            "Europe", "Indian", "Pacific", "Etc"}

LOCK = threading.Lock()
STATE = {}
CONFIG = {}


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def load_state(seed):
    seed = copy.deepcopy(seed or {})
    project = seed.get("project") or {}
    state = {
        "project": {"id": int(project.get("id", 42)), "path": project.get("path", "group/composer-3-terraform"),
                    "default_branch": project.get("default_branch", "main")},
        "schedules": [],
        "resource_groups": [],
        "pagination_headers": bool(seed.get("pagination_headers", True)),
    }
    for s in seed.get("schedules", []):
        state["schedules"].append(normalise_schedule(s))
    for g in seed.get("resource_groups", []):
        state["resource_groups"].append(
            {
                "id": g.get("id", len(state["resource_groups"]) + 1),
                "key": g["key"],
                "process_mode": g.get("process_mode", "unordered"),
                "created_at": now(),
                "updated_at": now(),
            }
        )
    ids = [s["id"] for s in state["schedules"]]
    state["next_id"] = max(ids, default=0) + 1
    return state


def normalise_schedule(s):
    out = {
        "id": int(s["id"]),
        "description": s.get("description", ""),
        "ref": s.get("ref", "main"),
        "cron": s.get("cron", "0 1 * * *"),
        "cron_timezone": s.get("cron_timezone", "UTC"),
        "next_run_at": "2030-01-01T00:00:00.000Z",
        "active": bool(s.get("active", True)),
        "created_at": now(),
        "updated_at": now(),
        "owner": s.get("owner", {"id": 1, "username": "ci-bot", "name": "CI bot"}),
        "variables": [],
    }
    for v in s.get("variables", []):
        out["variables"].append(
            {"key": v["key"], "value": v.get("value", ""), "variable_type": v.get("variable_type", "env_var")}
        )
    return out


def public_schedule(s, with_variables):
    out = {k: v for k, v in s.items() if k != "variables"}
    if with_variables:
        out["variables"] = copy.deepcopy(s["variables"])
    return out


def truthy(value):
    return str(value).lower() in ("true", "1", "yes")


def cron_ok(cron):
    fields = cron.split()
    return len(fields) == 5 and all(CRON_FIELD.match(f) for f in fields)


def timezone_ok(tz):
    """IANA-style "Area/Location" names (or UTC). Rule-based on purpose, so
    the result does not depend on the image having a tz database."""
    if tz in ("UTC", "Etc/UTC"):
        return True
    return bool(TZ_NAME.match(tz)) and tz.split("/", 1)[0] in TZ_AREAS


class Handler(BaseHTTPRequestHandler):
    server_version = "fake-gitlab/1.0"

    # ── plumbing ────────────────────────────────────────────────────────
    def log_message(self, fmt, *args):  # keep test output quiet
        pass

    def _raw_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _body(self):
        """Request parameters as {name: str} (form-encoded or JSON body)."""
        raw = self._raw_body()
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip()
        if not raw:
            return {}
        if ctype == "application/json":
            data = json.loads(raw.decode())
            return {k: v if isinstance(v, str) else json.dumps(v) for k, v in data.items()}
        return {k: v[-1] for k, v in urllib.parse.parse_qs(raw.decode(), keep_blank_values=True).items()}

    def _send(self, status, body=None, headers=None):
        payload = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def _record(self, method, path, query, form, status, auth):
        entry = {"method": method, "path": path, "query": query, "form": form, "status": status, "auth": auth}
        with open(CONFIG["log"], "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")
            f.flush()

    def _handle(self, method):
        split = urllib.parse.urlsplit(self.path)
        raw_path = split.path
        query = {k: v[-1] for k, v in urllib.parse.parse_qs(split.query, keep_blank_values=True).items()}

        if raw_path == "/__control/state":
            with LOCK:
                if method == "GET":
                    return self._send(200, STATE)
                if method == "POST":
                    seed = json.loads(self._raw_body().decode() or "{}")
                    STATE.clear()
                    STATE.update(load_state(seed))
                    return self._send(204)
            return self._send(405, {"error": "405 Method Not Allowed"})

        form = self._body() if method in ("POST", "PUT", "DELETE") else {}
        params = dict(query)
        params.update(form)
        auth = self.headers.get("PRIVATE-TOKEN") == CONFIG["token"]
        with LOCK:
            if not auth:
                status, body, headers = 401, {"message": "401 Unauthorized"}, {}
            else:
                status, body, headers = self._route(method, raw_path, params)
            # Record before answering, so the log is complete once curl returns.
            self._record(method, raw_path, query, form, status, auth)
        self._send(status, body, headers)

    def do_GET(self):  # noqa: N802
        self._handle("GET")

    def do_POST(self):  # noqa: N802
        self._handle("POST")

    def do_PUT(self):  # noqa: N802
        self._handle("PUT")

    def do_DELETE(self):  # noqa: N802
        self._handle("DELETE")

    # ── routing ─────────────────────────────────────────────────────────
    def _project_matches(self, ident):
        project = STATE["project"]
        return ident == str(project["id"]) or ident == urllib.parse.quote(project["path"], safe="")

    def _route(self, method, raw_path, params):
        not_found = (404, {"message": "404 Not found"}, {})
        if not raw_path.startswith(API + "/projects/"):
            return 404, {"error": "404 Not Found"}, {}
        rest = raw_path[len(API + "/projects/"):]
        ident, _, rest = rest.partition("/")
        if not self._project_matches(ident):
            return 404, {"message": "404 Project Not Found"}, {}
        parts = rest.split("/") if rest else []

        if not parts and method == "GET":
            project = STATE["project"]
            return 200, {"id": project["id"], "path_with_namespace": project["path"],
                         "default_branch": project["default_branch"]}, {}

        if parts[:1] == ["pipeline_schedules"]:
            if len(parts) == 1:
                if method == "GET":
                    return self._list_schedules(params)
                if method == "POST":
                    return self._create_schedule(params)
            elif len(parts) >= 2:
                sched = self._find_schedule(parts[1])
                if sched is None:
                    return 404, {"message": "404 Pipeline Schedule Not Found"}, {}
                if len(parts) == 2:
                    if method == "GET":
                        return 200, public_schedule(sched, True), {}
                    if method == "PUT":
                        return self._update_schedule(sched, params)
                if len(parts) == 3 and parts[2] == "variables" and method == "POST":
                    return self._create_variable(sched, params)
                if len(parts) == 4 and parts[2] == "variables":
                    key = urllib.parse.unquote(parts[3])
                    if method == "PUT":
                        return self._update_variable(sched, key, params)
                    if method == "DELETE":
                        return self._delete_variable(sched, key)
            return not_found

        if parts[:1] == ["resource_groups"] and len(parts) == 2:
            key = urllib.parse.unquote(parts[1])
            group = next((g for g in STATE["resource_groups"] if g["key"] == key), None)
            if group is None:
                return not_found
            if method == "GET":
                return 200, group, {}
            if method == "PUT":
                mode = params.get("process_mode")
                if mode is not None:
                    if mode not in PROCESS_MODES:
                        return 400, {"error": "process_mode does not have a valid value"}, {}
                    group["process_mode"] = mode
                    group["updated_at"] = now()
                return 200, group, {}
        return not_found

    def _find_schedule(self, sid):
        if not sid.isdigit():
            return None
        return next((s for s in STATE["schedules"] if s["id"] == int(sid)), None)

    # ── schedules ───────────────────────────────────────────────────────
    def _list_schedules(self, params):
        try:
            page = max(int(params.get("page", 1)), 1)
            per_page = min(max(int(params.get("per_page", 20)), 1), 100)
        except ValueError:
            return 400, {"error": "page is invalid"}, {}
        items = sorted(STATE["schedules"], key=lambda s: s["id"])
        scope = params.get("scope")
        if scope == "active":
            items = [s for s in items if s["active"]]
        elif scope == "inactive":
            items = [s for s in items if not s["active"]]
        total = len(items)
        pages = max((total + per_page - 1) // per_page, 1)
        chunk = items[(page - 1) * per_page: page * per_page]
        headers = {}
        if STATE.get("pagination_headers", True):
            headers = {
                "X-Page": str(page),
                "X-Per-Page": str(per_page),
                "X-Next-Page": str(page + 1) if page < pages else "",
                "X-Prev-Page": str(page - 1) if page > 1 else "",
                "X-Total": str(total),
                "X-Total-Pages": str(pages),
            }
        return 200, [public_schedule(s, False) for s in chunk], headers

    def _validate_schedule(self, sched):
        errors = {}
        if not sched["description"]:
            errors["description"] = ["can't be blank"]
        if not sched["ref"]:
            errors["ref"] = ["can't be blank"]
        if not cron_ok(sched["cron"]):
            errors["cron"] = [" is invalid syntax"]
        if not timezone_ok(sched["cron_timezone"]):
            errors["cron_timezone"] = [" is invalid syntax"]
        return errors

    def _create_schedule(self, params):
        missing = [k for k in ("description", "ref", "cron") if k not in params]
        if missing:
            return 400, {"error": f"{', '.join(missing)} is missing"}, {}
        sched = normalise_schedule(
            {
                "id": STATE["next_id"],
                "description": params["description"],
                "ref": params["ref"],
                "cron": params["cron"],
                "cron_timezone": params.get("cron_timezone", "UTC"),
                "active": truthy(params.get("active", "true")),
                "owner": {"id": 7, "username": "token-owner", "name": "Token owner"},
            }
        )
        errors = self._validate_schedule(sched)
        if errors:
            return 400, {"message": errors}, {}
        STATE["next_id"] += 1
        STATE["schedules"].append(sched)
        return 201, public_schedule(sched, True), {}

    def _update_schedule(self, sched, params):
        candidate = copy.deepcopy(sched)
        for key in ("description", "ref", "cron", "cron_timezone"):
            if key in params:
                candidate[key] = params[key]
        if "active" in params:
            candidate["active"] = truthy(params["active"])
        errors = self._validate_schedule(candidate)
        if errors:
            return 400, {"message": errors}, {}
        candidate["updated_at"] = now()
        sched.clear()
        sched.update(candidate)
        return 200, public_schedule(sched, True), {}

    # ── schedule variables ──────────────────────────────────────────────
    def _create_variable(self, sched, params):
        key = params.get("key")
        if not key or "value" not in params:
            return 400, {"error": "key is missing" if not key else "value is missing"}, {}
        if not re.match(r"^[A-Za-z0-9_]+$", key):
            return 400, {"message": {"key": ["can contain only letters, digits and '_'."]}}, {}
        if any(v["key"] == key for v in sched["variables"]):
            return 400, {"message": {"key": [f"({key}) has already been taken"]}}, {}
        var = {"key": key, "value": params["value"], "variable_type": params.get("variable_type", "env_var")}
        sched["variables"].append(var)
        return 201, var, {}

    def _update_variable(self, sched, key, params):
        var = next((v for v in sched["variables"] if v["key"] == key), None)
        if var is None:
            return 404, {"message": "404 Variable Not Found"}, {}
        if "value" in params:
            var["value"] = params["value"]
        if "variable_type" in params:
            var["variable_type"] = params["variable_type"]
        return 200, var, {}

    def _delete_variable(self, sched, key):
        var = next((v for v in sched["variables"] if v["key"] == key), None)
        if var is None:
            return 404, {"message": "404 Variable Not Found"}, {}
        sched["variables"].remove(var)
        return 202, var, {}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--token", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--seed")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-fifo")
    args = parser.parse_args()

    seed = None
    if args.seed:
        with open(args.seed, encoding="utf-8") as f:
            seed = json.load(f)
    STATE.update(load_state(seed))
    CONFIG.update({"token": args.token, "log": args.log})
    open(args.log, "a", encoding="utf-8").close()

    server = HTTPServer((args.host, args.port), Handler)
    port = server.server_address[1]
    if args.ready_fifo:
        with open(args.ready_fifo, "w", encoding="utf-8") as f:
            f.write(f"{port}\n")
    else:
        print(port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
