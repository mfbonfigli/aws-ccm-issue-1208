# Kubernetes Cloud Provider AWS Bug #1208 Reproduction Guide

## Bug Summary
Security group leak when adding `service.beta.kubernetes.io/aws-load-balancer-security-groups` annotation to an existing CLB service.

This repo documents how to reproduce the bug and how to test the fix locally.

Ref: https://github.com/kubernetes/cloud-provider-aws/issues/1208

## Prerequisites
- Kubernetes cluster running on AWS
- kubectl CLI configured and logged in to the cluster
- AWS CLI configured with appropriate credentials
- Access to create services and security groups

## Quick Run Scripts

### Reproduce the Bug
For convenience, you can use the automated script:
```bash
./reproduce-bug.sh
```

### Clean Up
Use the cleanup script to automatically remove all resources:
```bash
./cleanup.sh
```

### Test the fix
Pull the PR 1209 repo locally, then follow the steps inside `how_to_test_locally.md` to build and run locally the patched AWS CCM against a running cluster.

## Manual Reproduction Steps

This is the manual step by step procedure that explain how to reproduce the bug. The `reproduce-bug.sh` script automates the process.

### Step 1: Create Initial CLB Service
Create a LoadBalancer service WITHOUT custom security groups. The AWS cloud provider will auto-generate a managed security group.

```bash
kubectl apply -f 1-initial-service.yaml
```

Wait for the service to get an external IP:

```bash
kubectl get svc test-clb-service -w
```

### Step 2: Identify the Managed Security Group
Once the LoadBalancer is created, identify the auto-generated security group:

```bash
# Get the load balancer DNS name from the service
LB_DNS=$(kubectl get svc test-clb-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Load Balancer DNS: $LB_DNS"

# Extract the load balancer name (everything before the first dot)
LB_NAME=$(echo $LB_DNS | cut -d'-' -f1)
echo "Load Balancer Name: $LB_NAME"

# Find the load balancer and its security groups
aws elb describe-load-balancers --load-balancer-names $LB_NAME --query 'LoadBalancerDescriptions[0].SecurityGroups' --output text

# Save the security group ID
MANAGED_SG=$(aws elb describe-load-balancers --load-balancer-names $LB_NAME --query 'LoadBalancerDescriptions[0].SecurityGroups[0]' --output text)
echo "Managed Security Group: $MANAGED_SG"

# Verify the managed SG has the kubernetes.io/cluster tag
aws ec2 describe-security-groups --group-ids $MANAGED_SG --query 'SecurityGroups[0].Tags'
```

### Step 3: Create a Custom Security Group
Create a custom security group to use as "Bring Your Own" (BYO):

```bash
# Get VPC ID from the cluster
VPC_ID=$(aws ec2 describe-security-groups --group-ids $MANAGED_SG --query 'SecurityGroups[0].VpcId' --output text)
echo "VPC ID: $VPC_ID"

# Create custom security group
CUSTOM_SG=$(aws ec2 create-security-group \
  --group-name test-byo-sg-$(date +%s) \
  --description "Custom SG for bug 1208 reproduction" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text)

echo "Custom Security Group: $CUSTOM_SG"

# Add ingress rules to allow traffic (example: HTTP)
aws ec2 authorize-security-group-ingress \
  --group-id $CUSTOM_SG \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

# Add egress rules (allow all outbound by default)
aws ec2 authorize-security-group-egress \
  --group-id $CUSTOM_SG \
  --protocol -1 \
  --cidr 0.0.0.0/0 2>/dev/null || true
```

### Step 4: Patch the Service with BYO Security Group Annotation
Add the custom security group annotation to the existing service:

```bash
kubectl annotate svc test-clb-service service.beta.kubernetes.io/aws-load-balancer-security-groups=$CUSTOM_SG
```

Wait for reconciliation (may take 30-60 seconds):
```bash
echo "Waiting for reconciliation..."
sleep 60
```

### Step 5: Verify the Bug - Security Group Leak
Check that the custom SG is now attached:

```bash
echo "Current security groups on load balancer:"
aws elb describe-load-balancers --load-balancer-names $LB_NAME --query 'LoadBalancerDescriptions[0].SecurityGroups' --output table
```

**BUG VERIFICATION**: Check if the managed SG still exists but is orphaned:

```bash
echo "=== BUG VERIFICATION ==="

# The managed SG should still exist
echo "1. Checking if managed SG still exists:"
aws ec2 describe-security-groups --group-ids $MANAGED_SG --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null && echo "   ✓ Managed SG still exists: $MANAGED_SG" || echo "   ✗ Managed SG was deleted (unexpected)"

# But it should have NO network interfaces attached
echo "2. Checking network interfaces attached to managed SG:"
NIC_COUNT=$(aws ec2 describe-network-interfaces --filters "Name=group-id,Values=$MANAGED_SG" --query 'length(NetworkInterfaces)' --output text)
if [ "$NIC_COUNT" = "0" ]; then
  echo "   ✓ BUG CONFIRMED: Managed SG has 0 network interfaces (orphaned)"
else
  echo "   ✗ Managed SG still has $NIC_COUNT network interfaces attached"
fi

# Verify it's not on the load balancer anymore
echo "3. Checking if managed SG is still on the load balancer:"
LB_SGS=$(aws elb describe-load-balancers --load-balancer-names $LB_NAME --query 'LoadBalancerDescriptions[0].SecurityGroups' --output text)
if echo "$LB_SGS" | grep -q "$MANAGED_SG"; then
  echo "   ✗ Managed SG is still attached to LB"
else
  echo "   ✓ Managed SG is NOT on the LB anymore"
fi

echo ""
echo "=== SUMMARY ==="
echo "Managed SG ID: $MANAGED_SG"
echo "Custom SG ID: $CUSTOM_SG"
echo "If the managed SG exists but has no NICs and is not on the LB, the bug is confirmed."
```

### Step 6: Verify the Leak
The managed security group should:
- Still exist in AWS
- NOT be attached to any network interfaces
- NOT be attached to the load balancer anymore

This is the bug: the managed SG is leaked and not cleaned up when BYO SG is added.

## Expected Behavior
The managed security group should be automatically deleted when the BYO security group annotation is added.

## Cleanup

### Automated Cleanup (Recommended)
Use the cleanup script which handles dependencies automatically:

```bash
./cleanup.sh
```

### Manual Cleanup

```bash
# Delete the service (this should clean up the load balancer)
kubectl delete -f 1-initial-service.yaml

# Wait for LB deletion
echo "Waiting for load balancer deletion..."
sleep 30

# Delete the custom security group
aws ec2 delete-security-group --group-id $CUSTOM_SG --region us-west-2
echo "Deleted custom SG: $CUSTOM_SG"

# Check for dependencies (other SGs referencing the managed SG)
aws ec2 describe-security-groups \
  --region us-west-2 \
  --filters "Name=ip-permission.group-id,Values=$MANAGED_SG" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' --output table

# If dependencies exist, remove the ingress rules first
# Example: aws ec2 revoke-security-group-ingress --group-id <DEPENDENT_SG> --region us-west-2 --ip-permissions IpProtocol=-1,UserIdGroupPairs="[{GroupId=$MANAGED_SG}]"

# Delete the leaked managed security group
aws ec2 delete-security-group --group-id $MANAGED_SG --region us-west-2
echo "Deleted leaked managed SG: $MANAGED_SG"
```
