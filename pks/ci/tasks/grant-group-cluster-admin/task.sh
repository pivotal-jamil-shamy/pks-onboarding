#!/bin/bash

set -e

export PKS_USER_PASSWORD="$PKS_CLI_PASSWORD"
ROLE_BINDING_TYPE="ClusterRoleBinding"
ROLE_TYPE="ClusterRole"
ROLE_OR_CLUSTER_ROLE_NAME="cluster-admin"

function yaml2json() {
  ruby -ryaml -rjson -e \
    'puts JSON.pretty_generate(YAML.load(ARGF))' $*
}

generate_cluster_role_binding() {
  PKS_GROUP="$1"
  role_or_cluster_role_binding_name="$(echo "$PKS_GROUP")"
  #group_name=`ldapsearch -x -h $LDAP_HOSTNAME -D $LDAP_BIND_USER  -w $LDAP_BIND_PASSWORD -b "$LDAP_SEARCH_BASE_DN" "(&(objectCategory=group)(|(cn=$PKS_GROUP)))" cn | grep cn: | awk '{print $2}'`
  cluster_role_binding_yaml="./pks-onboarding-repo/pks/scripts/output/$PKS_GROUP-cluster-role-binding.yaml"
  cp ./pks-onboarding-repo/pks/scripts/templates/group-role-binding-configuration-template.yaml $cluster_role_binding_yaml
  sed -e "s/ROLE_BINDING_TYPE/$ROLE_BINDING_TYPE/g" -e "s/ROLE_OR_CLUSTER_ROLE_BINDING_NAME/$role_or_cluster_role_binding_name/g" \
    -e "s/NAME_OF_GROUP/$PKS_GROUP/g" -e "s/ROLE_TYPE/$ROLE_TYPE/g" \
    -e "s/ROLE_OR_CLUSTER_ROLE_NAME/$ROLE_OR_CLUSTER_ROLE_NAME/g" \
    -i.bkp $cluster_role_binding_yaml
  kubectl apply -f $cluster_role_binding_yaml
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

    if is_cluster_exists $PKS_CLUSTER_NAME; then
      set_dns_on_hosts $PKS_CLUSTER_NAME
      echo "$PKS_CLUSTER_NAME exists, granting the admin cluster role!"
      pks get-credentials $PKS_CLUSTER_NAME
      for group in $PKS_CLUSTER_LDAP_ADMINS; do
        generate_cluster_role_binding $group
      done
    else
      echo "Cluster $PKS_CLUSTER_NAME does not exists in PKS..."
    fi
  fi
done
