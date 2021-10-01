#!/bin/bash

#######################################################################
# Setup Vars
#######################################################################

## BASIC_AUTH_NAME is a DNS-safe name for this BASIC_AUTH IdP
export BASIC_AUTH_NAME=${BASIC_AUTH_NAME:="MySSO"}
export BASIC_AUTH_LOWER_NAME=$(echo "${BASIC_AUTH_NAME}" | tr '[:upper:]' '[:lower:]')

## BASIC_AUTH_ENDPOINT points to the HTTPS endpoint of the Basic Auth service
export BASIC_AUTH_ENDPOINT=${BASIC_AUTH_ENDPOINT:=""}

## BASIC_AUTH_CA_CERT_PEM_FILE is the location to the CA Certificate the private Basic Auth service is signed by
export BASIC_AUTH_CA_CERT_PEM_FILE=${BASIC_AUTH_CA_CERT_PEM_FILE:=""}

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

echo -e "\n===== Checking for required variables..."

if [[ -z "$BASIC_AUTH_ENDPOINT" ]]; then
  echo "Basic Auth Server Endpoint not found at \$BASIC_AUTH_ENDPOINT!"
  echo "Failed preflight!"
  exit 1
fi

if [[ ! -z $BASIC_AUTH_CA_CERT_PEM_FILE ]]; then
  if [[ ! -f $BASIC_AUTH_CA_CERT_PEM_FILE ]]; then
    echo "Basic Auth Server CA Certificate defined as \$BASIC_AUTH_CA_CERT_PEM_FILE but not found on the filesystem!"
    echo "Failed preflight!"
    exit 1
  fi
else
  echo "Basic Auth Server CA Certificate not defined as \$BASIC_AUTH_CA_CERT_PEM_FILE!"
  echo "Failed preflight!"
  exit 1
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

  # Check for existing CA Cert ConfigMap if needed
  if [[ ! -z $BASIC_AUTH_CA_CERT_PEM_FILE ]] && [[ -f $BASIC_AUTH_CA_CERT_PEM_FILE ]]; then
    # Check for existing CA Cert ConfigMap
    CLIENT_CA_CERT_CONFIGMAP_NAME="${BASIC_AUTH_LOWER_NAME}-basic-auth-ca-config-map"
    oc get configmap ${CLIENT_CA_CERT_CONFIGMAP_NAME} -n openshift-config >/dev/null 2>&1
    if [[ $? == 1 ]]; then
      if [[ $1 == "--commit" ]]; then
        echo "===== Creating ${BASIC_AUTH_NAME} Basic Auth CA Cert ConfigMap..."
        oc create configmap ${CLIENT_CA_CERT_CONFIGMAP_NAME} --from-file=ca.crt=$BASIC_AUTH_CA_CERT_PEM_FILE -n openshift-config
      else
        echo -e "\n===== Target YAML Modification:\n"
        oc create configmap ${CLIENT_CA_CERT_CONFIGMAP_NAME} --from-file=ca.crt=$BASIC_AUTH_CA_CERT_PEM_FILE -n openshift-config --dry-run=client -o yaml
      fi
    fi
  fi

  # Template out the OAuth Config
  sed "s|BASIC_AUTH_NAME_HERE|${BASIC_AUTH_NAME}|g" oauth-config.yaml.template > oauth-config.yaml
  sed -i "s|HTTPS_ENDPOINT_HERE|${BASIC_AUTH_ENDPOINT}|g" oauth-config.yaml
  sed -i "s|CA_CERT_CONFIGMAP_NAME_HERE|${CLIENT_CA_CERT_CONFIGMAP_NAME}|g" oauth-config.yaml

  echo "" >> oauth-config.yaml
  # Add CA Certificate definition
  if [[ ! -z $BASIC_AUTH_CA_CERT_PEM_FILE ]] && [[ -f $BASIC_AUTH_CA_CERT_PEM_FILE ]]; then
    echo "      ca:" >> oauth-config.yaml
    echo "        name: ${CLIENT_CA_CERT_CONFIGMAP_NAME}" >> oauth-config.yaml
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
    echo "Adding ${BASIC_AUTH_NAME} Basic Auth to OAuth cluster configuration..."
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

  echo -e "\nFinished provisioning ${BASIC_AUTH_NAME} Basic Auth OAuth Identity Provider for OpenShift!\n\n"
  exit 0
else
  echo "Not logged into an OpenShift cluster with `oc` CLI!"
  exit 1
fi