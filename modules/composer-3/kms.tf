# ── KMS Key Ring ───────────────────────────────────────────────────────
# Composer requires the key in the environment's region (no multi-regional or global keys).
resource "google_kms_key_ring" "composer" {
  count = local.create_kms_key ? 1 : 0

  project  = local.project_id
  name     = local.encryption.kms_key_ring_name
  location = local.region

  depends_on = [google_project_service.required]
}

# ── KMS Crypto Key ────────────────────────────────────────────────────
resource "google_kms_crypto_key" "composer" {
  count = local.create_kms_key ? 1 : 0

  name            = local.encryption.kms_key_name
  key_ring        = google_kms_key_ring.composer[0].id
  rotation_period = local.encryption.kms_key_rotation_period
  labels          = local.labels

  lifecycle {
    prevent_destroy = true
  }
}

# ── Service agents that Composer 3 requires on the key ────────────────
# Composer 3 needs roles/cloudkms.cryptoKeyEncrypterDecrypter for the Composer service agent
# and the Cloud Storage service agent only.

resource "google_kms_crypto_key_iam_member" "composer_agent_kms" {
  count = local.encryption.enable_cmek ? 1 : 0

  crypto_key_id = local.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${local.composer_service_agent}"

  depends_on = [google_project_service_identity.composer]
}

# Reading this data source also creates the project's Cloud Storage service agent if it
# does not exist yet.
data "google_storage_project_service_account" "gcs" {
  count = local.encryption.enable_cmek ? 1 : 0

  project = local.project_id

  depends_on = [google_project_service.required]
}

resource "google_kms_crypto_key_iam_member" "gcs_agent_kms" {
  count = local.encryption.enable_cmek ? 1 : 0

  crypto_key_id = local.kms_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = data.google_storage_project_service_account.gcs[0].member
}
