variable "config_file" {
  description = "Path to the YAML configuration file for the Composer 3 environment"
  type        = string
  default     = "configs/basic.yaml"

  validation {
    condition     = can(regex("\\.ya?ml$", var.config_file))
    error_message = "config_file must be a YAML file (.yaml or .yml)."
  }
}
