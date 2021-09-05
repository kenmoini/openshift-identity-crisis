#!/bin/bash

#######################################################################
# Setup Vars
#######################################################################

export HTPASSWD_FILE="$(pwd)/ocp-users.htpasswd"

export INITIAL_USER_NAME="myAdmin"
export INITIAL_USER_PASS="s0m3P455"

export BULK_NUM_USERS=10
export BULK_USER_PREFIX="user"
export BULK_USER_SUFFIX=""
export BULK_USER_PASSWORD="s3cur3P455"
export BULK_USER_START_NUM=1

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

echo "Checking for required applications..."
checkForProgramAndExit oc
checkForProgramAndExit yq

echo "Creating HTPasswd file..."
touch $HTPASSWD_FILE

echo "Create the initial user..."
htpasswd -c -B -b $HTPASSWD_FILE $INITIAL_USER_NAME $INITIAL_USER_PASS

echo "Create bulk users..."
for ((n=$BULK_USER_START_NUM;n<$BULK_NUM_USERS;n++))
do
 BULK_USERNAME="${BULK_USER_PREFIX}${n}${BULK_USER_SUFFIX}"
 echo "  Adding ${BULK_USERNAME} to ${HTPASSWD_FILE}..."
 htpasswd -b $HTPASSWD_FILE ${BULK_USERNAME} ${BULK_USER_PASSWORD} >/dev/null 2>&1
done

oc whoami >/dev/null 2>&1
if [[ $? == 0 ]]; then
  oc get secret htpasswd-secret -n openshift-config >/dev/null 2>&1
  if [[ $? == 1 ]]; then
    echo "Creating HTPasswd secret..."
    oc create secret generic htpasswd-secret --from-file=htpasswd=$HTPASSWD_FILE -n openshift-config
  fi
  
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
    echo "Adding HTPasswd to OAuth cluster configuration..."
    oc patch OAuth cluster --type merge --patch '{"spec": { "identityProviders": '$CURRENT_IDPs' }}'
  fi

  echo "Finished provisioning"
  exit 0
else
  echo "Not logged into an OpenShift cluster with `oc` CLI!"
  exit 1
fi


