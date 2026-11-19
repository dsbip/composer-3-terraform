variable "environment_key" {
  description = "Name key for this environment from the YAML environments map"
  type        = string
}

variable "config" {
  description = "Per-environment configuration from YAML (may be null or {} — every field is optional)"
  type        = any
  default     = {}
}

variable "global_config" {
  description = "Global configuration defaults shared across all environments"
  type        = any
  default     = {}
}
