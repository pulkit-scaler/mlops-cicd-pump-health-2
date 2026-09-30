#!/usr/bin/env bash
# Deletes everything infra/up.sh and the session created, in both environments.
#
#     infra/down.sh
#
# Safe to run twice. The task execution role ecsTaskExecutionRole is left in
# place, because it costs nothing and every ECS deployment uses it.
set -uo pipefail
cd "$(dirname "$0")/.."
source infra/lookup.sh
SECONDS=0

# Services, then load balancers, then target groups, in both environments
for pair in mlops-cluster:pump-health mlops-staging:pump-health-staging; do
  CLUSTER=${pair%%:*}; NAME=${pair#*:}
  STATUS=$(aws ecs describe-services --cluster "$CLUSTER" --services "$NAME" --query 'services[0].status' --output text 2>/dev/null)
  if [ "$STATUS" = ACTIVE ]; then
    aws ecs delete-service --cluster "$CLUSTER" --service "$NAME" --force >/dev/null
    aws ecs wait services-inactive --cluster "$CLUSTER" --services "$NAME"
  fi
  ALB=$(q elbv2 describe-load-balancers --names "$NAME-alb" --query 'LoadBalancers[0].LoadBalancerArn')
  [ -n "$ALB" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" &&
    aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB"
  TG=$(q elbv2 describe-target-groups --names "$NAME-tg" --query 'TargetGroups[0].TargetGroupArn')
  if [ -n "$TG" ]; then
    # The listener goes a few seconds after the load balancer, so the delete is retried.
    for try in $(seq 12); do aws elbv2 delete-target-group --target-group-arn "$TG" 2>/dev/null && break; sleep 10; done
  fi
  for td in $(aws ecs list-task-definitions --family-prefix "$NAME" --query 'taskDefinitionArns' --output text); do
    aws ecs deregister-task-definition --task-definition "$td" >/dev/null
  done
  sleep 5
  ARNS=$(aws ecs list-task-definitions --family-prefix "$NAME" --status INACTIVE --query 'taskDefinitionArns' --output text)
  [ -n "$ARNS" ] && aws ecs delete-task-definitions --task-definitions $ARNS >/dev/null
  aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1
  aws logs delete-log-group --log-group-name "/ecs/$NAME" 2>/dev/null
  echo "$NAME deleted"
done

# The registry, the two deploy roles and the OIDC provider
aws ecr delete-repository --repository-name pump-health --force >/dev/null 2>&1
for role in github-deploy-pump-health github-deploy-pump-health-staging; do
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  aws iam delete-role --role-name "$role" 2>/dev/null
done
[ -n "$OIDC_ARN" ] && aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN"
echo "registry, roles and OIDC provider deleted"

# The network. The load balancers' network interfaces linger for a while, so each delete is retried.
for sg in "$TASK_SG" "$ALB_SG"; do
  [ -z "$sg" ] && continue
  for try in $(seq 30); do aws ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 && break; sleep 10; done
done
if [ -n "$RT_ID" ]; then
  for a in $(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
             --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text); do
    aws ec2 disassociate-route-table --association-id "$a"
  done
  aws ec2 delete-route-table --route-table-id "$RT_ID"
fi
if [ -n "$IGW_ID" ]; then
  [ -n "$VPC_ID" ] && aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
fi
for s in "$SUBNET_A" "$SUBNET_B"; do [ -n "$s" ] && aws ec2 delete-subnet --subnet-id "$s"; done
[ -n "$VPC_ID" ] && aws ec2 delete-vpc --vpc-id "$VPC_ID"
echo "network deleted, ${SECONDS} s in all"
