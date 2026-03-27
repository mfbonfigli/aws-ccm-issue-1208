#!/bin/bash

set -e

echo "====================================================================="
echo "Kubernetes Cloud Provider AWS Bug #1208 Reproduction Script"
echo "Security Group Leak When Adding BYO SG Annotation"
echo "====================================================================="
echo ""

# CONFIG
## Region is the AWS region where the cluster is
REGION=us-west-2

# Step 1: Create the initial service
echo "Step 1: Creating LoadBalancer service without custom security groups..."
kubectl apply -f 1-initial-service.yaml

echo "Waiting for LoadBalancer to be provisioned (this may take 2-3 minutes)..."
for i in {1..60}; do
  LB_DNS=$(kubectl get svc test-clb-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "$LB_DNS" ]; then
    echo "✓ LoadBalancer provisioned: $LB_DNS"
    break
  fi
  echo -n "."
  sleep 5
done
echo ""

if [ -z "$LB_DNS" ]; then
  echo "✗ Error: LoadBalancer not provisioned after 5 minutes"
  exit 1
fi

# Step 2: Identify the managed security group
echo ""
echo "Step 2: Identifying the auto-generated managed security group..."
LB_NAME=$(echo $LB_DNS | cut -d'-' -f1)
echo "Load Balancer Name: $LB_NAME"

# Wait a bit more for AWS to fully configure the LB
sleep 10

MANAGED_SG=$(aws elb describe-load-balancers --load-balancer-names $LB_NAME --query 'LoadBalancerDescriptions[0].SecurityGroups[0]' --output text --region $REGION)
echo "Managed Security Group: $MANAGED_SG"

echo ""
echo "Managed SG Tags:"
aws ec2 describe-security-groups --group-ids $MANAGED_SG --query 'SecurityGroups[0].Tags' --output table --region $REGION

# Step 3: Create custom security group
echo ""
echo "Step 3: Creating custom security group (BYO SG)..."
VPC_ID=$(aws ec2 describe-security-groups --group-ids $MANAGED_SG --query 'SecurityGroups[0].VpcId' --output text --region $REGION)
echo "VPC ID: $VPC_ID"

CUSTOM_SG=$(aws ec2 create-security-group \
  --group-name test-byo-sg-$(date +%s) \
  --description "Custom SG for bug 1208 reproduction" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text \
  --region $REGION)

echo "Custom Security Group: $CUSTOM_SG"

# Add ingress rules
echo "Adding ingress rules to custom SG..."
aws ec2 authorize-security-group-ingress \
  --group-id $CUSTOM_SG \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region $REGION > /dev/null

# Step 4: Patch the service with BYO SG annotation
echo ""
echo "Step 4: Adding BYO security group annotation to the service..."
kubectl annotate svc test-clb-service service.beta.kubernetes.io/aws-load-balancer-security-groups=$CUSTOM_SG

echo "Waiting for reconciliation (60 seconds)..."
sleep 60

# Step 5: Verify the bug
echo ""
echo "====================================================================="
echo "Step 5: BUG VERIFICATION"
echo "====================================================================="
echo ""

echo "Current security groups on load balancer:"
aws elb describe-load-balancers --load-balancer-names $LB_NAME --query 'LoadBalancerDescriptions[0].SecurityGroups' --output table --region $REGION

echo ""
echo "=== BUG VERIFICATION CHECKS ==="
echo ""

# Check 1: Managed SG still exists
echo "1. Checking if managed SG still exists:"
if aws ec2 describe-security-groups --group-ids $MANAGED_SG --query 'SecurityGroups[0].GroupId'  --region $REGION --output text 2>/dev/null >/dev/null; then
  echo "   ✓ Managed SG still exists: $MANAGED_SG"
  MANAGED_SG_EXISTS=true
else
  echo "   ✗ Managed SG was deleted (unexpected - bug NOT reproduced)"
  MANAGED_SG_EXISTS=false
fi

# Check 2: Managed SG has no network interfaces
echo ""
echo "2. Checking network interfaces attached to managed SG:"
if [ "$MANAGED_SG_EXISTS" = true ]; then
  NIC_COUNT=$(aws ec2 describe-network-interfaces --filters "Name=group-id,Values=$MANAGED_SG" --region $REGION --query 'length(NetworkInterfaces)' --output text)
  if [ "$NIC_COUNT" = "0" ]; then
    echo "   ✓ BUG CONFIRMED: Managed SG has 0 network interfaces (orphaned)"
    ORPHANED=true
  else
    echo "   ✗ Managed SG still has $NIC_COUNT network interfaces attached"
    ORPHANED=false
  fi
fi

# Check 3: Managed SG not on load balancer
echo ""
echo "3. Checking if managed SG is still on the load balancer:"
LB_SGS=$(aws elb describe-load-balancers --load-balancer-names $LB_NAME --region $REGION --query 'LoadBalancerDescriptions[0].SecurityGroups' --output text)
if echo "$LB_SGS" | grep -q "$MANAGED_SG"; then
  echo "   ✗ Managed SG is still attached to LB (bug NOT reproduced)"
  NOT_ON_LB=false
else
  echo "   ✓ Managed SG is NOT on the LB anymore"
  NOT_ON_LB=true
fi

# Check 4: Custom SG is on load balancer
echo ""
echo "4. Checking if custom SG is now on the load balancer:"
if echo "$LB_SGS" | grep -q "$CUSTOM_SG"; then
  echo "   ✓ Custom SG is attached to LB: $CUSTOM_SG"
  CUSTOM_ON_LB=true
else
  echo "   ✗ Custom SG is NOT on the LB (unexpected)"
  CUSTOM_ON_LB=false
fi

# Final verdict
echo ""
echo "====================================================================="
echo "SUMMARY"
echo "====================================================================="
echo "Managed SG ID: $MANAGED_SG"
echo "Custom SG ID:  $CUSTOM_SG"
echo ""

if [ "$MANAGED_SG_EXISTS" = true ] && [ "$ORPHANED" = true ] && [ "$NOT_ON_LB" = true ] && [ "$CUSTOM_ON_LB" = true ]; then
  echo "🐛 BUG CONFIRMED!"
  echo ""
  echo "The managed security group is LEAKED:"
  echo "  - It still exists in AWS"
  echo "  - It has NO network interfaces attached"
  echo "  - It is NOT attached to the load balancer"
  echo "  - The custom SG has replaced it on the LB"
  echo ""
  echo "This orphaned security group will remain until manually deleted."
else
  echo "⚠️  BUG NOT REPRODUCED"
  echo ""
  echo "The expected bug behavior was not observed."
  echo "This could mean the bug has been fixed or the environment is different."
fi

echo ""
echo "====================================================================="
echo "To clean up, run: ./cleanup.sh"
echo "====================================================================="

# Save IDs for cleanup
cat > .bug-reproduction-state <<EOF
MANAGED_SG=$MANAGED_SG
CUSTOM_SG=$CUSTOM_SG
LB_NAME=$LB_NAME
REGION=$REGION
EOF

echo ""
echo "Environment state saved to .bug-reproduction-state"
