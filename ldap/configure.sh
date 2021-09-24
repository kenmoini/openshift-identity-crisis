#!/bin/bash

#######################################################################
# Setup Vars
#######################################################################

export LDAP_CA_CERT_FILE=${LDAP_CA_CERT_FILE:="$HOME/ldap-ca-cert.pem"}
export LDAP_SERVER=${LDAP_SERVER:="idm.kemo.labs"}
export LDAP_BASE=${LDAP_BASE:="dc=kemo,dc=labs"}

export BIND_USER_NAME=${BIND_USER_NAME:="myAdmin"}
export BIND_USER_PASS=${BIND_USER_PASS:="s0m3P455"}

export BIND_USER_DN=${BIND_USER_DN:="uid=${BIND_USER_NAME},cn=users,cn=accounts,${LDAP_BASE}"}
export LDAP_URL=${LDAP_URL:="ldaps://${LDAP_SERVER}:636/cn=users,cn=accounts,${LDAP_BASE}?uid?sub?(uid=*)"}

#######################################################################
# Functions
#######################################################################

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     machine=linux;;
    Darwin*)    machine=darwin;;
    *)          machine="UNKNOWN:${unameOut}"
esac

archOut="$(arch)"
case "${archOut}" in
    x86_64*)     arch=amd64;;
    x86*)        arch=386;;
    *)          arch="UNKNOWN:${archOut}"
esac

PWD=$(pwd)
PARENT_DIR=$(dirname "$PWD")
BIN_DIR="${PARENT_DIR}/bin"
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
checkForProgramAndExit yq

# Check for a logged in user
oc whoami >/dev/null 2>&1
if [[ $? == 0 ]]; then

  # Check for existing secret
  oc get secret ldap-bind-password -n openshift-config >/dev/null 2>&1
  if [[ $? == 1 ]]; then
    echo "Creating LDAP Bind User Secret..."
    oc create secret generic ldap-bind-password --from-literal=bindPassword=$BIND_USER_PASS -n openshift-config
  fi

  # Check for existing ConfigMap
  oc get configmap ldap-ca-cert -n openshift-config >/dev/null 2>&1
  if [[ $? == 1 ]]; then
    if [[ -f $LDAP_CA_CERT_FILE ]]; then
      echo "Creating LDAP CA Cert ConfigMap..."
      oc create configmap ldap-ca-cert --from-file=ca.crt=$LDAP_CA_CERT_FILE -n openshift-config
    else
      echo "LDAP CA Certificate not found at ${LDAP_CA_CERT_FILE} !"
      exit 1
    fi
  fi

  # Template out the OAuth Config if does not exist
  sed "s/BIND_USER_DN/${BIND_USER_DN}/g" oauth-config.yaml.template > oauth-config.yaml
  sed -i "s|LDAP_URL_HERE|${LDAP_URL}|g" oauth-config.yaml
  
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
    echo "Adding LDAP to OAuth cluster configuration..."
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

  echo -e "\nFinished provisioning Htpasswd Identity Provider for OpenShift!\n\n"
  exit 0
else
  echo "Not logged into an OpenShift cluster with `oc` CLI!"
  exit 1
fi