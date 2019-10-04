#!/bin/bash

set -e

function yaml2json() {
  ruby -ryaml -rjson -e \
    'puts JSON.pretty_generate(YAML.load(ARGF))' $*
}

create_pks_cluster() {
  PKS_CLUSTER_NAME="$1"
  PKS_CLUSTER_MASTER_HOSTNAME="$2"
  PKS_SERVICE_PLAN_NAME="$3"
  PKS_CLUSTER_NUMBER_OF_WORKERS="$4"

  echo "Login to PKS API [$PCF_PKS_API]"
  pks login -a "$PCF_PKS_API" -u "$PKS_CLI_USER" -p "$PKS_CLI_PASSWORD" --skip-ssl-validation # TBD --ca-cert CERT-PATH

  echo "Creating PKS cluster [$PKS_CLUSTER_NAME], master node hostname [$PKS_CLUSTER_MASTER_HOSTNAME], plan [$PKS_SERVICE_PLAN_NAME], number of workers [$PKS_CLUSTER_NUMBER_OF_WORKERS]"
  pks create-cluster "$PKS_CLUSTER_NAME" --external-hostname "$PKS_CLUSTER_MASTER_HOSTNAME" --plan "$PKS_SERVICE_PLAN_NAME" --num-nodes "$PKS_CLUSTER_NUMBER_OF_WORKERS" --wait

  last_action_description=$(pks cluster "$PKS_CLUSTER_NAME" --json | jq -rc '.last_action_description')

  if [[ "$cluster_state" == "$succeeded_state" ]]; then
    echo "Successfully created cluster [$PKS_CLUSTER_NAME], last_action_state=[$cluster_state], last_action_description=[$last_action_description]"
    pks cluster "$PKS_CLUSTER_NAME"
    echo "Next step: make sure that the external hostname configured for the cluster [$PKS_CLUSTER_MASTER_HOSTNAME] is accessible from a DNS/network standpoint, so it can be managed with 'kubectl'"
  else
    echo "Error: Creating cluster [$PKS_CLUSTER_NAME], last_action_state=[$cluster_state], last_action_description=[$last_action_description]"
    exit 1
  fi
}

is_cluster_exists() {
  PKS_CLUSTER_NAME="$1"
  #echo "Login to PKS API [$PCF_PKS_API]"
  pks login -a "$PCF_PKS_API" -u "$PKS_CLI_USER" -p "$PKS_CLI_PASSWORD" --skip-ssl-validation
  pks cluster $PKS_CLUSTER_NAME
  if [ $? -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

LIST_OF_CLUSTERS=$(ls pks-onboarding-repo/pks/$PKS_ENV)
if [ $? -eq 0 ]; then
  echo "Loaded clusters info"
else
  echo "Error: Unable to retrieve clusters info"
  exit 1
fi

for cluster in $LIST_OF_CLUSTERS; do
  if [[ -f pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml ]]; then
    PKS_CLUSTER_NAME=$(cat pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml | yaml2json | jq -r '.pks_cluster_name')
    PKS_CLUSTER_MASTER_HOSTNAME=$(cat pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml | yaml2json | jq -r '.pks_cluster_master_node_hostname')
    PKS_SERVICE_PLAN_NAME=$(cat pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml | yaml2json | jq -r '.pks_plan_name')
    PKS_CLUSTER_NUMBER_OF_WORKERS=$(cat pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml | yaml2json | jq -r '.pks_cluster_number_of_workers')
    PKS_CLUSTER_LDAP_ADMINS=$(cat pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml | yaml2json | jq -r '.pks_cluster_admin_ldap_group[]')

    if [ $cluster != $PKS_CLUSTER_NAME ]; then
      echo "Error: Directory name pks/$PKS_ENV/$cluster does not match with pks_cluster_name defined on config file pks/$PKS_ENV/$cluster/pksClusterConfig.yml "
      exit 1
    fi

    if is_cluster_exists $PKS_CLUSTER_NAME; then
      echo "$PKS_CLUSTER_NAME already exists, skipping cluster creation!"
    else
      echo "Creating $PKS_CLUSTER_NAM cluster..."
      create_pks_cluster $PKS_CLUSTER_NAME $PKS_CLUSTER_MASTER_HOSTNAME $PKS_SERVICE_PLAN_NAME $PKS_CLUSTER_NUMBER_OF_WORKERS
    fi
  fi
done
