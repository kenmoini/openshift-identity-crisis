#!/bin/bash

#######################################################################
# Setup Vars
#######################################################################

export LDAP_CA_CERT_FILE=${LDAP_CA_CERT_FILE:="$HOME/ldap-ca-cert.pem"}
export LDAP_BASE=${LDAP_BASE:="dc=kemo,dc=labs"}
export LDAP_URL=${LDAP_URL:="ldaps://idm.kemo.labs:636/cn=users,cn=accounts,${LDAP_BASE}?uid?sub?(uid=*)"}

export BIND_USER_NAME=${BIND_USER_NAME:="myAdmin"}
export BIND_USER_PASS=${BIND_USER_PASS:="s0m3P455"}
export BIND_USER_DN=${BIND_USER_DN:="uid=${BIND_USER_NAME},cn=users,cn=accounts,${LDAP_BASE}"}

#######################################################################
# Functions
#######################################################################

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

#######################################################################
# Main Script
#######################################################################

echo "Checking for required applications..."
checkForProgramAndExit oc

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
  CURRENT_CONFIG_LEN=$(yq <<<$(oc get OAuth cluster -o yaml) '.spec.identityProviders | length')
  CURRENT_IDPs=""
  CURRENT_IDP_NAMES=()

  for ((n=0;n<$CURRENT_CONFIG_LEN;n++))
  do
    CUR_NAME=$(oc get OAuth cluster -o yaml | yq -c '.spec.identityProviders['$n'].name')
    echo "Found IDP: ${CUR_NAME}..."
    CURRENT_IDP_NAMES=(${CURRENT_IDP_NAMES[@]} "$CUR_NAME")
    CURRENT_IDPs="${CURRENT_IDPs}$(oc get OAuth cluster -o yaml | yq -c '.spec.identityProviders['$n']'),"
  done

  containsElement $(yq -c '.spec.identityProviders[0].name' oauth-config.yaml) "${CURRENT_IDP_NAMES[@]}"

  if [[ $? == 0 ]]; then
    echo "This identity provider $(yq -c '.spec.identityProviders[0].name' oauth-config.yaml) looks to already be configured!"
    exit 0
  else
    # Add the proposed IDP to the array
    CURRENT_IDPs="[${CURRENT_IDPs}$(yq -c '.spec.identityProviders[0]' oauth-config.yaml)]"

    # Apply the joined configuration
    echo "Adding LDAP to OAuth cluster configuration..."
    oc patch OAuth cluster --type merge --patch '{"spec": { "identityProviders": '$CURRENT_IDPs' }}'
  fi

  echo "Finished provisioning LDAP Identity Provider for OpenShift!"
  exit 0
else
  echo "Not logged into an OpenShift cluster with `oc` CLI!"
  exit 1
fi