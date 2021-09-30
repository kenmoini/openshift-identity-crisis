#!/bin/bash

#######################################################################
# Setup Vars
#######################################################################

export HTPASSWD_FILE=${HTPASSWD_FILE:="$(pwd)/ocp-users.htpasswd"}

export INITIAL_USER_NAME=${INITIAL_USER_NAME:="myAdmin"}
export INITIAL_USER_PASS=${INITIAL_USER_PASS:="s0m3P455"}

export BULK_NUM_USERS=${BULK_NUM_USERS:=10}
export BULK_USER_PREFIX=${BULK_USER_PREFIX:="user"}
export BULK_USER_SUFFIX=${BULK_USER_SUFFIX:=""}
export BULK_USER_PASSWORD=${BULK_USER_PASSWORD:="s3cur3P455"}
export BULK_USER_START_NUM=${BULK_USER_START_NUM:=1}

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

#######################################################################
# Preflight
#######################################################################

echo "===== Checking for required applications..."
export PATH="${BIN_DIR}:$PATH"

checkyq
checkForProgramAndExit oc
checkForProgramAndExit yq

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

echo "===== Creating HTPasswd file..."
touch $HTPASSWD_FILE

echo "===== Create the initial user..."
htpasswd -c -B -b $HTPASSWD_FILE $INITIAL_USER_NAME $INITIAL_USER_PASS

echo "===== Create bulk users..."
for ((n=$BULK_USER_START_NUM;n<$BULK_NUM_USERS;n++))
do
  BULK_USERNAME="${BULK_USER_PREFIX}${n}${BULK_USER_SUFFIX}"
  echo "  Adding ${BULK_USERNAME} to ${HTPASSWD_FILE}..."
  htpasswd -b $HTPASSWD_FILE ${BULK_USERNAME} ${BULK_USER_PASSWORD} >/dev/null 2>&1
done

oc whoami >/dev/null 2>&1
if [[ $? == 0 ]]; then
  # Check for existing secret
  oc get secret htpasswd-secret -n openshift-config >/dev/null 2>&1
  if [[ $? == 1 ]]; then
    if [[ $1 == "--commit" ]]; then
      echo "===== Creating HTPasswd secret..."
      oc create secret generic htpasswd-secret --from-file=htpasswd=$HTPASSWD_FILE -n openshift-config
    else
      echo -e "\n===== Target YAML Modification:\n"
      oc create secret generic htpasswd-secret --from-file=htpasswd=$HTPASSWD_FILE -n openshift-config --dry-run=client -o yaml
    fi
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

  # Check to see if the HTPasswd IdP Name exists in the current list
  containsElement $(cat oauth-config.yaml | ${YQ_BIN} eval '.spec.identityProviders[0].name' -) "${CURRENT_IDP_NAMES[@]}"

  if [[ $? == 0 ]]; then
    echo "This identity provider $(cat oauth-config.yaml | ${YQ_BIN} eval '.spec.identityProviders[0].name' -) looks to already be configured!"
    exit 0
  else
    # Add the proposed IDP to the array
    CURRENT_IDPs="[${CURRENT_IDPs}$(cat oauth-config.yaml | ${YQ_BIN} -o=json eval '.spec.identityProviders[0]' -)]"

    # Apply the joined configuration
    echo "Adding HTPasswd to OAuth cluster configuration..."
    PATCH_CONTENTS='{"spec": { "identityProviders": '${CURRENT_IDPs}' }}'
    if [[ $1 == "--commit" ]]; then
      echo "===== Writing configuration to cluster!"
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

  echo -e "\nFinished provisioning Htpasswd Identity Provider for OpenShift!\n\n"
  exit 0
else
  echo "Not logged into an OpenShift cluster with `oc` CLI!"
  exit 1
fi