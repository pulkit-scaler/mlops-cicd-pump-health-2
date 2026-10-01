#!/usr/bin/env bash
# Stands up one environment of the pump health service on AWS, with the
# commands from Part 1 collected in one place.
#
#     infra/up.sh production    # Part 1's end state, and the network and registry
#     infra/up.sh staging       # a second copy: its own cluster, load balancer and service
#
# Safe to run twice. Anything that already exists is left alone. Needs the AWS
# CLI signed in to us-east-1, and Docker for the first image. production also
# needs GH_TOKEN, a GitHub token that can read this repository.
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=${1:?usage: infra/up.sh production|staging}
case "$ENV" in
  production) CLUSTER=mlops-cluster; NAME=pump-health
              : "${GH_TOKEN:?production needs GH_TOKEN, a GitHub token that can read this repository}" ;;
  staging)    CLUSTER=mlops-staging; NAME=pump-health-staging ;;
  *) echo "usage: infra/up.sh production|staging" >&2; exit 2 ;;
esac
mkdir -p scratch
source infra/lookup.sh
tag() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2}]"; }
SECONDS=0

# --- Shared by both environments: network, execution role, registry, OIDC provider
[ -z "$VPC_ID" ] && aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(tag vpc mlops-vpc)" >/dev/null
source infra/lookup.sh
[ -z "$SUBNET_A" ] && aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a --tag-specifications "$(tag subnet mlops-public-a)" >/dev/null
[ -z "$SUBNET_B" ] && aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.0.2.0/24 \
  --availability-zone us-east-1b --tag-specifications "$(tag subnet mlops-public-b)" >/dev/null
[ -z "$IGW_ID" ] && aws ec2 create-internet-gateway --tag-specifications "$(tag internet-gateway mlops-igw)" >/dev/null
[ -z "$RT_ID" ] && aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tag route-table mlops-public-rt)" >/dev/null
source infra/lookup.sh
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID" 2>/dev/null || true
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null 2>&1 || true
for s in "$SUBNET_A" "$SUBNET_B"; do
  aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$s" >/dev/null 2>&1 || true
done
[ -z "$ALB_SG" ] && aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name mlops-alb-sg \
  --description "pump-health load balancers, HTTP from anywhere" >/dev/null
[ -z "$TASK_SG" ] && aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name mlops-task-sg \
  --description "pump-health tasks, port 8000 from the load balancers only" >/dev/null
source infra/lookup.sh
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$TASK_SG" --protocol tcp --port 8000 --source-group "$ALB_SG" >/dev/null 2>&1 || true

aws iam get-role --role-name ecsTaskExecutionRole >/dev/null 2>&1 ||
  aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
aws iam attach-role-policy --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

aws ecr describe-repositories --repository-names pump-health >/dev/null 2>&1 ||
  aws ecr create-repository --repository-name pump-health --image-tag-mutability IMMUTABLE >/dev/null
[ -z "$OIDC_ARN" ] && aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com >/dev/null
source infra/lookup.sh
echo "network, registry and OIDC provider ready"

# --- One environment: cluster, logs, target group, load balancer, listener
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
aws logs create-log-group --log-group-name "/ecs/$NAME" 2>/dev/null || true
aws logs put-retention-policy --log-group-name "/ecs/$NAME" --retention-in-days 1
aws elbv2 describe-target-groups --names "$NAME-tg" >/dev/null 2>&1 ||
  aws elbv2 create-target-group --name "$NAME-tg" --vpc-id "$VPC_ID" \
    --protocol HTTP --port 8000 --target-type ip --health-check-path /health \
    --health-check-interval-seconds 10 --healthy-threshold-count 2 --unhealthy-threshold-count 3 >/dev/null
aws elbv2 describe-load-balancers --names "$NAME-alb" >/dev/null 2>&1 ||
  aws elbv2 create-load-balancer --name "$NAME-alb" --type application \
    --scheme internet-facing --subnets "$SUBNET_A" "$SUBNET_B" --security-groups "$ALB_SG" >/dev/null
aws elbv2 wait load-balancer-available --names "$NAME-alb"
TG=$(aws elbv2 describe-target-groups --names "$NAME-tg" --query 'TargetGroups[0].TargetGroupArn' --output text)
ALB=$(aws elbv2 describe-load-balancers --names "$NAME-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 modify-target-group-attributes --target-group-arn "$TG" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null
[ "$(aws elbv2 describe-listeners --load-balancer-arn "$ALB" --query 'length(Listeners)' --output text)" = 0 ] &&
  aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 80 \
    --default-actions Type=forward,TargetGroupArn="$TG" >/dev/null
echo "$ENV load balancer ready"

# --- The first image, if the registry has none for this commit yet
SHA=$(git rev-parse HEAD)
if ! aws ecr describe-images --repository-name pump-health --image-ids imageTag="$SHA" >/dev/null 2>&1; then
  aws ecr get-login-password | docker login -u AWS --password-stdin "$ECR_REGISTRY" >/dev/null 2>&1
  docker build -q --platform linux/amd64 --build-arg GIT_SHA="$SHA" -t "$ECR_URI:$SHA" . >/dev/null
  docker push -q "$ECR_URI:$SHA" >/dev/null
  echo "pushed pump-health:${SHA:0:7}"
fi

# --- The task definition and the service
cat > "scratch/taskdef-$ENV.json" <<JSON
{
  "family": "$NAME",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "runtimePlatform": {"cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX"},
  "executionRoleArn": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsTaskExecutionRole",
  "containerDefinitions": [{
    "name": "pump-health",
    "image": "${ECR_URI}:${SHA}",
    "essential": true,
    "portMappings": [{"containerPort": 8000, "protocol": "tcp"}],
    "logConfiguration": {"logDriver": "awslogs", "options": {
      "awslogs-group": "/ecs/$NAME", "awslogs-region": "us-east-1", "awslogs-stream-prefix": "ecs"}}
  }]
}
JSON
STATUS=$(aws ecs describe-services --cluster "$CLUSTER" --services "$NAME" --query 'services[0].status' --output text 2>/dev/null || true)
if [ "$STATUS" != ACTIVE ]; then
  aws ecs register-task-definition --cli-input-json "file://scratch/taskdef-$ENV.json" >/dev/null
  aws ecs create-service --cluster "$CLUSTER" --service-name "$NAME" --task-definition "$NAME" \
    --desired-count 1 --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_A,$SUBNET_B],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG,containerName=pump-health,containerPort=8000" \
    --health-check-grace-period-seconds 30 \
    --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true}" >/dev/null
fi
aws ecs wait services-stable --cluster "$CLUSTER" --services "$NAME"
echo "$ENV service $NAME stable in $CLUSTER, ${SECONDS} s in all"

# --- Production only: Part 1's deploy role, which trusts the main branch of this repository
if [ "$ENV" = production ]; then
  read OWNER_ID REPO_ID <<< "$(curl -s -H "Authorization: Bearer $GH_TOKEN" "https://api.github.com/repos/$GITHUB_REPO" |
    python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["owner"]["id"], d["id"])')"
  : "${REPO_ID:?GitHub returned no IDs. Check that GH_TOKEN can read your repository}"
  SUBJECT="repo:${GITHUB_REPO%/*}@${OWNER_ID}/${GITHUB_REPO#*/}@${REPO_ID}:ref:refs/heads/main"
  cat > scratch/github-trust-part1.json <<JSON
{"Version": "2012-10-17", "Statement": [{"Effect": "Allow",
  "Principal": {"Federated": "$OIDC_ARN"}, "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {"StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                                 "token.actions.githubusercontent.com:sub": "$SUBJECT"}}}]}
JSON
  cat > scratch/github-policy-part1.json <<JSON
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*"},
  {"Effect": "Allow", "Action": ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload",
     "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage"],
   "Resource": "arn:aws:ecr:us-east-1:${AWS_ACCOUNT_ID}:repository/pump-health"},
  {"Effect": "Allow", "Action": ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"], "Resource": "*"},
  {"Effect": "Allow", "Action": ["ecs:UpdateService", "ecs:DescribeServices"],
   "Resource": "arn:aws:ecs:us-east-1:${AWS_ACCOUNT_ID}:service/mlops-cluster/pump-health"},
  {"Effect": "Allow", "Action": "iam:PassRole",
   "Resource": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsTaskExecutionRole",
   "Condition": {"StringEquals": {"iam:PassedToService": "ecs-tasks.amazonaws.com"}}}]}
JSON
  aws iam get-role --role-name github-deploy-pump-health >/dev/null 2>&1 ||
    aws iam create-role --role-name github-deploy-pump-health \
      --assume-role-policy-document file://scratch/github-trust-part1.json >/dev/null
  aws iam put-role-policy --role-name github-deploy-pump-health --policy-name deploy-pump-health \
    --policy-document file://scratch/github-policy-part1.json
  echo "deploy role: arn:aws:iam::${AWS_ACCOUNT_ID}:role/github-deploy-pump-health"
fi
