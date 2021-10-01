# Basic Auth Identity Provider for OpenShift

# Prerequisites

- An OpenShift Cluster user with cluster-admin permissions
- The `oc` binary installed and user logged in
- A Basic Authentication Service - you can find one to deploy to OpenShift in the `example-idp-service` directory

# Automation

In this directory you can find a `./configure.sh` file that will allow you to quickly apply Basic Authentication to a logged in cluster.  Edit the file and run as follows:

```bash
# Check configuration
./configure.sh
# Actually apply configuration
./configure.sh --commit
```

# Manual Processes

## OpenShift Configuration

### 1. [Optional] Create OpenShift ConfigMap for the Basic Auth Server CA Certificate

If you have a self-signed CA Certificate that needs to be provided to the OpenShift OAuth Configuration then you can create it with the following command, provided the PEM is located in the `$HOME` directory:

```bash
oc create configmap myapp-basic-auth-ca-cert --from-file=ca.crt=$HOME/oidc-ca-cert.pem -n openshift-config
```

### 3. Create the YAML for the OAuth Custom Resource

Replace the needed text in the following YAML with whatever your Client configuration is:

```yaml---
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: BASIC_AUTH_NAME_HERE
    mappingMethod: claim
    type: BasicAuth
    basicAuth:
      url: >-
        HTTPS_ENDPOINT_HERE
      ca:
        name: myapp-basic-auth-ca-cert
```

***Notes:***

- Replace the ***BASIC_AUTH_NAME_HERE*** and ***HTTPS_ENDPOINT_HERE*** with your Basic Auth Service information

### 4. Apply the YAML to the OpenShift Cluster

With the YAML created, we can apply it to the cluster now with the following command, assuming you saved it to a file called oauth.yaml:

> ***WARNING*** The following command may overwrite your current IdP settings!

```bash
oc patch OAuth cluster --patch-file oauth.yaml
```

### 5. ???????

### 6. PROFIT!!!!!1

Once the Authentication Operator has restarted you should be able to log into the cluster with Basic Authentication!