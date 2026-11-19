variable "environment_key" {
  description = "Name key for this environment from the YAML environments map"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment_key))
    error_message = "environment_key must start with a lowercase letter and contain only lowercase letters, numbers, and hyphens."
  }
}

variable "config" {
  description = "Per-environment configuration from YAML (all fields optional with sensible defaults)"
  type        = any
  default     = {}
}

variable "global_config" {
  description = "Global configuration defaults shared across all environments"
  type        = any
  default     = {}
}

variable "fallback_image_version" {
  description = "Image version used only when the YAML leaves software_config.image_version unset (set by the hibernation startup script to restore on the snapshot's Airflow version). null = let GCP pick."
  type        = string
  default     = null

  validation {
    condition     = var.fallback_image_version == null || can(regex("^composer-3-airflow-[0-9]+(\\.[0-9]+){0,2}(-build\\.[0-9]+)?$", var.fallback_image_version))
    error_message = "fallback_image_version must look like composer-3-airflow-X.Y.Z (optionally with -build.N)."
  }
}
