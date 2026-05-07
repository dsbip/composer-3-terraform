terraform {
  required_version = ">= 1.2.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0.0"
    }
  }
}

provider "google" {
  project = local.global_config.project_id
  region  = local.global_config.region
}

provider "google-beta" {
  project = local.global_config.project_id
  region  = local.global_config.region
}
