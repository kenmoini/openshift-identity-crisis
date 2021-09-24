# Htpasswd Identity Provider for OpenShift

# Automation

In this directory you can find a `./configure.sh` file that will allow you to quickly apply HTPasswd authentication to a logged in cluster.  Edit the file and run as follows:

```bash
# Check configuration
./configure.sh
# Actually apply configuration
./configure.sh --commit
```

# Manual Processes

## Prerequisites

- An OpenShift Cluster user with cluster-admin permissions
- The `htpasswd` binary installed, available from the `httpd-tools` package on RHEL-based systems
- The `oc` binary installed and user logged in

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

```bash
oc get OAuth cluster -o yaml
```

In this directory, you can find a [oauth-config.yaml](oauth-config.yaml) file that can be applied to the cluster.

***WARNING - If you apply the oauth-config.yaml file as is, it will over-write your current configuration!***

> ## Wait a few minutes for the Authentication Operator to reload the configuration across the running Pods and you should be able to see a new Identity Provider on the OpenShift Log In Screen

## Additional Documentation

Red Hat OpenShift Container Platform HTPasswd Configuration: https://docs.openshift.com/container-platform/4.8/authentication/identity_providers/configuring-htpasswd-identity-provider.html