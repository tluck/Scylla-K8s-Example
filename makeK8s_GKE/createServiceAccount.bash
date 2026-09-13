#!/usr/bin/env bash

source init.conf

# -s not -e: a failed `keys create` leaves a zero-byte file behind, and testing for
# mere existence makes every later run exit here without ever minting a key
if [[ -s gcs-service-account.json ]]; then
  echo "Service account json file already exists, skipping creation of service account and granting permissions to the GCS bucket"
  exit 0
fi
rm -f gcs-service-account.json

if [[ -z ${gkeServiceAccount} ]]; then
  echo "Creating the service account and granting permissions to the GCS bucket"
  gcloud iam service-accounts create gke-sa --display-name="gke-service-account"
  # init.conf resolved this before the account existed - resolve it again
  gkeServiceAccount=$(gcloud iam service-accounts list --filter="displayName:gke-service-account" --format="value(email)")
else
  echo "Service account ${gkeServiceAccount} already exists - granting permissions and minting a key"
fi

gcloud storage buckets add-iam-policy-binding gs://${gcsBucketName} \
  --role=roles/storage.objectViewer \
  --member="serviceAccount:${gkeServiceAccount}"

gcloud storage buckets add-iam-policy-binding gs://${gcsBucketName} \
  --role=roles/storage.objectCreator \
  --member="serviceAccount:${gkeServiceAccount}"

gcloud storage buckets add-iam-policy-binding gs://${gcsBucketName} \
  --role=roles/storage.objectUser \
  --member="serviceAccount:${gkeServiceAccount}"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --role="roles/storage.objectAdmin" \
  --member="serviceAccount:${gkeServiceAccount}"

# Create the json file for the SA
gcloud iam service-accounts keys create gcs-service-account.json \
  --iam-account=${gkeServiceAccount}

# A failed `keys create` leaves a zero-byte file behind - never leave one around.
# That is what made every later run of this script exit early without a key, and
# what made deployScylla.bash mount empty credentials into the agents.
if [[ ! -s gcs-service-account.json ]] || ! jq -e '.client_email' gcs-service-account.json > /dev/null 2>&1; then
  printf "* * * Error - failed to create a usable gcs-service-account.json for %s\n" "${gkeServiceAccount}" >&2
  rm -f gcs-service-account.json
  exit 1
fi
printf "Created gcs-service-account.json for %s\n" "$(jq -r .client_email gcs-service-account.json)"

# Link the key into the repo root so deployScylla.bash finds it (target is
# resolved relative to the link's location — the parent dir — hence the prefix)
ln -sf makeK8s_GKE/gcs-service-account.json ../gcs-service-account.json
