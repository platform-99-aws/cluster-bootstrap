#!/bin/bash

set -eou pipefail

################
### SETTINGS ###
################

# List of clusters
BOOTSTRAP_CLUSTER="bootstrap-local-cc-00"

# Use a local kubeconfig file
export KUBECONFIG=$PWD/.kubeconfig

# Fix incorrect DNS configuration: https://github.com/k3d-io/k3d/issues/209
export K3D_FIX_DNS=1

#################
### FUNCTIONS ###
#################

create_cluster () {
  cluster=$1
  shift
  
  if ! k3d cluster list "${cluster}" >/dev/null 2>&1; then
    echo "[${cluster}]: Creating cluster..."
    if [ -f /usr/local/share/ca-certificates/custom.crt ]; then
      echo "[${cluster}]: Custom certificate found, adding volume..."
      k3d cluster create --volume /usr/local/share/ca-certificates/custom.crt:/etc/ssl/certs/custom.crt --k3s-arg '--disable=traefik@server:0' "$@" "${cluster}"
    else
      k3d cluster create --k3s-arg '--disable=traefik@server:0' "$@" "${cluster}"
    fi
  else
    echo "[${cluster}]: Cluster already exists, skipping..."
  fi
}

add_azure_managed_identity_to_vm () {
  echo "Adding Managed Identity to VM..."
  if [ -z "${AZURE_MSI_CLIENT_ID}" ]; then
    AZURE_MSI_CLIENT_ID=$(az vm identity assign --ids $(curl --silent -H 'Metadata: true' 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' | jq -r .compute.resourceId) --identities "$AZURE_MSI_RESOURCE_ID" | jq -r ".userAssignedIdentities[\"$AZURE_MSI_RESOURCE_ID\"].clientId")
  fi
}

delete_cluster () {
  cluster=$1
  shift

  echo "[${cluster}]: Deleting cluster..."
  k3d cluster list "${cluster}" >/dev/null 2>&1 && k3d cluster delete "${cluster}"
}

do_kubectl () {
  cluster="k3d-$1"
  shift

  kubectl --context "${cluster}" "$@"
}

do_helm () {
  cluster="k3d-$1"
  shift

  helm --kubeconfig "${KUBECONFIG}" --kube-context "${cluster}" "$@"
}

create_namespace () {
  local cluster_name=$1
  local namespace_name=$2 

  echo "[${cluster_name}] Creating ${namespace_name} namespace..."
  cat <<EOF | do_kubectl "${cluster_name}" apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: "${namespace_name}"
  labels:
    namespace.ssc-spc.gc.ca/purpose: platform
EOF
}

get_aks_kubeconfig () {
  if command -v az &> /dev/null; then
      echo "Azure CLI (az) is installed."
  else
      echo "Azure CLI (az) is NOT installed or not found in PATH."
      echo "Please install it from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
      exit 1
  fi

  if az account show &>/dev/null; then
    echo "Azure CLI is authenticated."
  else
      echo "Azure CLI is NOT authenticated. Please run 'az login'."
      exit 1
  fi

  echo "[${CLUSTER_NAME}] Retrieving context from cluster..."
  az aks get-credentials --resource-group "${CLUSTER_RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --file .kubeconfig  
}

validate_aws_instance_profile () {
  echo "Validating IAM Instance Profile authentication..."
  
  # Get IMDSv2 token first
  IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300" \
    --connect-timeout 2 2>/dev/null) || true
  
  # Check if we're running on an EC2 instance with an instance profile
  if [ -z "$IMDS_TOKEN" ]; then
    echo "❌ ERROR: Unable to reach EC2 instance metadata service."
    echo "   This script must run on an EC2 instance with an IAM Instance Profile attached."
    echo "   Please ensure:"
    echo "     1. You are running this on an EC2 instance"
    echo "     2. An IAM Instance Profile is attached to the instance"
    echo "     3. The instance metadata service (IMDS) is enabled"
    exit 1
  fi
  
  # Get the instance profile name using the token
  INSTANCE_PROFILE_NAME=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/)
  
  if [ -z "$INSTANCE_PROFILE_NAME" ]; then
    echo "❌ ERROR: No IAM Instance Profile attached to this EC2 instance."
    echo "   Please attach an IAM Instance Profile with the required permissions."
    exit 1
  fi
  
  echo "✅ Found IAM Instance Profile: $INSTANCE_PROFILE_NAME"
  
  # Validate we can get credentials from the instance profile
  if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "❌ ERROR: Unable to authenticate using the Instance Profile."
    echo "   Please verify the IAM role has the required permissions."
    exit 1
  fi
  
  echo "✅ Successfully authenticated using IAM Instance Profile"
}

get_eks_kubeconfig () {
  if command -v aws &> /dev/null; then
      echo "AWS CLI (aws) is installed."
  else
      echo "AWS CLI (aws) is NOT installed or not found in PATH."
      echo "Please install it from https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      exit 1
  fi

  # Validate instance profile authentication if using that method
  if [[ "${AWS_AUTH_METHOD:-static_credentials}" == "instance_profile" ]]; then
    validate_aws_instance_profile
  fi

  aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME --alias $CLUSTER_NAME
}

argocd_register_cluster () {
  local source_cluster=$1
  local destination_cluster=$2
  local arn="${3:-$2}"

  api_server=$(kubectl --context "${destination_cluster}" config view -o jsonpath="{.clusters[?(@.name == '${arn}')].cluster.server}")
  token=$(kubectl --context "${destination_cluster}" get secret -n platform-system "argocd-mgmt-token" -o jsonpath='{.data.token}' | base64 --decode)
  ca=$(kubectl --context "${destination_cluster}" get secret -n platform-system "argocd-mgmt-token" -o jsonpath='{.data.ca\.crt}')

  cat <<EOF | do_kubectl "${source_cluster}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: "${destination_cluster,,}"
  namespace: platform-management-system
  labels:
    argocd.argoproj.io/secret-type: cluster
    cluster.ssc-spc.gc.ca/use: argocd
type: Opaque
stringData:
  name: "${destination_cluster,,}"
  server: "${api_server}"
  config: |
    {
      "bearerToken": "${token}",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${ca}"
      }
    }
EOF
}
