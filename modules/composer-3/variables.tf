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
