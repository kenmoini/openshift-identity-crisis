# GitLab OAuth Identity Provider for OpenShift

# Automation

*(Still needs the Manual Processes > Prerequisites to take place in GitLab)*

In this directory you can find a `./configure.sh` file that will allow you to quickly apply GitLab OAuth authentication to a logged in cluster.  ***Edit the file*** and run as follows:

```bash
# Export the client credential variables
export GITLAB_CREDENTIAL_CLIENT_ID="abc123"
export GITLAB_CREDENTIAL_CLIENT_SECRET="someLongSecretString"
# See `./configure.sh` for extra variables

# Check configuration
./configure.sh
# Actually apply configuration
./configure.sh --commit
```

Requires the GitLab OAuth Client Credentials to be passed as environmental variables.

# Manual Processes

## Prerequisites

Before you can configure OpenShift to use GitLab as an Identity Provider, you need to create the OAuth Client in GitLab.

### 1. Navigate to GitLab Admin Area

<div align="center" style="text-align:center">

<img alt="Goto your user's GitLab Admin Area" src="./img/1.png" style="border:2px solid #000" />

**Goto your GitLab's Admin Area**

</div>

### 2. Navigate to Applications

<div align="center" style="text-align:center">

<img alt="Use the left-hand pane to navigate to Applications" src="./img/2.png" style="border:2px solid #000" />

**Use the left-hand pane to navigate to Applications**

</div>

### 3. Click 'New application'

<div align="center" style="text-align:center">

<img alt="Click the 'New application' button" src="./img/3.png" style="border:2px solid #000" />

**Click the 'New application' button**

</div>

### 4. Provide OAuth Details

<div align="center" style="text-align:center">

<img alt="Fill in the information to match your OpenShift cluster and other information" src="./img/4.png" style="border:2px solid #000" />

**Provide the GitLab OAuth Application some primer information**

</div>

Provide the following information:

- **An Application Name**, whatever you'd like - this will show on the Authorization flow screen
- The **Redirect URI** is the most important part of this form - it'll be the OpenShift OAuth Callback endpoint, eg `https://oauth-openshift.apps.cluster-3078.3078.sandbox601.opentlc.com/oauth2callback/gitlab` following the format of: `https://oauth-openshift.apps.<cluster_name>.<base_domain>/oauth2callback/<IdP_Name>`
- Check the **Trusted** and **Confidential** checkboxes
- Provide the scopes for `read_user`, `openid`, `profile`, and `email`

Click **Save application**

### 5. Copy Client ID and Client Secret

<div align="center" style="text-align:center">

<img alt="Take note of the Client ID and Client Secret" src="./img/5.png" style="border:2px solid #000" />

**Take note of the Client ID and Client Secret**

</div>


## Adding the GitLab IdP to the OpenShift Cluster

With the configuration finished in GitLab, we can now add our OAuth information to the cluster for consumption.

### 1. Create OpenShift Secret for the OAuth Client Secret

Next, you can create the needed OpenShift Secret with the following command, so long as you are logged in as a cluster-admin

```bash
oc create secret generic gitlab-oauth-client-secret --from-literal=clientSecret=$GITLAB_CREDENTIAL_CLIENT_SECRET -n openshift-config
```

### 2. [Optional] Create an OpenShift ConfigMap for the Private GitLab CA Certificate

If you're connecting to a private GitLab instance, OpenShift will need the CA Certificate chain to validate connections.  Provide that with the following command:

```bash
oc create configmap gitlab-ca-config-map --from-file=ca.crt=$GITLAB_CA_CERT_PEM_FILE -n openshift-config
```

### 3. Create the YAML for the OAuth Custom Resource

With the Secret created, you can now reference it in the YAML definition of the OAuth provider:

https://docs.openshift.com/container-platform/4.8/authentication/identity_providers/configuring-gitlab-identity-provider.html#identity-provider-gitlab-CR_configuring-gitlab-identity-provider

- Replace the ***CLIENT_ID_HERE*** text in the following YAML with whatever your Client ID is:

```yaml
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: gitlab
    mappingMethod: claim
    type: GitLab
    gitlab:
      clientID: CLIENT_ID_HERE
      clientSecret:
        name: gitlab-oauth-client-secret
```

***Notes:***

- The `.spec.identityProviders[0].name` is the same as the IdP Name prefixed to the end of the Authorized Redirect URI that was created in GitLab OAuth Application Client Registration earlier
- There are other options available to specify such as Organization and Team filters
- If this is a private GitLab Enterprise instance then you also need to define the `.spec.identityProviders[0].gitlab.ca.name` parameter

### 4. Apply the YAML to the OpenShift Cluster

With the YAML created, we can apply it to the cluster now with the following command, assuming you saved it to a file called oauth.yaml:

> ***WARNING*** The following command may overwrite your current IdP settings!

```bash
oc patch OAuth cluster --patch-file oauth.yaml
```

### 5. ???????

### 6. PROFIT!!!!!1

Once the Authentication Operator has restarted you should be able to log into the cluster with GitLab Authentication!