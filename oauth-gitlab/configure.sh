#!/bin/bash

#######################################################################
# Setup Vars
#######################################################################

## GITLAB_CREDENTIAL_CLIENT_ID & GITLAB_CREDENTIAL_CLIENT_SECRET need to be defined
export GITLAB_CREDENTIAL_CLIENT_ID=${GITLAB_CREDENTIAL_CLIENT_ID:=""}
export GITLAB_CREDENTIAL_CLIENT_SECRET=${GITLAB_CREDENTIAL_CLIENT_SECRET:=""}

## GITLAB_ENDPOINT should only be used if this is a private hosted GitLab instance being targeted
export GITLAB_ENDPOINT=${GITLAB_ENDPOINT:="https://gitlab.com"}

## GITLAB_CA_CERT_PEM_FILE is the location to the CA Certificate the private GitLab server is signed by
export GITLAB_CA_CERT_PEM_FILE=${GITLAB_CA_CERT_PEM_FILE:=""}

#######################################################################
# Functions
#######################################################################

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     machine=linux;;
    Darwin*)    machine=osx-amd;;
    *)          machine="UNKNOWN:${unameOut}"
esac
case "${unameOut}" in
    Linux*)     yqmachine=linux;;
    Darwin*)    yqmachine=darwin;;
    *)          yqmachine="UNKNOWN:${unameOut}"
esac

archOut="$(arch)"
case "${archOut}" in
    x86_64*)     arch=64;;
    x86*)        arch=32;;
    *)          arch="UNKNOWN:${archOut}"
esac
case "${archOut}" in
    x86_64*)     yqarch=amd64;;
    x86*)        yqarch=386;;
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
    curl -sSL https://gitlab.com/stedolan/jq/releases/download/jq-1.6/jq-${machine}${arch} -o "${BIN_DIR}/jq"
  fi
  chmod +x "${BIN_DIR}/jq"
}

function checkyq () {
  mkdir -p $BIN_DIR
  if [ ! -f "${BIN_DIR}/yq" ]; then
    curl -sSL https://gitlab.com/mikefarah/yq/releases/download/v4.13.2/yq_${yqmachine}_${yqarch} -o "${BIN_DIR}/yq"
  fi
  chmod +x "${BIN_DIR}/yq"
}

#######################################################################
# Preflight
#######################################################################

echo "===== Checking for required applications..."
export PATH="${BIN_DIR}:$PATH"

checkjq
checkyq
checkForProgramAndExit oc
checkForProgramAndExit jq
checkForProgramAndExit yq

if [[ -z "$GITLAB_CREDENTIAL_CLIENT_ID" ]] || [[ -z "$GITLAB_CREDENTIAL_CLIENT_SECRET" ]]; then
  echo "GitLab OAuth Credentials not found at \$GITLAB_CREDENTIAL_CLIENT_ID and \$GITLAB_CREDENTIAL_CLIENT_SECRET!"
  echo "Failed preflight!"
  exit 1
else
  CLIENT_ID=$GITLAB_CREDENTIAL_CLIENT_ID
  CLIENT_SECRET=$GITLAB_CREDENTIAL_CLIENT_SECRET
fi

if [[ ! -z $GITLAB_CA_CERT_PEM_FILE ]]; then
  if [[ ! -f $GITLAB_CA_CERT_PEM_FILE ]]; then
    echo "GitLab CA Certificate defined as \$GITLAB_CA_CERT_PEM_FILE but not found on the filesystem!"
    echo "Failed preflight!"
    exit 1
  fi
fi

# Dry run mode
if [[ ! -z $1 ]]; then
  if [[ $1 != "--commit" ]]; then
      echo -e "\n======================================================================\nDry run - configuration NOT applied to cluster!  Rerun with '--commit'\n======================================================================\n"
  fi
else
  echo -e "\n======================================================================\nDry run - configuration NOT applied to cluster!  Rerun with '--commit'\n======================================================================\n"
fi

#######################################################################
# Main Script
#######################################################################

# Check for a logged in user
oc whoami >/dev/null 2>&1
if [[ $? == 0 ]]; then

  # Check for existing secret
  oc get secret gitlab-oauth-client-secret -n openshift-config >/dev/null 2>&1
  if [[ $? == 1 ]]; then
    if [[ $1 == "--commit" ]]; then
      echo "===== Creating GitLab OAuth Client Secret, Secret..."
      oc create secret generic gitlab-oauth-client-secret --from-literal=clientSecret=$CLIENT_SECRET -n openshift-config
    else
      echo -e "\n===== Target YAML Modification:\n"
      oc create secret generic gitlab-oauth-client-secret --from-literal=clientSecret=$CLIENT_SECRET -n openshift-config --dry-run=client -o yaml
    fi
  fi

  # Check for existing CA Cert ConfigMap if needed
  if [[ ! -z $GITLAB_CA_CERT_PEM_FILE ]] && [[ -f $GITLAB_CA_CERT_PEM_FILE ]]; then
    # Check for existing CA Cert ConfigMap
    oc get configmap gitlab-ca-config-map -n openshift-config >/dev/null 2>&1
    if [[ $? == 1 ]]; then
      if [[ $1 == "--commit" ]]; then
        echo "===== Creating GitLab CA Cert ConfigMap..."
        oc create configmap gitlab-ca-config-map --from-file=ca.crt=$GITLAB_CA_CERT_PEM_FILE -n openshift-config
      else
        echo -e "\n===== Target YAML Modification:\n"
        oc create configmap gitlab-ca-config-map --from-file=ca.crt=$GITLAB_CA_CERT_PEM_FILE -n openshift-config --dry-run=client -o yaml
      fi
    fi
  fi

  # Template out the OAuth Config
  sed "s|CLIENT_ID_HERE|${CLIENT_ID}|g" oauth-config.yaml.template > oauth-config.yaml
  sed -i "s|GITLAB_ENDPOINT_HERE|${GITLAB_ENDPOINT}|g" oauth-config.yaml

  echo "" >> oauth-config.yaml
  # Add CA Certificate definition
  if [[ ! -z $GITLAB_CA_CERT_PEM_FILE ]] && [[ -f $GITLAB_CA_CERT_PEM_FILE ]]; then
    echo "      ca:" >> oauth-config.yaml
    echo "        name: gitlab-ca-config-map" >> oauth-config.yaml
  fi
  
  # Take current OAuth cluster configuration
  CURRENT_CLUSTER_CONFIG=$(oc get OAuth cluster -o yaml)
  CURRENT_CONFIG_LEN=$(echo "$CURRENT_CLUSTER_CONFIG" | ${YQ_BIN} eval '.spec.identityProviders | length' -)
  CURRENT_IDPs=""
  CURRENT_IDP_NAMES=()
  echo -e "\n===== Current Config (${CURRENT_CONFIG_LEN}):\n\n${CURRENT_CLUSTER_CONFIG}"

  # Add current OAuth Identity Providers to an array
  for ((n=0;n<$CURRENT_CONFIG_LEN;n++))
  do
    CUR_NAME=$(echo "$CURRENT_CLUSTER_CONFIG" | ${YQ_BIN} eval '.spec.identityProviders['$n'].name' -)
    echo "===== Found IDP: ${CUR_NAME}..."
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
    echo "Adding GitLab OAuth to OAuth cluster configuration..."
    PATCH_CONTENTS='{"spec": { "identityProviders": '${CURRENT_IDPs}' }}'
    if [[ $1 == "--commit" ]]; then
      echo "Writing configuration to cluster!"
      oc patch OAuth cluster --type merge --patch "$PATCH_CONTENTS"
    else
      echo -e "\n===== Target YAML Modification:\n"
      oc patch OAuth cluster --type merge --patch "$PATCH_CONTENTS" --dry-run=client -o yaml
    fi
  fi

  # Dry run mode
  if [[ ! -z $1 ]]; then
    if [[ $1 != "--commit" ]]; then
        echo -e "\n======================================================================\nDry run - configuration NOT applied to cluster!  Rerun with '--commit'\n======================================================================\n"
    fi
  else
    echo -e "\n======================================================================\nDry run - configuration NOT applied to cluster!  Rerun with '--commit'\n======================================================================\n"
  fi

  echo -e "\nFinished provisioning GitLab OAuth Identity Provider for OpenShift!\n\n"
  exit 0
else
  echo "Not logged into an OpenShift cluster with `oc` CLI!"
  exit 1
fi