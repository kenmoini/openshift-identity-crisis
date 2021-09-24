# LDAP Identity Provider for OpenShift

# Automation

In this directory you can find a `./configure.sh` file that will allow you to quickly apply LDAP authentication to a logged in cluster.  ***Edit the file*** and run as follows:

```bash
# Check configuration
./configure.sh
# Actually apply configuration
./configure.sh --commit
```

# Manual Processes

## Prerequisites

- An OpenShift Cluster user with cluster-admin permissions
- An LDAP Server with an Admin/Bind User
- The CA Certificate of the LDAP Server

For this reference, the configuration will be based off of a Red Hat Identity Management deployment with the default schema.

## 1. Download the LDAP Certificate Authority Certificate

First, you'll need a copy of the LDAP Certificate Authority's Certificate - this is a public certificate and will still be stored in a ConfigMap.

If using Red Hat Identity Management:

1. Log into the web panel at `https://IDM_HOST/`
2. Navigate to **Authentication > Certificates** and in the list of certificates, find the one with a Subject of `CN=Certificate Authority`, likely the first one - click the linked Serial Number.
3. From the **Actions** dropdown, click **Download**

Place this certificate somewhere easy to access, like maybe `$HOME/ldap-ca.cert.pem`

## 2. Create the Bind User Secret

To authenticate users against the LDAP server you need to provide a user with binding permissions, such as the Admin user.

The binding username is stored in the LDAP Configuration while the password is stored in a Secret:

```bash
BIND_PASSWORD="s3cur3P455"

oc create secret generic ldap-bind-password --from-literal=bindPassword=${BIND_PASSWORD} -n openshift-config
```

The Secret key must be called `bindPassword`.

## 3. Create the Certificate ConfigMap

Assuming that the LDAP CA Certificate downloaded earlier is stored in `$HOME/ldap-ca-cert.pem`, you can run the following command to create a ConfigMap from that certificate file:

```bash
oc create configmap ldap-ca-cert --from-file=ca.crt=cert.pem -n openshift-config
```

The ConfigMap key must be called `ca.crt`.

## 4. Apply the LDAP OAuth Configuration

Now that the LDAP CA Cert is stored on the cluster as a ConfigMap and the Binding User's password is stored as a Secret, we can apply the following to the OAuth/cluster configuration:

```yaml
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
    - ldap:
        attributes:
          email:
            - mail
          id:
            - dn
          name:
            - cn
          preferredUsername:
            - uid
        bindDN: 'uid=admin,cn=users,cn=accounts,dc=kemo,dc=labs'
        bindPassword:
          name: ldap-bind-password
        ca:
          name: ldap-ca-cert
        insecure: false
        url: >-
          ldaps://idm.kemo.labs:636/cn=users,cn=accounts,dc=kemo,dc=labs?uid?sub?(uid=*)
      mappingMethod: claim
      name: LabLDAP
      type: LDAP
```

This is a cluster-wide configuration and not namespaced - you can `oc apply -f` this manifest as a YAML file.

Make sure to set the following to meet the specifications of your LDAP server - this is formatted to the Red Hat Identity Management default standard schema:

- `.spec.identityProviders.ldap.bindDN` should meet the target Distinctive Name of your Admin/Binding User
` `.spec.identityProviders.ldap.bindPassword` is the name of the Secret created in ***step #2, Create the Bind User Secret***
- `.spec.identityProviders.ldap.ca.name` is the name of the ConfigMap created in ***step #3, Create the Certificate ConfigMap***
- `.spec.identityProviders.ldap.url` is the target of your LDAP Server with any sort of filters to apply to every query
- `.spec.identityProviders.ldap.name` is the friendly name given to the Identity Provider on the Auth Provider portion of the OpenShift log in screen

> ## Wait a few minutes for the Authentication Operator to reload the configuration across the running Pods and you should be able to see a new Identity Provider on the OpenShift Log In Screen

## Bonus: LDAP Group Syncing & RoleBinding

Since LDAP can support complex grouping of users and flexible ways of querying and targeting them, we can sync the provided Groups to RoleBindings so LDAP users who are assigned Administrative privileges and groups can automatically assume cluster-admin on the OpenShift cluster without having to individually assign them to each user.

In the following example, we'll sync two groups from LDAP, `labadmins` and `admins`:

```yaml
kind: LDAPSyncConfig
apiVersion: v1
url: ldaps://idm.kemo.labs:636
insecure: false
groupUIDNameMapping:
  "cn=labadmins,cn=groups,cn=accounts,dc=kemo,dc=labs": labadmins
  "cn=admins,cn=groups,cn=accounts,dc=kemo,dc=labs": admins
bindDN: uid=admin,cn=users,cn=accounts,dc=kemo,dc=labs
bindPassword: SOME_SECURE_PASSWORD
ca: cert.pem
rfc2307:
  groupsQuery:
    baseDN: "cn=groups,cn=accounts,dc=kemo,dc=labs"
    scope: sub
    derefAliases: never
    pageSize: 0
    filter: (|(cn=labadmins)(cn=admins))
  groupUIDAttribute: dn 
  groupNameAttributes: [ cn ] 
  groupMembershipAttributes: [ member ]
  usersQuery:
    baseDN: "cn=users,cn=accounts,dc=kemo,dc=labs"
    scope: sub
    derefAliases: never
    pageSize: 0
  userUIDAttribute: dn
  userNameAttributes: [ uid ]
  tolerateMemberNotFoundErrors: true
  tolerateMemberOutOfScopeErrors: true
```

This is a cluster-wide configuration and not namespaced - you can `oc apply -f` this manifest as a YAML file.

Make sure to set the following to meet the specifications of your LDAP server - this is formatted to the Red Hat Identity Management default standard schema:

- `.url` is simply the `${LDAP_PROTOCOL}://${LDAP_HOSTNAME}:${LDAP_PORT}` without anything else trailing
- `.groupUIDNameMapping` is where you can find the two LDAP groups being synced and their name that will be referenced as OpenShift groups
- `.bindDN` is the same Binding User DN that was used earlier
- `.bindPassword` is the Binding User's password - yeah, unfortunately it can't reference the same Secret from earlier when the LDAP configuration was made, however this `LDAPSyncConfig/v1` resource is only available to cluster-admins so keep your RBAC tight
- `.rfc2307.groupsQuery.baseDN` is the base DN provided to query LDAP Groups
- `.rfc2307.groupsQuery.filter` as is currently set allows for the `labadmins` or `admins` Group
- `.rfc2307.usersQuery` sets the base query parameters for users - this is for any user without additional filtering

Next, run the sync configuration against the OpenShift cluster and apply a cluster-admin ClusterRoleBinding to the Groups we named...assuming this LDAPSyncConfig manifest was created as `ldap-sync-config.yaml`:

```bash
## Sync the configuration
oc adm groups sync --sync-config=ldap-sync-config.yaml --confirm

## Set RBAC bindings
oc adm policy add-cluster-role-to-group cluster-admin admins
oc adm policy add-cluster-role-to-group cluster-admin labadmins
```

## Additional Documentation

- Red Hat OpenShift Container Platform LDAP Configuration: https://docs.openshift.com/container-platform/4.8/authentication/identity_providers/configuring-ldap-identity-provider.html
- Red Hat OpenShift Container Platform LDAP Group Syncing: https://docs.openshift.com/container-platform/4.8/authentication/ldap-syncing.html