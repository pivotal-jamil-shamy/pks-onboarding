#!/bin/bash

set -eu

CLUSTER_LIST=""

function yaml2json() {
  ruby -ryaml -rjson -e \
    'puts JSON.pretty_generate(YAML.load(ARGF))' $*
}

get_current_pks_clusters() {
  echo "Login to PKS API [$PCF_PKS_API]"
  pks login -a "$PCF_PKS_API" -u "$PKS_CLI_USER" -p "$PKS_CLI_PASSWORD" --skip-ssl-validation # TBD --ca-cert CERT-PATH
  CLUSTER_LIST=$(pks clusters --json | jq -rc '.[].name')
}

delete_cluster() {
  PKS_CLUSTER_NAME="$1"
  echo "Login to PKS API [$PCF_PKS_API]"
  pks login -a "$PCF_PKS_API" -u "$PKS_CLI_USER" -p "$PKS_CLI_PASSWORD" --skip-ssl-validation # TBD --ca-cert CERT-PATH
  pks cluster "$PKS_CLUSTER_NAME"

  echo "Deleting PKS cluster [$PKS_CLUSTER_NAME]..."
  pks delete-cluster --non-interactive "$PKS_CLUSTER_NAME" --wait

  cluster_exists=$(pks cluster "$PKS_CLUSTER_NAME" --json | jq -rc '.name')

  if [[ "$cluster_exists" == "" ]]; then
    echo "Successfully deleted cluster [$PKS_CLUSTER_NAME]"
    echo "Current list of PKS clusters:"
    pks clusters --json
  else
    last_action_description=$(pks cluster "$PKS_CLUSTER_NAME" --json | jq -rc '.last_action_description')
    echo "Error: Error deleting cluster [$PKS_CLUSTER_NAME], last_action_state=[$cluster_state], last_action_description=[$last_action_description]"
    # exit 1
  fi
}

get_current_pks_clusters

for cluster in $CLUSTER_LIST; do
  if [[ -d pks-onboarding-repo/pks/$PKS_ENV/$cluster ]]; then
    echo "$cluster specification exists in repo, skipping the delete"
  else
    delete_cluster $cluster
  fi
done
