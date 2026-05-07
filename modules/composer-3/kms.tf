# ── KMS Key Ring ───────────────────────────────────────────────────────
resource "google_kms_key_ring" "composer" {
  count = local.encryption.enable_cmek && local.encryption.existing_kms_key == null ? 1 : 0

  project  = local.project_id
  name     = local.encryption.kms_key_ring_name
  location = local.region

  depends_on = [google_project_service.required]
}

# ── KMS Crypto Key ────────────────────────────────────────────────────
resource "google_kms_crypto_key" "composer" {
  count = local.encryption.enable_cmek && local.encryption.existing_kms_key == null ? 1 : 0

  name            = local.encryption.kms_key_name
  key_ring        = google_kms_key_ring.composer[0].id
  rotation_period = local.encryption.kms_key_rotation_period

  lifecycle {
    prevent_destroy = true
  }
}

# ── Grant Composer service agent access to the KMS key ─────────────────
resource "google_kms_crypto_key_iam_member" "composer_agent_kms" {
  count = local.encryption.enable_cmek ? 1 : 0

  crypto_key_id = local.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@cloudcomposer-accounts.iam.gserviceaccount.com"
}

# ── Grant Artifact Registry service agent KMS access ───────────────────
resource "google_kms_crypto_key_iam_member" "artifact_registry_kms" {
  count = local.encryption.enable_cmek ? 1 : 0

  crypto_key_id = local.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-artifactregistry.iam.gserviceaccount.com"
}

# ── Grant GCS service agent KMS access ─────────────────────────────────
resource "google_kms_crypto_key_iam_member" "gcs_kms" {
  count = local.encryption.enable_cmek ? 1 : 0

  crypto_key_id = local.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.this.number}@gs-project-accounts.iam.gserviceaccount.com"
}
