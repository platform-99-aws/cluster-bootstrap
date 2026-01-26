#!/bin/bash

set -eou pipefail

# Steps:
# 1. Install the argocd-operator chart within the argo-operator-system namespace
# 2. Install the argocd-instance chart within the platform-management-system namespace
# 3. Install the aurora-platform chart within the platform-management-system namespace
# 4. Create an image pull secret and attach it to every service account within the platform-management-system namespace
# 5. Wait for Argo CD credentials

# Validate input
source input.sh
# Load utils
source common.sh

echo "Creating ${BOOTSTRAP_CLUSTER} cluster..."
create_cluster "${BOOTSTRAP_CLUSTER}" --k3s-arg "--kube-apiserver-arg=--service-node-port-range=30000-30050@server:0" -p "30000-30050:30000-30050@server:0"

echo "[${BOOTSTRAP_CLUSTER}] Creating Labels..."
do_kubectl "${BOOTSTRAP_CLUSTER}" label node "k3d-${BOOTSTRAP_CLUSTER}-server-0" node.ssc-spc.gc.ca/purpose=system --overwrite

create_namespace $BOOTSTRAP_CLUSTER "argo-operator-system"
create_namespace $BOOTSTRAP_CLUSTER "platform-system"
create_namespace $BOOTSTRAP_CLUSTER "platform-management-system"

echo [Adding Helm Repositories...]
helm repo add aurora $HELM_REGISTRY --force-update

#############################
### argocd-operator chart ###
#############################

echo ""
echo "[${BOOTSTRAP_CLUSTER}] Installing Argo CD Operator in argo-operator-system..."
do_helm "${BOOTSTRAP_CLUSTER}" \
  -n argo-operator-system \
  upgrade \
  --install \
  --atomic \
  --history-max 2 \
  -f base/argocd-operator.yaml \
  argo-operator \
  aurora/argocd-operator

##############################
### argocd-instance chart  ###
##############################

if [[ "${CSP,,}" == "azure" ]]; then
  # Adding Managed Identity
  # Note we pass Client ID for the AAD Pod Identity / AVP
  add_azure_managed_identity_to_vm
fi 

echo ""
echo "[${BOOTSTRAP_CLUSTER}] Installing Argo CD instance in platform-management-system..."
envsubst < "base/${CSP,,}/argocd-instance.yaml" | \
do_helm "${BOOTSTRAP_CLUSTER}" \
  -n platform-management-system \
  upgrade \
  --install \
  --atomic \
  --history-max 2 \
  -f - \
  --force \
  --version $ARGOCD_INSTANCE_HELM_CHART_VERSION \
  argocd-instance \
  aurora/argocd-instance

#############################
### aurora-platform chart ###
#############################

echo ""
echo "[${BOOTSTRAP_CLUSTER}] Installing Aurora platform in platform-management-system..." 
envsubst < "base/${CSP,,}/platform-aurora.yaml" | \
do_helm "${BOOTSTRAP_CLUSTER}" \
  -n platform-management-system \
  upgrade \
  --install \
  --atomic \
  --history-max 2 \
  -f - \
  --force \
  --version $AURORA_PLATFORM_HELM_CHART_VERSION \
  aurora-platform \
  aurora/aurora-platform

#########################
### Image Pull Secret ###
#########################

echo ""
if [[ -n "$IMAGE_PULL_SECRET" ]]; then
  echo "[${BOOTSTRAP_CLUSTER}] Installing Image Pull Secret..."
  cat <<EOF | do_kubectl "${BOOTSTRAP_CLUSTER}" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aurora-image-pull-secret
  namespace: platform-management-system
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: >-
    ${IMAGE_PULL_SECRET}
EOF

  echo "[${BOOTSTRAP_CLUSTER}] Adding Image Pull Secret to Service Accounts for Argo CD..."
  NAMESPACE="platform-management-system"
  SECRET_NAME="aurora-image-pull-secret"
  SERVICE_ACCOUNTS=$(do_kubectl "${BOOTSTRAP_CLUSTER}" get serviceaccounts -n "$NAMESPACE" --no-headers -o custom-columns=':.metadata.name')

  for SA in $SERVICE_ACCOUNTS; do
    CURRENT_SECRETS=$(do_kubectl "${BOOTSTRAP_CLUSTER}" get serviceaccount "$SA" -n "$NAMESPACE" -o jsonpath="{.imagePullSecrets[*].name}")
    if [[ "$CURRENT_SECRETS" != *"$SECRET_NAME"* ]]; then
      do_kubectl "${BOOTSTRAP_CLUSTER}" patch serviceaccount "$SA" -n "$NAMESPACE" -p '{"imagePullSecrets": [{"name": "'$SECRET_NAME'"}]}'
      echo "Added imagePullSecret '$SECRET_NAME' to ServiceAccount '$SA'"
    else
      echo "ImagePullSecret '$SECRET_NAME' already exists in ServiceAccount '$SA'"
    fi
  done
else
  echo "[${BOOTSTRAP_CLUSTER}] Skipping Image Pull Secret setup as IMAGE_PULL_SECRET is empty."
fi

########################
### Register Cluster ###
########################

echo ""
echo "Registering cluster"

arn=""
if [[ "${CSP,,}" == "azure" ]]; then
  get_aks_kubeconfig
elif [[ "${CSP,,}" == "aws" ]]; then
  get_eks_kubeconfig
  arn=$(aws eks describe-cluster --region $AWS_REGION --name $CLUSTER_NAME --query "cluster.arn" --output text)
fi 

argocd_register_cluster $BOOTSTRAP_CLUSTER $CLUSTER_NAME $arn

##################################
### Output Argo CD Credentials ###
##################################

#Output credentials for Argo CD
echo
echo "=================================="
echo

until do_kubectl "${BOOTSTRAP_CLUSTER}" get service -n platform-management-system argocd-server >/dev/null 2>&1; do
  sleep 0
done

argocd_port=$(do_kubectl "${BOOTSTRAP_CLUSTER}" get service -n platform-management-system argocd-server -o jsonpath='{.spec.ports[?(@.name == "https")].nodePort}')

until do_kubectl "${BOOTSTRAP_CLUSTER}" get secret -n platform-management-system argocd-cluster >/dev/null 2>&1; do
  sleep 0
done

argocd_password=$(do_kubectl "${BOOTSTRAP_CLUSTER}" get secret -n platform-management-system argocd-cluster -o jsonpath='{.data.admin\.password}' | base64 --decode)

echo "Argo CD: http://127.0.0.1:$argocd_port"
echo "  Username: admin"
echo "  Password: $argocd_password"
