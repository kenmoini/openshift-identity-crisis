# LDAP Identity Provider for OpenShift

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

## 3. Create the Certificate ConfigMap

Assuming that the LDAP CA Certificate downloaded earlier is stored in `$HOME/ldap-ca-cert.pem`, you can run the following command to create a ConfigMap from that certificate file:

```bash
oc create configmap ldap-ca-cert --from-file=ca.crt=cert.pem -n openshift-config
```

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