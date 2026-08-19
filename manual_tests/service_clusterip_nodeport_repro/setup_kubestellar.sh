#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# --- Default Variables ---
CLUSTER_NAME="edge" # Workload cluster: <name>-1 only for this repro
HOST_CLUSTER_NAME="kubeflex"
HOST_PORT="9443"
KUBESTELLAR_VERSION="0.29.0"
KIND_SCRIPT_PATH="create-kind-cluster-with-SSL-passthrough.sh"
CUSTOM_KUBECONFIG="${HOME}/.kube/kubeflex"

# Cleanup defaults
PERFORM_CLEANUP=true
CLEANUP_ONLY=false

# --- Helper Functions ---

display_usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --name <name>         Workload cluster name will be <name>-1 (default: edge → edge-1)"
    echo "  --host-name <name>    Hosting Kind cluster name (default: kubeflex)"
    echo "  --port <port>         KubeFlex SSL passthrough port (default: 9443)"
    echo "  --kubeconfig <path>   Path to the kubeconfig file to use (default: ~/.kube/kubeflex)"
    echo "  --no-cleanup          Skip the default cleanup step"
    echo "  --cleanup-only        Wipe resources and exit without installing"
    echo "  --help                Display this help message"
    exit 1
}

cleanup_resources() {
    echo "=================================================="
    echo "CLEANUP INITIATED: Wiping clusters and contexts..."
    echo "Target Kubeconfig: $CUSTOM_KUBECONFIG"
    echo "=================================================="

    # 1. Delete Host Cluster
    echo "Deleting Host Cluster: ${HOST_CLUSTER_NAME}..."
    kind delete cluster --name "${HOST_CLUSTER_NAME}" --kubeconfig "${CUSTOM_KUBECONFIG}" || true

    # 2. Delete Workload Clusters (Iterating the dynamic list)
    for cluster in "${WORKLOAD_CLUSTERS[@]}"; do
        echo "Deleting Workload Cluster: ${cluster}..."
        kind delete cluster --name "${cluster}" --kubeconfig "${CUSTOM_KUBECONFIG}" || true
    done

    # 3. Delete Virtual Contexts (ITS/WDS)
    echo "Cleaning up KubeStellar contexts..."
    kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" config delete-context its1 > /dev/null 2>&1 || true
    kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" config delete-context wds1 > /dev/null 2>&1 || true
    
    # 4. Double check cleanup of renamed contexts
    for cluster in "${WORKLOAD_CLUSTERS[@]}"; do
         kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" config delete-context "${cluster}" > /dev/null 2>&1 || true
    done

    rm -f "${CUSTOM_KUBECONFIG}"
    touch "${CUSTOM_KUBECONFIG}"

    echo "Cleanup complete."
    echo "--------------------------------------------------"
}

# --- Argument Parsing ---

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --name) CLUSTER_NAME="$2"; shift ;;
        --host-name) HOST_CLUSTER_NAME="$2"; shift ;;
        --port) HOST_PORT="$2"; shift ;;
        --kubeconfig) CUSTOM_KUBECONFIG="$2"; shift ;;
        --no-cleanup) PERFORM_CLEANUP=false ;;
        --cleanup-only) PERFORM_CLEANUP=true; CLEANUP_ONLY=true ;;
        --help) display_usage ;;
        *) echo "Unknown parameter passed: $1"; display_usage ;;
    esac
    shift
done

echo "Using Workload Prefix: $CLUSTER_NAME"
echo "Using Host Cluster: $HOST_CLUSTER_NAME"
echo "Using Host Port: $HOST_PORT"
echo "Using Kubeconfig Path: $CUSTOM_KUBECONFIG"
# --- Dynamic Variable Configuration ---
# This repro uses a single WEC: edge-1
WORKLOAD_CLUSTERS=("${CLUSTER_NAME}-1")

# Ensure the directory for the kubeconfig exists
mkdir -p "$(dirname "$CUSTOM_KUBECONFIG")"

# --- Main Execution ---

# 1. Perform Cleanup (Default: True)
if [ "$PERFORM_CLEANUP" = true ]; then
    cleanup_resources
    if [ "$CLEANUP_ONLY" = true ]; then
        echo "Cleanup-only requested. Exiting."
        exit 0
    fi
else
    echo "Skipping cleanup step (--no-cleanup flag used)."
fi

echo "=================================================="
echo "Starting KubeStellar Setup Scenario"
echo "Host Cluster: ${HOST_CLUSTER_NAME}"
echo "Member Clusters: ${WORKLOAD_CLUSTERS[*]}"
echo "Using Kubeconfig: $CUSTOM_KUBECONFIG"
echo "=================================================="

# 2. Verify External Script
if [ ! -f "$KIND_SCRIPT_PATH" ]; then
    echo "Error: Script '${KIND_SCRIPT_PATH}' not found."
    echo "Please ensure you are running this from the correct directory."
    exit 1
fi

# 3. Create the Hosting Cluster
echo "Creating Kind cluster ${HOST_CLUSTER_NAME} with SSL passthrough..."

# EXCEPTION: We must use the env var here because the external script 
# does not accept a --kubeconfig argument.
KUBECONFIG="${CUSTOM_KUBECONFIG}" bash "$KIND_SCRIPT_PATH" --name "${HOST_CLUSTER_NAME}" --port "${HOST_PORT}"


# 4. Initialize KubeFlex and create ITS and WDS
echo "--------------------------------------------------"
echo "Installing KubeStellar Core Helm Chart (v${KUBESTELLAR_VERSION})..."
helm upgrade --install ks-core oci://ghcr.io/kubestellar/kubestellar/core-chart \
    --version "${KUBESTELLAR_VERSION}" \
    --kubeconfig "${CUSTOM_KUBECONFIG}" \
    --set-json ITSes='[{"name":"its1"}]' \
    --set-json WDSes='[{"name":"wds1"}]' \
    --set verbosity.default=5 \
    --set "kubeflex-operator.externalPort=${HOST_PORT}" \
    --set "kubeflex-operator.hostContainer=${HOST_CLUSTER_NAME}-control-plane"


# 5. Configure KubeConfig Contexts
echo "--------------------------------------------------"
echo "Configuring KubeFlex contexts..."
kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" config use-context "kind-${HOST_CLUSTER_NAME}"

# Kflex using -k flag
kflex ctx --set-current-for-hosting -k "${CUSTOM_KUBECONFIG}"
kflex ctx --overwrite-existing-context its1 -k "${CUSTOM_KUBECONFIG}"
kflex ctx --overwrite-existing-context wds1 -k "${CUSTOM_KUBECONFIG}"


# 6. Wait for ITS Initialization
echo "--------------------------------------------------"
echo "Waiting for ITS (its1) to be fully initialized..."
sleep 200s

echo "Waiting for its-hub-init hook..."
kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" --context "kind-${HOST_CLUSTER_NAME}" wait controlplane.tenancy.kflex.kubestellar.org/its1 \
    --for 'jsonpath={.status.postCreateHooks.its-hub-init}=true' --timeout 200s

echo "Waiting for its-hub-init job completion..."
kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" --context "kind-${HOST_CLUSTER_NAME}" wait -n its1-system job.batch/its-hub-init \
    --for condition=Complete --timeout 200s

echo "Waiting for install-status-addon hook..."
kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" --context "kind-${HOST_CLUSTER_NAME}" wait controlplane.tenancy.kflex.kubestellar.org/its1 \
    --for 'jsonpath={.status.postCreateHooks.install-status-addon}=true' --timeout 200s

echo "Waiting for install-status-addon job completion..."
kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" --context "kind-${HOST_CLUSTER_NAME}" wait -n its1-system job.batch/install-status-addon \
    --for condition=Complete --timeout 200s

echo "ITS initialization complete."


# 7. Create and Register Workload Execution Clusters
echo "--------------------------------------------------"
echo "Creating and Registering Workload Clusters..."

FLAGS="--force-internal-endpoint-lookup"

for cluster in "${WORKLOAD_CLUSTERS[@]}"; do
    echo "Processing ${cluster}..."
    
    # Check if cluster exists
    if kind get clusters | grep -q "^${cluster}$"; then
        echo "Cluster ${cluster} already exists. Skipping creation."
    else
        # Explicit --kubeconfig flag for creation
        kind create cluster --name "${cluster}" --kubeconfig "${CUSTOM_KUBECONFIG}"
    fi

    # Rename context
    kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" config rename-context "kind-${cluster}" "${cluster}"

    # Generate Join Token and Execute Join Command
    echo "Registering ${cluster} with ITS1..."
    
    # Inject --kubeconfig into the generated command via awk
    JOIN_CMD=$(clusteradm --kubeconfig "${CUSTOM_KUBECONFIG}" --context its1 get token | grep '^clusteradm join' | sed "s/<cluster_name>/${cluster}/" | awk -v kc="${CUSTOM_KUBECONFIG}" '{print $0 " --context '${cluster}' --singleton '${FLAGS}' --kubeconfig " kc}')

    echo "Executing command: $JOIN_CMD"
    
    # Execute the constructed command
    eval "$JOIN_CMD"
done


# 8. Wait for CSRs
echo "--------------------------------------------------"
echo "Waiting for CSRs to appear in ITS1..."

while true; do
    PENDING_COUNT=$(kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" --context its1 get csr | grep -c Pending || true)
    REQUIRED_COUNT=${#WORKLOAD_CLUSTERS[@]}
    
    echo "Found $PENDING_COUNT pending CSRs (Need $REQUIRED_COUNT)..."
    
    if [ "$PENDING_COUNT" -ge "$REQUIRED_COUNT" ]; then
        echo "All required CSRs found."
        break
    fi
    
    echo "Waiting 5 seconds..."
    sleep 5
done


# 9. Approve CSRs
echo "--------------------------------------------------"
echo "Approving CSRs..."
for cluster in "${WORKLOAD_CLUSTERS[@]}"; do
    clusteradm --kubeconfig "${CUSTOM_KUBECONFIG}" --context its1 accept --clusters "${cluster}"
done


# 10. Verify and Label Clusters
echo "--------------------------------------------------"
echo "Verifying and Labeling Clusters..."
kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" --context its1 get managedclusters

# Dynamic Labeling Loop
for cluster in "${WORKLOAD_CLUSTERS[@]}"; do
    echo "Labeling ${cluster}..."
    
    # Reset LABELS for this iteration
    LABELS=""

    case "$cluster" in
        "${CLUSTER_NAME}-1")
            LABELS="region=us env=dev gpu=true"
            ;;
        *)
            echo "Warning: No specific config found for $cluster. Applying base labels only."
            ;;
    esac

    # Run kubectl command unconditionally. 
    # $LABELS will expand to nothing if empty, so base tags still get applied.
    kubectl --kubeconfig "${CUSTOM_KUBECONFIG}" --context its1 \
        label managedcluster "${cluster}" \
        location-group=edge \
        name="${cluster}" \
        $LABELS \
        --overwrite
done

echo "=================================================="
echo "Setup Complete!"
echo "Configuration saved to: $CUSTOM_KUBECONFIG"
echo "Contexts available: kind-${HOST_CLUSTER_NAME}, its1, wds1, ${WORKLOAD_CLUSTERS[*]}"
echo "=================================================="
