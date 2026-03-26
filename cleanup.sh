#!/bin/bash

set -e

echo "====================================================================="
echo "Cleanup Script for Bug #1208 Reproduction"
echo "====================================================================="
echo ""

# CONFIG
## Region is the AWS region where the cluster is
REGION=us-west-2

# Load saved state if it exists
if [ -f .bug-reproduction-state ]; then
  echo "Loading saved state from .bug-reproduction-state..."
  source .bug-reproduction-state
  echo "  Managed SG: $MANAGED_SG"
  echo "  Custom SG:  $CUSTOM_SG"
  echo "  LB Name:    $LB_NAME"
  echo "  Region:     $REGION"
  echo ""
fi

# Step 1: Delete the service
echo "Step 1: Deleting the service and load balancer..."
if oc get svc test-clb-service >/dev/null 2>&1; then
  oc delete -f 1-initial-service.yaml
  echo "Service deleted. Waiting for load balancer to be removed..."

  # Wait for load balancer to be deleted
  for i in {1..30}; do
    if aws elb describe-load-balancers --load-balancer-names $LB_NAME --region $REGION 2>/dev/null >/dev/null; then
      echo -n "."
      sleep 5
    else
      echo ""
      echo "✓ Load balancer deleted"
      break
    fi
  done
  echo ""
else
  echo "Service not found, skipping..."
fi

# Give AWS a moment to fully clean up
sleep 30

# Step 2: Delete custom security group
echo ""
echo "Step 2: Deleting custom security group..."
if [ -n "$CUSTOM_SG" ]; then
  if aws ec2 describe-security-groups --group-ids $CUSTOM_SG --region $REGION >/dev/null 2>&1; then
    aws ec2 delete-security-group --group-id $CUSTOM_SG --region $REGION
    echo "✓ Deleted custom SG: $CUSTOM_SG"
  else
    echo "Custom SG not found or already deleted"
  fi
else
  echo "Custom SG ID not set, skipping..."
fi

# Step 3: Delete leaked managed security group
echo ""
echo "Step 3: Deleting leaked managed security group..."
if [ -n "$MANAGED_SG" ]; then
  if aws ec2 describe-security-groups --group-ids $MANAGED_SG --region $REGION >/dev/null 2>&1; then
    # Check if other security groups reference this one
    echo "Checking for dependencies..."
    DEPENDENT_SGS=$(aws ec2 describe-security-groups \
      --region $REGION \
      --filters "Name=ip-permission.group-id,Values=$MANAGED_SG" \
      --query 'SecurityGroups[*].GroupId' \
      --output text)

    if [ -n "$DEPENDENT_SGS" ]; then
      echo "Found security groups referencing the managed SG, removing ingress rules..."
      for DEP_SG in $DEPENDENT_SGS; do
        echo "  Removing rule from $DEP_SG..."
        aws ec2 revoke-security-group-ingress \
          --group-id $DEP_SG \
          --region $REGION \
          --ip-permissions IpProtocol=-1,UserIdGroupPairs="[{GroupId=$MANAGED_SG}]" 2>/dev/null || true
      done
    fi

    # Also check egress rules
    DEPENDENT_SGS_EGRESS=$(aws ec2 describe-security-groups \
      --region $REGION \
      --filters "Name=egress.ip-permission.group-id,Values=$MANAGED_SG" \
      --query 'SecurityGroups[*].GroupId' \
      --output text)

    if [ -n "$DEPENDENT_SGS_EGRESS" ]; then
      echo "Found security groups with egress rules to the managed SG, removing..."
      for DEP_SG in $DEPENDENT_SGS_EGRESS; do
        echo "  Removing egress rule from $DEP_SG..."
        aws ec2 revoke-security-group-egress \
          --group-id $DEP_SG \
          --region $REGION \
          --ip-permissions IpProtocol=-1,UserIdGroupPairs="[{GroupId=$MANAGED_SG}]" 2>/dev/null || true
      done
    fi

    # Now try to delete the managed SG
    echo "Attempting to delete managed SG..."
    aws ec2 delete-security-group --group-id $MANAGED_SG --region $REGION
    echo "✓ Deleted managed SG: $MANAGED_SG"
    echo ""
    echo "  This is the leaked security group that demonstrates the bug."
    echo "  In a normal scenario, this should have been deleted automatically."
  else
    echo "Managed SG not found or already deleted"
  fi
else
  echo "Managed SG ID not set, skipping..."
fi

# Clean up state file
echo ""
echo "Removing state file..."
rm -f .bug-reproduction-state

echo ""
echo "====================================================================="
echo "Cleanup complete!"
echo "====================================================================="
