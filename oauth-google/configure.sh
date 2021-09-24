#!/bin/bash

#######################################################################
# Setup Vars
#######################################################################

export GCP_CREDENTIAL_JSON_FILE=${GCP_CREDENTIAL_JSON_FILE:="$HOME/gcp-credentials.json"}

# HOSTED_DOMAIN is the limit on what domain names can use this to log in - leave empty to allow anyone, set to `example.com` to only allow @example.com GSuite users to log in
export HOSTED_DOMAIN=${HOSTED_DOMAIN:=""}

#######################################################################
# Functions
#######################################################################

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     machine=linux;;
    Darwin*)    machine=osx-amd;;
    *)          machine="UNKNOWN:${unameOut}"
esac

archOut="$(arch)"
case "${archOut}" in
    x86_64*)     arch=64;;
    x86*)        arch=32;;
    *)          arch="UNKNOWN:${archOut}"
esac

PWD=$(pwd)
PARENT_DIR=$(dirname "$PWD")
BIN_DIR="${PARENT_DIR}/bin"
JQ_BIN="${BIN_DIR}/jq"
YQ_BIN="${BIN_DIR}/yq"

function checkForProgramAndExit() {
    command -v $1
    if [[ $? -eq 0 ]]; then
        printf '%-72s %-7s\n' $1 "PASSED!";
    else
        printf '%-72s %-7s\n' $1 "FAILED!";
        exit 1
    fi
}

function containsElement () {
  local e match="$1"
  shift
  for e; do [[ "$e" == "$match" ]] && return 0; done
  return 1
}

function checkjq () {
  mkdir -p $BIN_DIR

  if [ ! -f "${BIN_DIR}/jq" ]; then
    curl -sSL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-${machine}${arch} -o "${BIN_DIR}/jq"
  fi

  chmod +x "${BIN_DIR}/jq"
}
checkjq

function checkyq () {
  mkdir -p $BIN_DIR

  if [ ! -f "${BIN_DIR}/yq" ]; then
    curl -sSL https://github.com/mikefarah/yq/releases/download/v4.13.2/yq_${machine}_${arch} -o "${BIN_DIR}/yq"
  fi

  chmod +x "${BIN_DIR}/yq"
}
checkyq

#######################################################################
# Main Script
#######################################################################

echo "Checking for required applications..."
export PATH="${BIN_DIR}:$PATH"

checkForProgramAndExit oc
checkForProgramAndExit jq
checkForProgramAndExit yq

if [[ ! -f $GCP_CREDENTIAL_JSON_FILE ]]; then
  echo "GCP Credential JSON file not found at ${GCP_CREDENTIAL_JSON_FILE} as defined by \$GCP_CREDENTIAL_JSON_FILE !"
  exit 1
fi

# Set up client variables
CLIENT_ID=$(jq -r '.web.client_id' ${GCP_CREDENTIAL_JSON_FILE})
CLIENT_SECRET=$(jq -r '.web.client_secret' ${GCP_CREDENTIAL_JSON_FILE})

# Check for a logged in user
oc whoami >/dev/null 2>&1
if [[ $? == 0 ]]; then

  # Check for existing secret
  oc get secret google-oauth-client-secret -n openshift-config >/dev/null 2>&1
  if [[ $? == 1 ]]; then
    echo "Creating Google OAuth Client Secret, Secret..."
    oc create secret generic google-oauth-client-secret --from-literal=clientSecret=$CLIENT_SECRET -n openshift-config
  fi

  # Template out the OAuth Config if does not exist
  sed "s|CLIENT_ID_HERE|${CLIENT_ID}|g" oauth-config.yaml.template > oauth-config.yaml
  sed -i "s|HOSTED_DOMAIN|${HOSTED_DOMAIN}|g" oauth-config.yaml
  
  # Take current OAuth cluster configuration
  CURRENT_CLUSTER_CONFIG=$(oc get OAuth cluster -o yaml)
  CURRENT_CONFIG_LEN=$(echo "$CURRENT_CLUSTER_CONFIG" | ${YQ_BIN} eval '.spec.identityProviders | length' -)
  CURRENT_IDPs=""
  CURRENT_IDP_NAMES=()
  echo -e "\nCurrent Config:\n\n${CURRENT_CLUSTER_CONFIG}"

  # Add current OAuth Identity Providers to an array
  for ((n=0;n<$CURRENT_CONFIG_LEN;n++))
  do
    CUR_NAME=$(echo "$CURRENT_CLUSTER_CONFIG" | ${YQ_BIN} eval '.spec.identityProviders['$n'].name' -)
    echo "Found IDP: ${CUR_NAME}..."
    CURRENT_IDP_NAMES=(${CURRENT_IDP_NAMES[@]} "$CUR_NAME")
    CURRENT_IDPs="${CURRENT_IDPs}$(echo "$CURRENT_CLUSTER_CONFIG" | ${YQ_BIN} -o=json eval '.spec.identityProviders['$n']' -),"
  done

  containsElement $(cat oauth-config.yaml | ${YQ_BIN} eval '.spec.identityProviders[0].name' -) "${CURRENT_IDP_NAMES[@]}"

  if [[ $? == 0 ]]; then
    echo "This identity provider $(cat oauth-config.yaml | ${YQ_BIN} eval '.spec.identityProviders[0].name' -) looks to already be configured!"
    exit 0
  else
    # Add the proposed IDP to the array
    CURRENT_IDPs="[${CURRENT_IDPs}$(cat oauth-config.yaml | ${YQ_BIN} -o=json eval '.spec.identityProviders[0]' -)]"

    # Apply the joined configuration
    echo "Adding Google OAuth to OAuth cluster configuration..."
    PATCH_CONTENTS='{"spec": { "identityProviders": '${CURRENT_IDPs}' }}'
    if [[ $1 == "--commit" ]]; then
      echo "Writing configuration to cluster!"
      oc patch OAuth cluster --type merge --patch "$PATCH_CONTENTS"
    else
      echo -e "\n\nDry run - configuration NOT applied to cluster!  Rerun with '--commit'\n\n"
      oc patch OAuth cluster --type merge --patch "$PATCH_CONTENTS" --dry-run=client -o yaml
      echo -e "\n\nDry run - configuration NOT applied to cluster!  Rerun with '--commit'\n\n"
    fi
  fi

  echo -e "\nFinished provisioning Google OAuth Identity Provider for OpenShift!\n\n"
  exit 0
else
  echo "Not logged into an OpenShift cluster with `oc` CLI!"
  exit 1
fi