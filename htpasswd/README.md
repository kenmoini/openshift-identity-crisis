# Htpasswd Identity Provider for OpenShift

## Prerequisites

- An OpenShift Cluster user with cluster-admin permissions
- The `htpasswd` binary installed, available from the `httpd-tools` package on RHEL-based systems
- *Optional:* The `oc` binary installed and user logged in

## 1. Create the HTPasswd file

Create your HTPasswd file and initial user:

```bash
export HTPASSWD_FILE="${HOME}/ocp-users.htpasswd"

export INITIAL_USER_NAME="myAdmin"
export INITIAL_USER_PASS="s0m3P455"

touch $HTPASSWD_FILE
htpasswd -c -B -b $HTPASSWD_FILE $INITIAL_USER_NAME $INITIAL_USER_PASS
```

There is no way to specify Groups with an HTPasswd file and authentication method - RBAC can still be applied individually to users.

## 2. Populate with additional users

Next add additional users to the HTPasswd file:

```bash
htpasswd -b $HTPASSWD_FILE user1 s3cur3P455
```

If you wanted to loop through a set of users and add them in bulk, you could do something such as this:

```bash
export BULK_NUM_USERS=10
export BULK_USER_PREFIX="user"
export BULK_USER_SUFFIX=""
export BULK_USER_PASSWORD="s3cur3P455"
export BULK_USER_START_NUM=1

for ((n=$BULK_USER_START_NUM;n<$BULK_NUM_USERS;n++))
do
 BULK_USERNAME="${BULK_USER_PREFIX}${n}${BULK_USER_SUFFIX}"
 echo "Adding ${BULK_USERNAME} to ${HTPASSWD_FILE}..."
 htpasswd -b $HTPASSWD_FILE ${BULK_USERNAME} ${BULK_USER_PASSWORD}
done
```

## 3. Create Secret in OpenShift

Next, we'll add the Htpasswd file to the OpenShift cluster as a Secret.

In order to create the Secret in the OpenShift Cluster, your user must have cluster-admin access or access to the `openshift-config` namespace and objects within.

```bash
oc create secret generic htpasswd-secret --from-file=htpasswd=$HTPASSWD_FILE -n openshift-config
```

## 4. Set Authentication/OAuth Operator Configuration

With the Secret created, you can now apply the configuration to the OAuth configuration to use the HTPasswd list as an Identity Provider.

In this directory, you can find a [oauth-config.yaml](oauth-config.yaml) file that can be directly applied to the cluster:

```bash
# Take current OAuth cluster configuration
CURRENT_CONFIG_LEN=$(yq <<<$(oc get OAuth cluster -o yaml) '.spec.identityProviders | length')
CURRENT_IDPs=""

# Loop through the current configured IdPs...
for ((n=0;n<$CURRENT_CONFIG_LEN;n++))
do
  CURRENT_IDPs="${CURRENT_IDPs}$(oc get OAuth cluster -o yaml | yq -c '.spec.identityProviders['$n']'),"
done

# Add the proposed IDP to the array
CURRENT_IDPs="[${CURRENT_IDPs}$(yq -c '.spec.identityProviders[0]' oauth-config.yaml)]"

# Apply the joined configuration
oc patch OAuth cluster --type merge --patch '{"spec": { "identityProviders": '$CURRENT_IDPs' }}' --dry-run=client -o yaml
# Remove the --dry-run=client -o yaml to actually patch the config - messing this up can lock you out of the cluster!
```

This is a cluster-wide configuration and not namespaced.

> ## Wait a few minutes for the Authentication Operator to reload the configuration across the running Pods and you should be able to see a new Identity Provider on the OpenShift Log In Screen