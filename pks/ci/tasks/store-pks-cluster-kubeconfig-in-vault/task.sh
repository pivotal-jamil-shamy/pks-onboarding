#!/bin/bash

set -e

export PKS_USER_PASSWORD="$PKS_CLI_PASSWORD"
ROLE_BINDING_TYPE="ClusterRoleBinding"
ROLE_TYPE="ClusterRole"
ROLE_OR_CLUSTER_ROLE_NAME="cluster-admin"

DATA='{"role_id": "'"$VAULT_ROLE_ID"'","secret_id": "'"$VAULT_SECRET_ID"'"}'
CURL_CMD=$(curl -sk --request POST --data "$DATA" $VAULT_URL/v1/auth/approle/login)
VAULT_TOKEN=$(echo $CURL_CMD | jq -r '.auth.client_token')
if [ $VAULT_TOKEN = "null" ]; then
  echo "Error: Failed to retrieve token fronm vault!"
  echo $(echo $CURL_CMD | jq -r '.')
  exit 2
fi

LIST_OF_CLUSTERS=$(ls pks-onboarding-repo/pks/$PKS_ENV)
if [ $? -eq 0 ]; then
  echo "Loaded clusters info"
else
  echo "Error: Unable to retrieve clusters info"
  exit 1
fi

function yaml2json() {
  ruby -ryaml -rjson -e \
    'puts JSON.pretty_generate(YAML.load(ARGF))' $*
}

generate_kubeconfig() {
  # Collect Tokens from UAA
  CURL_CMD="curl 'https://${PCF_PKS_API}:8443/oauth/token' -sk -X POST -H 'Accept: application/json' -d \"client_id=pks_cluster_client&client_secret=\"\"&grant_type=password&username=${PKS_CLI_USER}&password=\"${PKS_CLI_PASSWORD}\"&response_type=id_token\""

  TOKENS=$(eval $CURL_CMD | jq -r '{id_token, refresh_token} | to_entries | map("\(.key)=\(.value | @sh)") | .[]')
  eval $TOKENS
  if [ $id_token = "unauthorized" ]; then
    echo
    echo "Error: Auth Failed"
    exit 1
  fi

  openssl s_client -showcerts -connect ${PCF_PKS_API}:8443 </dev/null 2>/dev/null | openssl x509 -outform PEM >./${PCF_PKS_API}-ca.crt
  openssl s_client -showcerts -connect ${PKS_CLUSTER_MASTER_HOSTNAME}:8443 </dev/null 2>/dev/null | openssl x509 -outform PEM >./${PKS_CLUSTER_MASTER_HOSTNAME}-ca.crt
  kubectl config set-cluster ${PKS_CLUSTER_NAME} --server=https://${PKS_CLUSTER_MASTER_HOSTNAME}:8443 --certificate-authority=./${PKS_CLUSTER_MASTER_HOSTNAME}-ca.crt --embed-certs=true

  kubectl config set-credentials ${PKS_CLI_USER} \
    --auth-provider oidc \
    --auth-provider-arg client-id=pks_cluster_client \
    --auth-provider-arg cluster_client_secret="" \
    --auth-provider-arg id-token=${id_token} \
    --auth-provider-arg idp-issuer-url=https://${PCF_PKS_API}:8443/oauth/token \
    --auth-provider-arg refresh-token=${refresh_token}

  context_current_admin=$(kubectl config view --minify | yaml2json | jq -r '.["current-context"]')
  context_name_admin=$(kubectl config view --minify | yaml2json | jq -r '.contexts[].name')
  context_cluster_admin=$(kubectl config view --minify | yaml2json | jq -r '.contexts[].context.cluster')
  cluster_name_admin=$(kubectl config view --minify | yaml2json | jq -r '.clusters[].name')
  cluster_server_admin=$(kubectl config view --minify | yaml2json | jq -r '.clusters[].cluster.server')
  cluster_certificate_authority_data_admin=$(kubectl config view --raw --minify | yaml2json | jq -r '.clusters[].cluster | .["certificate-authority-data"]')
  user_config_idp_issuer_url_admin=$(kubectl config view --minify | yaml2json | jq -r '.users[].user|.["auth-provider"].config|.["idp-issuer-url"]')

  kubectl config set-cluster ${cluster_name_admin} --server=https://${PCF_PKS_API}:8443 --certificate-authority=./${PCF_PKS_API}-ca.crt --embed-certs=true

  kubeconfig_admin_yaml="./pks-onboarding-repo/pks/scripts/output/kubeconfig-admin.yaml"
  kubeconfig_admin_json="./pks-onboarding-repo/pks/scripts/output/kubeconfig-admin.json"
  cp ./pks-onboarding-repo/pks/scripts/templates/kubeconfig-template.yaml $kubeconfig_admin_yaml

  sed -e 's|CLUSTER_SERVER_ADMIN|'"$cluster_server_admin"'|g' -e 's/CLUSTER_NAME_ADMIN/'"$cluster_name_admin"'/g' \
    -e 's/CONTEXT_CLUSTER_ADMIN/'"$context_cluster_admin"'/g' -e 's/CONTEXT_NAME_ADMIN/'"$context_name_admin"'/g' \
    -e 's/CONTEXT_CURRENT_ADMIN/'"$context_current_admin"'/g' -e 's|USER_CONFIG_IDP_ISSUER_URL_ADMIN|'"$user_config_idp_issuer_url_admin"'|g' \
    -e 's/CLUSTER_CERT_AUTH_DATA_ADMIN/'"$cluster_certificate_authority_data_admin"'/g' \
    -i.bkp $kubeconfig_admin_yaml
  cat $kubeconfig_admin_yaml | yaml2json | jq -r '.' >$kubeconfig_admin_json
}

is_vault_team_exists() {
  vault_team=$1
  CURL_RESULT=$(curl -sk \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    --request LIST \
    ${VAULT_URL}/v1/concourse/$vault_team/)
  if [[ $CURL_RESULT == "{"errors":[]}" ]]; then
    echo "Error: Unable to locate $vault_team on vault"
    exit 1
  else
    echo "Located $vault_team on vault"
  fi
  return 0
}

store_k8s_config_template_in_vault() {
  vault_team=$1
  is_vault_team_exists $vault_team

  kubeconfig_admin_json="./pks-onboarding-repo/pks/scripts/output/kubeconfig-admin.json"
  if [ -f $kubeconfig_admin_json ]; then
    echo "File $kubeconfig_admin_json exists."
  else
    echo "Error: File $kubeconfig_admin_json does not exist."
    exit 1
  fi

  pks_cluster_name=$(cat $kubeconfig_admin_json | jq -r '.clusters[] | .name')
  pks_environment=$(cat $kubeconfig_admin_json | jq -r '.users[].user | .["auth-provider"]| .config| .["idp-issuer-url"]' | awk -F/ '{print $3}' | awk -F. '{print $2}')

  curl -sk \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    --request POST \
    --data @./pks-onboarding-repo/pks/scripts/output/kubeconfig-admin.json \
    ${VAULT_URL}/v1/concourse/$vault_team/pks/$pks_environment/$pks_cluster_name/kubeconfig_template
}

is_cluster_exists() {
  PKS_CLUSTER_NAME="$1"
  pks login -a "$PCF_PKS_API" -u "$PKS_CLI_USER" -p "$PKS_CLI_PASSWORD" --skip-ssl-validation
  pks cluster $PKS_CLUSTER_NAME
  if [ $? -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

is_dns_resolving() {
  PKS_CLUSTER_NAME="$1"
  DNS_FQDN_NAME=$(pks cluster $PKS_CLUSTER_NAME --json | jq -r '.parameters.kubernetes_master_host')
  nslookup $DNS_FQDN_NAME
  if [ $? -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

set_dns_on_hosts() {
  PKS_CLUSTER_NAME="$1"
  if is_dns_resolving $PKS_CLUSTER_NAME; then
    echo "DNS nameresolution already exists..."
  else
    echo "DNS name resolution does not exists.."
    MASTER_IP_ADDRESS=$(pks cluster $PKS_CLUSTER_NAME --json | jq -rc '.kubernetes_master_ips[0]')
    DNS_FQDN_NAME=$(pks cluster $PKS_CLUSTER_NAME --json | jq -r '.parameters.kubernetes_master_host')
    echo "$MASTER_IP_ADDRESS  $DNS_FQDN_NAME" >/etc/hosts
  fi
}

for cluster in $LIST_OF_CLUSTERS; do
  if [[ -f pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml ]]; then
    PKS_CLUSTER_NAME=$(cat pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml | yaml2json | jq -r '.pks_cluster_name')
    VAULT_TEAMS=$(cat pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml | yaml2json | jq -r '.vault_teams_name[]')
    PKS_CLUSTER_MASTER_HOSTNAME=$(cat pks-onboarding-repo/pks/$PKS_ENV/$cluster/pksClusterConfig.yml | yaml2json | jq -r '.pks_cluster_master_node_hostname')
    if is_cluster_exists $PKS_CLUSTER_NAME; then
      set_dns_on_hosts $PKS_CLUSTER_NAME
      pks get-credentials $PKS_CLUSTER_NAME
      for team_name in $VAULT_TEAMS; do
        # Create the Kubeconfig file with ADMIN details
        generate_kubeconfig
        store_k8s_config_template_in_vault $team_name
      done
    else
      echo "Cluster $PKS_CLUSTER_NAME does not exists in PKS..."
    fi
  fi
done
