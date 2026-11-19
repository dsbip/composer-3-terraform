# Real Terraform plan fixtures

Rendered by Terraform 1.17.2 with the hashicorp/google(-beta) 7.31.0 providers
against a converged state of `configs/hib.yaml`-style environments
(`composer-dev`, `composer-test`), using `-refresh=false` and
`tests/hibernation/tools/stub_google_api.py` (see `helpers/world.bash`).
Trimmed with `jq 'del(.prior_state, .configuration, .planned_values, ...)'`.

| File | Command (abridged) |
|---|---|
| destroy-targeted-one | `plan -destroy -target=module.composer["composer-dev"].google_composer_environment.this` |
| destroy-targeted-two | same, both environments |
| destroy-untargeted-module | `plan -destroy -target=module.composer["composer-dev"]` (would delete the whole module) |
| destroy-typo-target | `plan -destroy -target=module.composer["composer-dve"]...` (no `resource_changes` key at all) |
| replace-module-target | `plan -target=module.composer["composer-dev"] -replace=...google_composer_environment.this` |
| create-module-target | composer-test env absent from state, `plan -target=module.composer["composer-test"]` |
| create-resource-target-leak | as above, a pending IAM role change for composer-dev, resource-level target — leaks composer-dev's IAM change |
| create-module-target-pending-change | same pending change, module-instance target — no leak |
