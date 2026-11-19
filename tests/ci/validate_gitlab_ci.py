#!/usr/bin/env python3
"""Validates GitLab CI YAML files against GitLab's official CI JSON schema.

The schema is downloaded once into tests/ci/.cache/ (git-ignored). `!reference`
tags are loaded as plain lists, like GitLab's own editor does.

Usage: validate_gitlab_ci.py FILE.yml [FILE.yml ...]
Exit: 0 valid, 1 invalid, 77 schema unavailable (offline) — treated as skip.
"""
import json
import os
import sys
import urllib.request

try:
    import yaml
except ImportError:  # pragma: no cover
    print("SKIP: PyYAML not installed")
    sys.exit(77)

SCHEMA_URL = "https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/assets/javascripts/editor/schema/ci.json"
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache", "gitlab-ci-schema.json")


class Loader(yaml.SafeLoader):
    pass


Loader.add_constructor("!reference", lambda loader, node: loader.construct_sequence(node))


def schema():
    if not os.path.exists(CACHE):
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        try:
            with urllib.request.urlopen(SCHEMA_URL, timeout=30) as r:
                data = r.read()
            json.loads(data)
        except Exception as exc:  # offline / proxy
            print(f"SKIP: cannot download the GitLab CI schema ({exc})")
            sys.exit(77)
        with open(CACHE, "wb") as f:
            f.write(data)
    with open(CACHE) as f:
        return json.load(f)


def main(paths):
    try:
        import jsonschema
    except ImportError:
        print("SKIP: python jsonschema not installed (pip install jsonschema)")
        return 77
    validator = jsonschema.Draft7Validator(schema())
    rc = 0
    for path in paths:
        with open(path) as fh:
            data = yaml.load(fh, Loader=Loader)
        errors = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
        for e in errors:
            rc = 1
            print(f"{path}: {'/'.join(map(str, e.path)) or '<root>'}: {e.message}")
        if not errors:
            print(f"{path}: OK")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
