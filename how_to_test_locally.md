# Testing the Bug Fix for Issue #1208

This guide explains how to test the fix from PR #1209 against an OpenShift Kubernetes cluster by locally running the locally built AWS CCM while overriding/shutting down the deployed AWS CCM within the cluster itself.

## Overview

The fix in PR #1209 ensures that when you add a "Bring Your Own Security Group" (BYO SG) annotation to an existing LoadBalancer service, the managed security group created by the cloud controller is properly cleaned up instead of being leaked.

## Prerequisites

- OpenShift cluster running on AWS
- `oc` CLI configured and authenticated (`kubectl` works as well, but in case you have a vanilla Kubernetes some steps might need to be slightly tweaked as some operators are missing)
- AWS CLI configured with appropriate credentials
- Go toolchain installed (for building the CCM)
- The PR branch already cloned in `../cloud-provider-aws-pr-1209`

## Step 1: Gather Cluster Information

First, collect the necessary information about your OpenShift cluster:

### 1.1 Get Cluster Infrastructure Details

```bash
# Get cluster infrastructure name (used for tagging)
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
echo "Cluster Name: $CLUSTER_NAME"

# Get AWS region
REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}')
echo "Region: $REGION"

# Get VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
  --region $REGION \
  --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
  --query 'Vpcs[0].VpcId' \
  --output text)
echo "VPC ID: $VPC_ID"

# Get a subnet ID (use any worker subnet)
SUBNET_ID=$(aws ec2 describe-subnets \
  --region $REGION \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${CLUSTER_NAME}-*-us-*" \
  --query 'Subnets[0].SubnetId' \
  --output text)
echo "Subnet ID: $SUBNET_ID"

# The Kubernetes cluster tag is the cluster name
CLUSTER_TAG="$CLUSTER_NAME"
echo "Cluster Tag: $CLUSTER_TAG"
```

### 1.2 Save Values for Later

```bash
# Save to environment file for reuse
cat > cluster-info.env <<EOF
CLUSTER_NAME=$CLUSTER_NAME
REGION=$REGION
VPC_ID=$VPC_ID
SUBNET_ID=$SUBNET_ID
CLUSTER_TAG=$CLUSTER_TAG
EOF

echo "Cluster information saved to cluster-info.env"
```

## Step 2: Build the Cloud Controller Manager with the Fix

Navigate to the PR directory and build the binary:

```bash
# Build the binary
make

# Verify the binary was created
ls -lh aws-cloud-controller-manager

# Check the current branch (should be pr-1209)
git branch --show-current
```

The binary `aws-cloud-controller-manager` will be created in the repository root.

## Step 3: Create Cloud Config File

Create a cloud configuration file for the controller:

```bash
# Load cluster information. Command assumes this repository is a sybling of the PR repo, adapt as needed
source ../aws-ccm-issue-1208/cluster-info.env

# Create cloud config
cat > cloud-config <<EOF
[Global]
Region                                          = $REGION
VPC                                             = $VPC_ID
SubnetID                                        = $SUBNET_ID
KubernetesClusterTag                            = $CLUSTER_TAG
DisableSecurityGroupIngress                     = false
ClusterServiceLoadBalancerHealthProbeMode       = Shared
ClusterServiceSharedLoadBalancerHealthProbePort = 0
EOF

echo "Cloud config created"
cat cloud-config
```

## Step 4: Scale Down the Production Cloud Controller Manager

Before running your patched version, scale down the production CCM to avoid conflicts.

**IMPORTANT:** In OpenShift, you need to scale down three components in order:
1. Cluster Version Operator (CVO) - prevents it from restoring the CCM operator
2. Cloud Controller Manager Operator - prevents it from restoring the CCM deployment
3. AWS Cloud Controller Manager - the actual controller

```bash
# Step 4.1: Scale down the Cluster Version Operator
oc scale --replicas=0 deployment.apps/cluster-version-operator -n openshift-cluster-version

# Verify CVO is scaled down
oc get pods -n openshift-cluster-version

# Step 4.2: Scale down the Cloud Controller Manager Operator
oc scale --replicas=0 deployment.apps/cluster-cloud-controller-manager-operator -n openshift-cloud-controller-manager-operator

# Verify the operator is scaled down
oc get pods -n openshift-cloud-controller-manager-operator

# Step 4.3: Scale down the AWS Cloud Controller Manager
oc scale --replicas=0 deployment.apps/aws-cloud-controller-manager -n openshift-cloud-controller-manager

# Verify the CCM is scaled down
oc get pods -n openshift-cloud-controller-manager

# Step 4.4: Delete the leader election lease to allow your local CCM to acquire leadership immediately
oc delete lease cloud-controller-manager -n openshift-cloud-controller-manager
```

**IMPORTANT:** Remember to scale all three back up when you're done testing (see Step 8)!

## Step 5: Run the Patched Cloud Controller Manager

Run the locally built CCM with the fix:

```bash
# Make sure you're in the cloud-provider-aws-pr-1209 directory
cd ../cloud-provider-aws-pr-1209

# Run the controller
./aws-cloud-controller-manager -v=2 \
    --cloud-config="./cloud-config" \
    --kubeconfig="${KUBECONFIG}" \
    --cloud-provider=aws \
    --use-service-account-credentials=true \
    --configure-cloud-routes=false \
    --leader-elect=true \
    --leader-elect-lease-duration=137s \
    --leader-elect-renew-deadline=107s \
    --leader-elect-retry-period=26s \
    --leader-elect-resource-namespace=openshift-cloud-controller-manager
```

Leave this running in the terminal. You should see logs indicating it's running and managing resources.

## Step 6: Test the Fix

In a **new terminal**, run the bug reproduction test to verify the fix works:

```bash
# Run the reproduction script
./reproduce-bug.sh
```

### Expected Behavior with the Fix

If the fix works correctly, the reproduction script should show:

```
=== BUG VERIFICATION CHECKS ===

1. Checking if managed SG still exists:
   ✗ Managed SG was deleted (unexpected - bug NOT reproduced)

2. Checking network interfaces attached to managed SG:
   (skipped)

3. Checking if managed SG is still on the load balancer:
   ✓ Managed SG is NOT on the LB anymore

4. Checking if custom SG is now on the load balancer:
   ✓ Custom SG is attached to LB: sg-XXXXX

===================================================================
SUMMARY
===================================================================
⚠️  BUG NOT REPRODUCED

The expected bug behavior was not observed.
This could mean the bug has been fixed or the environment is different.
```

The key difference is that the managed SG should be **deleted** when the BYO SG annotation is added, rather than being orphaned.

### Monitor the CCM Logs

In the terminal running the CCM, watch for log messages related to security group cleanup when you apply the BYO SG annotation. You should see messages about deleting the managed security group.

## Step 7: Clean Up Test Resources

After testing:

```bash
# Clean up the test resources
./cleanup.sh
```

## Step 8: Restore Production Cloud Controller Manager

Stop the local CCM (Ctrl+C) and restore the production components in reverse order:

```bash
# Step 8.1: Stop your local CCM (press Ctrl+C in the terminal running it)

# Step 8.2: Scale back up the AWS Cloud Controller Manager
oc scale --replicas=2 deployment.apps/aws-cloud-controller-manager -n openshift-cloud-controller-manager

# Verify the CCM is starting
oc get pods -n openshift-cloud-controller-manager

# Step 8.3: Scale back up the Cloud Controller Manager Operator
oc scale --replicas=1 deployment.apps/cluster-cloud-controller-manager-operator -n openshift-cloud-controller-manager-operator

# Verify the operator is running
oc get pods -n openshift-cloud-controller-manager-operator

# Step 8.4: Scale back up the Cluster Version Operator
oc scale --replicas=1 deployment.apps/cluster-version-operator -n openshift-cluster-version

# Verify CVO is running
oc get pods -n openshift-cluster-version

# Step 8.5: Delete the lease to force the production CCM to re-acquire leadership
oc delete lease cloud-controller-manager -n openshift-cloud-controller-manager

# Step 8.6: Wait and verify everything is running
oc get pods -n openshift-cloud-controller-manager -w
```
