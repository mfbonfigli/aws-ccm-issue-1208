# Kubernetes Cloud Provider AWS Bug #1208 Reproduction Guide

## Bug Summary
Security group leak when adding `service.beta.kubernetes.io/aws-load-balancer-security-groups` annotation to an existing CLB service.

Ref: https://github.com/kubernetes/cloud-provider-aws/issues/1208

## Prerequisites
- OpenShift/Kubernetes cluster running on AWS
- oc or kubectl CLI configured and logged in to the cluster
- AWS CLI configured with appropriate credentials
- Access to create services and security groups

## Reproduction Steps

### Step 1: Create Initial CLB Service
Create a LoadBalancer service WITHOUT custom security groups. The AWS cloud provider will auto-generate a managed security group.

**Using oc:**
```bash
oc apply -f 1-initial-service.yaml
```

**Using kubectl:**
```bash
kubectl apply -f 1-initial-service.yaml
```

Wait for the service to get an external IP:

**Using oc:**
```bash
oc get svc test-clb-service -w
```

**Using kubectl:**
```bash
kubectl get svc test-clb-service -w
```

### Step 2: Identify the Managed Security Group
Once the LoadBalancer is created, identify the auto-generated security group:

**Using oc:**
```bash
# Get the load balancer DNS name from the service
LB_DNS=$(oc get svc test-clb-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Load Balancer DNS: $LB_DNS"

# Extract the load balancer name (everything before the first dot)
LB_NAME=$(echo $LB_DNS | cut -d'.' -f1)
echo "Load Balancer Name: $LB_NAME"

# Find the load balancer and its security groups
aws elb describe-load-balancers --load-balancer-names $LB_NAME --query 'LoadBalancerDescriptions[0].SecurityGroups' --output text

# Save the security group ID
MANAGED_SG=$(aws elb describe-load-balancers --load-balancer-names $LB_NAME --query 'LoadBalancerDescriptions[0].SecurityGroups[0]' --output text)
echo "Managed Security Group: $MANAGED_SG"

# Verify the managed SG has the kubernetes.io/cluster tag
aws ec2 describe-security-groups --group-ids $MANAGED_SG --query 'SecurityGroups[0].Tags'
```

**Using kubectl:**
```bash
# Get the load balancer DNS name from the service
LB_DNS=$(kubectl get svc test-clb-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Load Balancer DNS: $LB_DNS"

# Extract the load balancer name (everything before the first dot)
LB_NAME=$(echo $LB_DNS | cut -d'.' -f1)
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

**Using oc:**
```bash
oc annotate svc test-clb-service service.beta.kubernetes.io/aws-load-balancer-security-groups=$CUSTOM_SG
```

**Using kubectl:**
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
- ✅ Still exist in AWS
- ❌ NOT be attached to any network interfaces
- ❌ NOT be attached to the load balancer anymore

This is the bug: the managed SG is leaked and not cleaned up when BYO SG is added.

## Expected Behavior
The managed security group should be automatically deleted when the BYO security group annotation is added.

## Cleanup

### Automated Cleanup (Recommended)
Use the cleanup script which handles dependencies automatically:

```bash
./cleanup.sh
```

The cleanup script will:
1. Delete the service and wait for the load balancer to be removed
2. Wait 30 seconds for AWS to detach network interfaces
3. Delete the custom security group
4. Remove any ingress/egress rules from other security groups that reference the managed SG
5. Delete the leaked managed security group

### Manual Cleanup

**Using oc:**
```bash
# Delete the service (this should clean up the load balancer)
oc delete -f 1-initial-service.yaml

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

**Using kubectl:**
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

### Troubleshooting Cleanup

**Error: "DependencyViolation: resource has a dependent object"**

This occurs when other security groups have ingress or egress rules that reference the managed SG. Common in OpenShift clusters where the cluster's load balancer security group may reference the leaked SG.

To troubleshoot:
```bash
# Find which SGs reference the managed SG (ingress rules)
aws ec2 describe-security-groups \
  --region us-west-2 \
  --filters "Name=ip-permission.group-id,Values=$MANAGED_SG" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' --output table

# Find which SGs reference the managed SG (egress rules)
aws ec2 describe-security-groups \
  --region us-west-2 \
  --filters "Name=egress.ip-permission.group-id,Values=$MANAGED_SG" \
  --query 'SecurityGroups[*].[GroupId,GroupName]' --output table

# Remove the ingress rule (replace <DEPENDENT_SG> with the actual SG ID)
aws ec2 revoke-security-group-ingress \
  --group-id <DEPENDENT_SG> \
  --region us-west-2 \
  --ip-permissions IpProtocol=-1,UserIdGroupPairs="[{GroupId=$MANAGED_SG}]"

# Then delete the managed SG
aws ec2 delete-security-group --group-id $MANAGED_SG --region us-west-2
```

## Quick Run Scripts

### Reproduce the Bug
For convenience, you can use the automated script (uses oc):
```bash
./reproduce-bug.sh
```

### Clean Up
Use the cleanup script to automatically remove all resources:
```bash
./cleanup.sh
```

**Note:** The cleanup script automatically handles dependency violations by removing ingress/egress rules from other security groups that reference the leaked managed SG before deletion.

## Additional Notes
- The bug occurs because the controller replaces security groups in-place without cleanup logic
- The issue is in `aws_loadbalancer.go` lines 1084-1104 in the cloud-provider-aws repository
- This can accumulate orphaned security groups over time, leading to AWS quota issues
- OpenShift uses the upstream Kubernetes cloud-provider-aws, so this bug affects OpenShift on AWS as well
