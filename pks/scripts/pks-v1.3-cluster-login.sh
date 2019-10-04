#!/bin/bash -e
#set -x

# version: v1.9


PKS_API=""

usage() {
    echo "PKS Vault kubeconfig retriever script."
    echo ""
    echo "-h --help"
    echo "--EMAIL=[UAA-USER]"
    echo "--TEAM=[VAULT-TEAM-NAME]"
    echo "--ENV=[PKS-ENV]"
    echo "--CLUSTER=[PKS-K8s-CLUSTER-NAME]"
    echo ""
    echo "example: ./pks-v1.3-cluster-login.sh --EMAIL=firstname.lastname@email.com --TEAM=mobile-site --ENV=dev --CLUSTER=team-cluster"
}

yaml2json() {
    ruby -ryaml -rjson -e \
        'puts JSON.pretty_generate(YAML.load(ARGF))' $*
}

urlencode() {
    local l=${#1}
    for (( i = 0 ; i < l ; i++ )); do
        local c=${1:i:1}
        case "$c" in
            [a-zA-Z0-9.~_-]) printf "$c" ;;
            ' ') printf + ;;
            *) printf '%%%.2X' "'$c"
        esac
    done
}


is_curl_installed() {
    if ! cmd_result="$(type curl)" || [[ -z $cmd_result ]]; then
        echo ""
        echo "ERROR: Unable to execute curl command, please install curl"
        exit 1
    else
        echo -n "..."
    fi
}

is_ruby_installed() {
    if ! cmd_result="$(type ruby)" || [[ -z $cmd_result ]]; then
        echo ""
        echo "ERROR: Unable to execute ruby command, please install ruby"
        exit 1
    else
        echo -n "..."
    fi
}

is_safe_installed() {
    if ! cmd_result="$(type safe)" || [[ -z $cmd_result ]]; then
        echo ""
        echo "ERROR: Unable to execute safe cli command, please install safe https://github.com/starkandwayne/safe/releases"
        exit 1
    else
        echo -n "..."
    fi
}

is_vault_installed() {
    if ! cmd_result="$(type vault)" || [[ -z $cmd_result ]]; then
        echo ""
        echo "ERROR: Unable to locate vault cli command, please install vault, https://www.vaultproject.io/downloads.html"
        exit 1
    else
        echo -n "..."
    fi
}

is_kubectl_installed() {
    if ! cmd_result="$(type kubectl)" || [[ -z $cmd_result ]]; then
        echo ""
        echo "ERROR: Unable to execute kubectl cli command, please install kubectl, https://kubernetes.io/docs/tasks/tools/install-kubectl/"
        exit 1
    else
        echo -n "..."
    fi
}

is_jq_installed() {
    if ! cmd_result="$(type jq)" || [[ -z $cmd_result ]]; then
        echo ""
        echo "ERROR: Unable to execute jq command, please install jq, https://stedolan.github.io/jq/download/"
        exit 1
    else
        echo -n "..."
    fi
}

is_vault_team_exists() {
    vault_team=$1
    safe vault list /concourse/$vault_team >/dev/null
    if [ $? -eq 0 ]; then
        echo -n "..."
    else
        echo "ERROR: Unable to locate /concourse/$vault_team on vault"
        exit 1
    fi
}

is_vault_cluster_exists() {
    vault_team=$1
    pks_environment=$2
    pks_cluster_name=$3
    safe vault list /concourse/$vault_team/pks/$pks_environment/$pks_cluster_name >/dev/null
    if [ $? -eq 0 ]; then
        echo "Done"
    else
        echo "ERROR: Unable to locate /concourse/$vault_team/pks/$pks_environment/$pks_cluster_name on vault"
        exit 1
    fi
}

retrieve_k8s_config_template_from_vault() {
    vault_team=$1
    pks_environment=$2
    pks_cluster_name=$3
    mkdir -p ~/.kube/
    echo -n "Retrieving kubeconfig template from Vault..."
    safe vault read -field=data -format=yaml /concourse/$vault_team/pks/$pks_environment/$pks_cluster_name/kubeconfig_template >~/.kube/custom-kubeconfig.yaml
    if [ $? -eq 0 ]; then
        echo -n "..."
    else
        echo "ERROR: Unable to retrieve kubeconfig from vault key, /concourse/$vault_team/pks/$pks_environment/$pks_cluster_name/kubeconfig_template"
        exit 1
    fi
    PKS_API=$(cat ~/.kube/custom-kubeconfig.yaml | yaml2json | jq -r '.users[].user|.["auth-provider"].config|.["idp-issuer-url"]' | awk -F/ '{print $3}' | awk -F: '{print $1}')
    echo "Done"
}

retrieve_k8s_tokens_from_pks() {
    PKS_API=$1
    UAA_USERNAME="$2"
    PKS_CLUSTER="$3"

    #Prompt for Password
    echo -n "Password:"
    read -s UAA_PASSWORD_RAW
    echo -n ""
    echo ""

    PKS_PASSWORD=$(urlencode $UAA_PASSWORD_RAW)
    echo -n "Retrieving credentials for cluster: $PKS_CLUSTER."

    CURL_CMD=$(curl 'https://'"${PKS_API}"':8443/oauth/token' -sk -X POST -H 'Accept: application/json' -d "client_id=pks_cluster_client&client_secret=""&grant_type=password&username=${UAA_USERNAME}&password="${PKS_PASSWORD}"&response_type=id_token")
    if [ $? -eq 0 ]; then
        echo "...Done"
    else
        echo ""
        echo "ERROR: Unable to retrieve token from ${PKS_API}"
        exit 1
    fi

    TOKENS=$(echo $CURL_CMD | jq -r '{id_token, refresh_token} | to_entries | map("\(.key)=\(.value | @sh)") | .[]')

    eval $TOKENS
    if [ $id_token = "unauthorized" ]; then
        echo
        echo "ERROR: Auth Failed"
        exit 1
    fi

    if [ $id_token = "null" ]; then
        echo
        echo "ERROR: Failed to retrieve token"
        exit 1
    fi

    dsg_kubeconfig_yaml=~/.kube/custom-kubeconfig.yaml

    sed -e 's|user: CONTEXT_USER|user: '"$UAA_USERNAME"'|g' -e 's/name: USER_NAME_USER/name: '"$UAA_USERNAME"'/g' \
        -e 's/id-token: USER_CONFIG_ID_TOKEN_USER/id-token: '"$id_token"'/g' -e 's/refresh-token: USER_CONFIG_REFRESH_TOKEN_USER/refresh-token: '"$refresh_token"'/g' \
        -i.bkp $dsg_kubeconfig_yaml
    kubectl config unset users.$UAA_USERNAME
    KUBECONFIG=~/.kube/config:$dsg_kubeconfig_yaml kubectl config view --raw >mergedkubconfig && mv mergedkubconfig ~/.kube/config
    kubectl config use-context $PKS_CLUSTER

    if [ $? -eq 0 ]; then
        echo "Successfully updated kubeconfig."
        echo "  Cluster: $PKS_CLUSTER"
        echo "  Username: $UAA_USERNAME"
    else
        echo "ERROR: Unable to retrieve kubeconfig from vault key, /concourse/$vault_team/pks/$pks_environment/$pks_cluster_name/kubeconfig_template"
        exit 1
    fi
    echo ""
    echo "  * Now you can use kubectl commands to interact with pks cluster, $PKS_CLUSTER."
    echo "  * You can now switch between clusters by using:"
    echo "       kubectl config use-context <cluster-name>"
    echo ""
}

if [ "$#" -lt 4 ]; then
    usage
    exit 1
fi

while [ "$1" != "" ]; do
    PARAM=$(echo $1 | awk -F= '{print $1}')
    VALUE=$(echo $1 | awk -F= '{print $2}')
    case $PARAM in
    -h | --help)
        usage
        exit
        ;;
    --EMAIL)
        UAA_USERNAME=$VALUE
        ;;
    --TEAM)
        VAULT_TEAM=$VALUE
        ;;
    --ENV)
        PKS_ENV=$VALUE
        ;;
    --CLUSTER)
        PKS_CLUSTER=$VALUE
        ;;
    --CERT)
        PKS_CLUSTER_CERT=$VALUE
        ;;
    *)
        echo "ERROR: unknown parameter \"$PARAM\""
        usage
        exit 1
        ;;
    esac
    shift
done

echo -n "Performing prerequisites check..."
is_curl_installed
is_ruby_installed
is_safe_installed
is_vault_installed
is_kubectl_installed
is_jq_installed
is_vault_team_exists "$VAULT_TEAM"
is_vault_cluster_exists "$VAULT_TEAM" "$PKS_ENV" "$PKS_CLUSTER"
retrieve_k8s_config_template_from_vault "$VAULT_TEAM" "$PKS_ENV" "$PKS_CLUSTER"
retrieve_k8s_tokens_from_pks "$PKS_API" "$UAA_USERNAME" "$PKS_CLUSTER"
