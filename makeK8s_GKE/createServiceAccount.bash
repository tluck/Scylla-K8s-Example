#!/usr/bin/env bash

source init.conf

# if the account doesnt exist
# gcloud iam service-accounts create gke-sa --display-name="gke-service-account"

gcloud storage buckets add-iam-policy-binding gs://${gcpBucketName} \
  --role=roles/storage.objectViewer \
  --member="serviceAccount:${gkeServiceAccount}"

gcloud storage buckets add-iam-policy-binding gs://${gcpBucketName} \
  --role=roles/storage.objectCreator \
  --member="serviceAccount:${gkeServiceAccount}"

gcloud storage buckets add-iam-policy-binding gs://${gcpBucketName} \
  --role=roles/storage.objectUser \
  --member="serviceAccount:${gkeServiceAccount}"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --role="roles/storage.objectAdmin" \
  --member="serviceAccount:${gkeServiceAccount}"

# Create the json file for the SA
gcloud iam service-accounts keys create gcs-service-account.json \
  --iam-account=${gkeServiceAccount}

