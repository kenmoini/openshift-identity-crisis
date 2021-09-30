#!/bin/bash

#######################################################################
# Setup Vars
#######################################################################

## GITHUB_CREDENTIAL_CLIENT_ID & GITHUB_CREDENTIAL_CLIENT_SECRET need to be defined
export GITHUB_CREDENTIAL_CLIENT_ID=${GITHUB_CREDENTIAL_CLIENT_ID:=""}
export GITHUB_CREDENTIAL_CLIENT_SECRET=${GITHUB_CREDENTIAL_CLIENT_SECRET:=""}

## GITHUB_ORGANIZATIONS is the limit on what GitHub Organizations can use this to log in - separated by a semicolon ';'
export GITHUB_ORGANIZATIONS=${GITHUB_ORGANIZATIONS:=""}

## GITHUB_TEAMS is the limit on what GitHub Organization Teams can use this to log in - separated by a semicolon ';'
export GITHUB_TEAMS=${GITHUB_TEAMS:=""}

## GITHUB_HOSTNAME should only be used if this is a private hosted GitHub Enterprise instance being targeted
export GITHUB_HOSTNAME=${GITHUB_HOSTNAME:=""}

## GITHUB_CA_CERT_PEM_FILE is the location to the CA Certificate the GitHub Enterprise server is signed by
export GITHUB_CA_CERT_PEM_FILE=${GITHUB_CA_CERT_PEM_FILE:=""}

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
    curl -sSL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-${machine}${arch} -o "${BIN_DIR}/jq"
  fi
  chmod +x "${BIN_DIR}/jq"
}

function checkyq () {
  mkdir -p $BIN_DIR
  if [ ! -f "${BIN_DIR}/yq" ]; then
    curl -sSL https://github.com/mikefarah/yq/releases/download/v4.13.2/yq_${yqmachine}_${yqarch} -o "${BIN_DIR}/yq"
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

if [[ -z "$GITHUB_CREDENTIAL_CLIENT_ID" ]] || [[ -z "$GITHUB_CREDENTIAL_CLIENT_SECRET" ]]; then
  echo "GitHub OAuth Credentials not found at \$GITHUB_CREDENTIAL_CLIENT_ID and \$GITHUB_CREDENTIAL_CLIENT_SECRET!"
  echo "Failed preflight!"
  exit 1
else
  CLIENT_ID=$GITHUB_CREDENTIAL_CLIENT_ID
  CLIENT_SECRET=$GITHUB_CREDENTIAL_CLIENT_SECRET
fi

GITHUB_ORG_ARRAY=()
GITHUB_TEAMS_ARRAY=()

if [[ ! -z $GITHUB_ORGANIZATIONS ]]; then
  GITHUB_ORG_ARRAY=(${GITHUB_ORGANIZATIONS//;/ })
fi

if [[ ! -z $GITHUB_TEAMS ]]; then
  GITHUB_TEAMS_ARRAY=(${GITHUB_TEAMS//;/ })
fi

if [[ ! -z $GITHUB_CA_CERT_PEM_FILE ]]; then
  if [[ ! -f $GITHUB_CA_CERT_PEM_FILE ]]; then
    echo "GitHub CA Certificate defined as \$GITHUB_CA_CERT_PEM_FILE but not found on the filesystem!"
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
  oc get secret github-oauth-client-secret -n openshift-config >/dev/null 2>&1
  if [[ $? == 1 ]]; then
    if [[ $1 == "--commit" ]]; then
      echo "===== Creating GitHub OAuth Client Secret, Secret..."
      oc create secret generic github-oauth-client-secret --from-literal=clientSecret=$CLIENT_SECRET -n openshift-config
    else
      echo -e "\n===== Target YAML Modification:\n"
      oc create secret generic github-oauth-client-secret --from-literal=clientSecret=$CLIENT_SECRET -n openshift-config --dry-run=client -o yaml
    fi
  fi

  # Check for existing CA Cert ConfigMap if needed
  if [[ ! -z $GITHUB_CA_CERT_PEM_FILE ]] && [[ -f $GITHUB_CA_CERT_PEM_FILE ]]; then
    # Check for existing CA Cert ConfigMap
    oc get configmap github-ca-config-map -n openshift-config >/dev/null 2>&1
    if [[ $? == 1 ]]; then
      if [[ $1 == "--commit" ]]; then
        echo "===== Creating GitHub CA Cert ConfigMap..."
        oc create configmap github-ca-config-map --from-file=ca.crt=$GITHUB_CA_CERT_PEM_FILE -n openshift-config
      else
        echo -e "\n===== Target YAML Modification:\n"
        oc create configmap github-ca-config-map --from-file=ca.crt=$GITHUB_CA_CERT_PEM_FILE -n openshift-config --dry-run=client -o yaml
      fi
    fi
  fi

  # Template out the OAuth Config
  sed "s|CLIENT_ID_HERE|${CLIENT_ID}|g" oauth-config.yaml.template > oauth-config.yaml

  echo "" >> oauth-config.yaml
  # Add Hostname
  if [[ ! -z "$GITHUB_HOSTNAME" ]]; then
    echo "      hostname: ${GITHUB_HOSTNAME}" >> oauth-config.yaml
  fi
  # Add CA Certificate definition
  if [[ ! -z $GITHUB_CA_CERT_PEM_FILE ]] && [[ -f $GITHUB_CA_CERT_PEM_FILE ]]; then
    echo "      ca:" >> oauth-config.yaml
    echo "        name: github-ca-config-map" >> oauth-config.yaml
  fi
  # Add Organization Filters
  if [[ ${#GITHUB_ORG_ARRAY[@]} -gt 0 ]]; then
    echo "      organizations:" >> oauth-config.yaml
    for org in ${GITHUB_ORG_ARRAY[@]}; do
      echo "      - ${org}" >> oauth-config.yaml
    done
  fi
  # Add Team Filters
  if [[ ${#GITHUB_TEAMS_ARRAY[@]} -gt 0 ]]; then
    echo "      teams:" >> oauth-config.yaml
    for team in ${GITHUB_TEAMS_ARRAY[@]}; do
      echo "      - ${team}" >> oauth-config.yaml
    done
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
    echo "Adding GitHub OAuth to OAuth cluster configuration..."
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

  echo -e "\nFinished provisioning GitHub OAuth Identity Provider for OpenShift!\n\n"
  exit 0
else
  echo "Not logged into an OpenShift cluster with `oc` CLI!"
  exit 1
fi