variable "config_file" {
  description = "Path to the YAML configuration file for the Composer 3 environment"
  type        = string
  default     = "configs/basic.yaml"

  validation {
    condition     = can(regex("\\.ya?ml$", var.config_file))
    error_message = "config_file must be a YAML file (.yaml or .yml)."
  }
}

variable "fallback_image_versions" {
  description = <<-EOT
    Map of environment key => Composer image version, applied ONLY to
    environments whose YAML leaves software_config.image_version unset.
    Normally left empty; the hibernation startup script
    (scripts/hibernation/composer-startup.sh) sets it so a recreated
    environment runs the same Airflow version as the snapshot it restores.
  EOT
  type        = map(string)
  default     = {}
}
