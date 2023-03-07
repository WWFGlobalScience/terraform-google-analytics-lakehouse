/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

data "google_project" "project" {
  project_id = var.project_id
}

module "project-services" {
  source                      = "terraform-google-modules/project-factory/google//modules/project_services"
  version                     = "13.0.0"
  disable_services_on_destroy = false

  project_id  = var.project_id
  enable_apis = var.enable_apis

  activate_apis = [
    "compute.googleapis.com",
    "cloudapis.googleapis.com",
    "cloudbuild.googleapis.com",
    "datacatalog.googleapis.com",
    "datalineage.googleapis.com",
    "eventarc.googleapis.com",
    "bigquerymigration.googleapis.com",
    "bigquerystorage.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "bigqueryreservation.googleapis.com",
    "bigquery.googleapis.com",
    "storage.googleapis.com",
    "storage-api.googleapis.com",
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "cloudfunctions.googleapis.com",
    "run.googleapis.com",
    "bigquerydatatransfer.googleapis.com",
    "artifactregistry.googleapis.com",
    "metastore.googleapis.com",
    "dataproc.googleapis.com",
    "dataplex.googleapis.com",
    "datacatalog.googleapis.com",
    "workflows.googleapis.com"

  ]
}

resource "time_sleep" "wait_after_apis_activate" {
  depends_on      = [module.project-services]
  create_duration = "30s"
}
resource "time_sleep" "wait_after_adding_eventarc_svc_agent" {
  depends_on = [time_sleep.wait_after_apis_activate,
    google_project_iam_member.eventarc_svg_agent
  ]
  #actually waits 180 seconds
  create_duration = "60s"
}

#random id
resource "random_id" "id" {
  byte_length = 4
}

# [START eventarc_workflows_create_serviceaccount]


resource "google_project_service_identity" "pos_eventarc_sa" {
  provider   = google-beta
  project    = module.project-services.project_id
  service    = "eventarc.googleapis.com"
  depends_on = [time_sleep.wait_after_apis_activate]
}
resource "google_project_iam_member" "eventarc_svg_agent" {
  project = module.project-services.project_id
  role    = "roles/eventarc.serviceAgent"
  member  = "serviceAccount:${google_project_service_identity.pos_eventarc_sa.email}"

  depends_on = [
    google_project_service_identity.pos_eventarc_sa
  ]
}

# Set up BigQuery resources
# # Create the BigQuery dataset
resource "google_bigquery_dataset" "gcp_lakehouse_ds" {
  project       = module.project-services.project_id
  dataset_id    = "gcp_lakehouse_ds"
  friendly_name = "My gcp_lakehouse Dataset"
  description   = "My gcp_lakehouse Dataset with tables"
  location      = var.region
  labels        = var.labels
  depends_on    = [time_sleep.wait_after_adding_eventarc_svc_agent]
}



# # Create a BigQuery connection
resource "google_bigquery_connection" "gcp_lakehouse_connection" {
  project       = module.project-services.project_id
  connection_id = "gcp_lakehouse_connection"
  location      = var.region
  friendly_name = "gcp lakehouse storage bucket connection"
  cloud_resource {}
  depends_on = [time_sleep.wait_after_adding_eventarc_svc_agent]
}

## This grants permissions to the service account of the connection created in the last step.
resource "google_project_iam_member" "connectionPermissionGrant" {
        project = module.project-services.project_id
        role = "roles/storage.objectViewer"
        member = format("serviceAccount:%s", google_bigquery_connection.gcp_lakehouse_connection.cloud_resource[0].service_account_id)
    }    

#set up workflows svg acct
resource "google_service_account" "workflows_sa" {
  project    = module.project-services.project_id
  account_id   = "workflows-sa"
  display_name = "Workflows Service Account"
}

#give workflows_sa bq access 
resource "google_project_iam_member" "workflows_sa_bq_read" {
  project = module.project-services.project_id
  role    = "roles/bigquery.dataOwner"
  member  = "serviceAccount:${google_service_account.workflows_sa.email}"

  depends_on = [
    google_service_account.workflows_sa
  ]
}

resource "google_project_iam_member" "workflows_sa_log_writer" {
  project = module.project-services.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.workflows_sa.email}"

  depends_on = [
    google_service_account.workflows_sa
  ]
}


resource "google_workflows_workflow" "workflows_bqml" {
  name            = "workflow-bqml"
  project    = module.project-services.project_id
  region          = "us-central1"
  description     = "Create BQML Model 113"
  service_account = google_service_account.workflows_sa.email
  source_contents = file("${path.module}/assets/yaml/workflow_bqml.yaml")
  depends_on      = [google_project_iam_member.workflows_sa_bq_read]
}

resource "google_workflows_workflow" "workflows_create_gcp_biglake_tables" {
  name            = "workflow-create-gcp-biglake-tables"
  project    = module.project-services.project_id
  region          = "us-central1"
  description     = "create gcp biglake tables_18"
  service_account = google_service_account.workflows_sa.email
  source_contents = file("${path.module}/assets/yaml/workflow_create_ gcp_tbl_events.yaml")
  depends_on      = [google_project_iam_member.workflows_sa_bq_read]
}

resource "google_bigquery_table" "view_ecommerce" {
  dataset_id          = google_bigquery_dataset.gcp_lakehouse_ds.dataset_id
  table_id            = "vw_ecommerce"
  project             = module.project-services.project_id
  depends_on          = [
    google_workflows_workflow.workflows_create_gcp_biglake_tables]
  deletion_protection = "false"

  view {
    query = file("${path.module}/assets/sql/view_test.sql")
    use_legacy_sql = false 
  }

}



# # Set up the provisioning bucketstorage bucket
resource "google_storage_bucket" "provisioning_bucket" {
  name                        = "gcp_gcf_source_code-${random_id.id.hex}"
  project                     = module.project-services.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy

}

# # Set up the export storage bucket
resource "google_storage_bucket" "destination_bucket" {
  name                        = "gcp-lakehouse-edw-export"
  project                     = module.project-services.project_id
  location                    = "us-central1"
  uniform_bucket_level_access = true
  force_destroy               = var.force_destroy

}


# Set up service account for the Cloud Function to execute as
resource "google_service_account" "cloud_function_service_account" {
  project      = module.project-services.project_id
  account_id   = "cloud-function-sa-${random_id.id.hex}"
  display_name = "Service Account for Cloud Function Execution"
}


resource "google_project_iam_member" "cloud_function_service_account_editor_role" {
  project = module.project-services.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.cloud_function_service_account.email}"

  depends_on = [
    google_service_account.cloud_function_service_account
  ]
}


resource "google_project_iam_member" "cloud_function_service_account_function_invoker" {
  project = module.project-services.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.cloud_function_service_account.email}"

  depends_on = [
    google_service_account.cloud_function_service_account
  ]
}


# Create a Cloud Function resource

# # Zip the function file
data "archive_file" "bigquery_external_function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/assets/bigquery-external-function"
  output_path = "${path.module}/assets/bigquery-external-function.zip"

  depends_on = [
    google_storage_bucket.provisioning_bucket
  ]
}

# # Place the cloud function code (zip file) on Cloud Storage
resource "google_storage_bucket_object" "cloud_function_zip_upload" {
  name   = "assets/bigquery-external-function.zip"
  bucket = google_storage_bucket.provisioning_bucket.name
  source = data.archive_file.bigquery_external_function_zip.output_path

  depends_on = [
    google_storage_bucket.provisioning_bucket,
    data.archive_file.bigquery_external_function_zip
  ]
}


#get gcs svc account
data "google_storage_project_service_account" "gcs_account" {
  project = module.project-services.project_id
}

resource "google_project_iam_member" "gcs_pubsub_publisher" {
  project = module.project-services.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

resource "google_project_iam_member" "gcs_run_invoker" {
  project = module.project-services.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs_account.email_address}"
}

#Create gcp cloud function
resource "google_cloudfunctions2_function" "function" {
  #provider = google-beta
  project     = module.project-services.project_id
  name        = "gcp-run-gcf-${random_id.id.hex}"
  location    = var.region
  description = "run python code that Terraform cannot currently handle..."

  build_config {
    runtime     = "python310"
    entry_point = "gcp_main"
    source {
      storage_source {
        bucket = google_storage_bucket.provisioning_bucket.name
        object = "assets/bigquery-external-function.zip"
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "256M"
    timeout_seconds    = 539
    environment_variables = {
      PROJECT_ID            = module.project-services.project_id
      DATASET_ID            = ""
      TABLE_NAME            = ""
      DESTINATION_BUCKET_ID = google_storage_bucket.destination_bucket.name
      SOURCE_BUCKET_ID      = var.bucket_name
      REGION = var.region
      CONN_NAME = google_bigquery_connection.gcp_lakehouse_connection.name
    }
    service_account_email = google_service_account.cloud_function_service_account.email
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.storage.object.v1.finalized"
    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.provisioning_bucket.name
    }
    retry_policy = "RETRY_POLICY_RETRY"
  }

  depends_on = [
    google_storage_bucket.provisioning_bucket,
    google_project_iam_member.cloud_function_service_account_editor_role,
    google_project_iam_member.eventarc_svg_agent,
    time_sleep.wait_after_adding_eventarc_svc_agent
  ]
}


resource "google_project_iam_member" "dp_worker_role_sa" {
  project    = data.google_project.project.project_id
  role       = "roles/dataproc.worker"
  member     = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
  depends_on = [module.project-services]
}

resource "google_project_iam_member" "dp_metastore_role_sa" {
  project    = data.google_project.project.project_id
  role       = "roles/metastore.admin"
  member     = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
  depends_on = [module.project-services]
}


resource "google_dataproc_cluster" "gcp_lakehouse_cluster" {
  name       = "gcp-lakehouse-cluster"
  project    = data.google_project.project.project_id
  region     = "us-central1"
  depends_on = [google_project_iam_member.dp_worker_role_sa]
  /* cluster_config {
            metastore_config         {
          dataproc_metastore_service = google_dataproc_metastore_service.gcp_lakehouse_metastore.id
        }

    }*/
}

resource "google_project_service_identity" "dataproc_sa" {
  provider   = google-beta
  project    = data.google_project.project.project_id
  service    = "dataproc.googleapis.com"
  depends_on = [google_dataproc_cluster.gcp_lakehouse_cluster]
}

#pyspark ml job

resource "google_project_iam_member" "cf_admin_to_compute_default" {
  project = module.project-services.project_id
  role    = "roles/cloudfunctions.admin"
  member  = "serviceAccount:${data.google_project.project.number}-compute@developer.gserviceaccount.com"
}


resource "google_storage_bucket_object" "startfile" {
  bucket = google_storage_bucket.provisioning_bucket.name
  name   = "startfile"
  source = "${path.module}/assets/startfile"

  depends_on = [
    google_cloudfunctions2_function.function
  ]
}

#we need to wait after file is dropped in bucket, to trigger cf, and copy data files
resource "time_sleep" "wait_after_cloud_function_creation" {
  depends_on      = [google_storage_bucket_object.startfile]
  create_duration = "15s"
}

resource "google_storage_bucket_object" "pyspark_file" {
  bucket = google_storage_bucket.provisioning_bucket.name
  name   = "sparkml.py"
  source = "${path.module}/assets/sparkml.py"

  depends_on = [
    google_cloudfunctions2_function.function
  ]

}


#dataplex
#get dataplex svc acct info
resource "google_project_service_identity" "dataplex_sa" {
  provider   = google-beta
  project    = module.project-services.project_id
  service    = "dataplex.googleapis.com"
  depends_on = [time_sleep.wait_after_adding_eventarc_svc_agent]
}

#lake
resource "google_dataplex_lake" "gcp_primary" {
  location     = var.region
  name         = "gcp-primary-lake"
  description  = "gcp primary lake"
  display_name = "gcp primary lake"

  labels = {
    gcp-lake = "exists"
  }

  project    = module.project-services.project_id
  depends_on = [time_sleep.wait_after_adding_eventarc_svc_agent]
}

#zone
resource "google_dataplex_zone" "gcp_primary_zone" {
  discovery_spec {
    enabled = true
  }

  lake     = google_dataplex_lake.gcp_primary.name
  location = var.region
  name     = "gcp-primary-zone"

  resource_spec {
    location_type = "SINGLE_REGION"
  }

  type         = "RAW"
  description  = "Zone for thelookecommerce"
  display_name = "Zone 1"
  labels       = {}
  project      = module.project-services.project_id
  depends_on   = [time_sleep.wait_after_adding_eventarc_svc_agent]
}

#give dataplex access to biglake bucket
resource "google_project_iam_member" "dataplex_bucket_access" {
  project = module.project-services.project_id
  role    = "roles/dataplex.serviceAgent"
  member  = "serviceAccount:${google_project_service_identity.dataplex_sa.email}"

  depends_on = [time_sleep.wait_after_adding_eventarc_svc_agent]
}

#asset
resource "google_dataplex_asset" "gcp_primary_asset" {
  name     = "gcp-primary-asset"
  location = var.region

  lake          = google_dataplex_lake.gcp_primary.name
  dataplex_zone = google_dataplex_zone.gcp_primary_zone.name

  discovery_spec {
    enabled = true
  }

  resource_spec {
    name = "projects/${module.project-services.project_id}/buckets/${google_storage_bucket.destination_bucket.name}"
    type = "STORAGE_BUCKET"
  }

  project    = module.project-services.project_id
  depends_on = [time_sleep.wait_after_adding_eventarc_svc_agent, google_project_iam_member.dataplex_bucket_access]
}






