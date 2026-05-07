import yaml
import sys
import os

os.chdir(os.path.join(os.path.dirname(__file__), ".."))

configs = {
    "basic": "configs/basic.yaml",
    "development": "configs/development.yaml",
    "production": "configs/production.yaml",
    "private-ip": "configs/private-ip.yaml",
    "multi-environment": "configs/multi-environment.yaml",
}

valid_sizes = [
    "ENVIRONMENT_SIZE_SMALL",
    "ENVIRONMENT_SIZE_MEDIUM",
    "ENVIRONMENT_SIZE_LARGE",
]
valid_resilience = ["STANDARD_RESILIENCE", "HIGH_RESILIENCE"]

all_passed = True

for name, path in configs.items():
    with open(path) as f:
        cfg = yaml.safe_load(f)

    errors = []

    if "project_id" not in cfg:
        errors.append("  missing global project_id")

    envs = cfg.get("environments", {})
    if not envs:
        errors.append("  no environments defined")

    for env_key, env_cfg in envs.items():
        prefix = "  [" + env_key + "] "
        if env_cfg is None:
            env_cfg = {}

        size = env_cfg.get("environment_size", "ENVIRONMENT_SIZE_SMALL")
        if size not in valid_sizes:
            errors.append(prefix + "invalid environment_size: " + size)

        resilience = env_cfg.get("resilience_mode", "STANDARD_RESILIENCE")
        if resilience not in valid_resilience:
            errors.append(prefix + "invalid resilience_mode: " + resilience)

        sw = env_cfg.get("software_config", {})
        img = sw.get("image_version")
        if img is not None and not img.startswith("composer-3"):
            errors.append(prefix + "image_version must start with composer-3: " + img)

    if errors:
        print(name + ": FAILED")
        for e in errors:
            print(e)
        all_passed = False
    else:
        env_list = ", ".join(envs.keys())
        print(name + ": PASSED (" + str(len(envs)) + " env: " + env_list + ")")

if not all_passed:
    sys.exit(1)
print("\nAll config files validated successfully.")
