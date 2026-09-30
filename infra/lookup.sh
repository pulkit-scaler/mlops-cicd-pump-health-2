# Finds this project's AWS resources by name and exports their IDs.
#
#     source infra/lookup.sh
#
# A resource that does not exist yet gives an empty variable. Production keeps
# the names from Part 1. Staging has the same pieces with -staging in the name.
q() { v=$(aws "$@" --output text 2>/dev/null); [ "$v" = None ] && v=; echo "$v"; }

# owner/name of this clone's GitHub repository, from its remote
export GITHUB_REPO=$(git remote get-url origin | sed -E 's#\.git$##; s#^.*[:/]([^/:]+/[^/]+)$#\1#')
export AWS_ACCOUNT_ID=$(q sts get-caller-identity --query Account)
export ECR_REGISTRY=${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com
export ECR_URI=${ECR_REGISTRY}/pump-health

# The network both environments share
export VPC_ID=$(q ec2 describe-vpcs --filters Name=tag:Name,Values=mlops-vpc --query 'Vpcs[0].VpcId')
export SUBNET_A=$(q ec2 describe-subnets --filters Name=tag:Name,Values=mlops-public-a --query 'Subnets[0].SubnetId')
export SUBNET_B=$(q ec2 describe-subnets --filters Name=tag:Name,Values=mlops-public-b --query 'Subnets[0].SubnetId')
export IGW_ID=$(q ec2 describe-internet-gateways --filters Name=tag:Name,Values=mlops-igw --query 'InternetGateways[0].InternetGatewayId')
export RT_ID=$(q ec2 describe-route-tables --filters Name=tag:Name,Values=mlops-public-rt --query 'RouteTables[0].RouteTableId')
export ALB_SG=$(q ec2 describe-security-groups --filters Name=group-name,Values=mlops-alb-sg Name=vpc-id,Values="${VPC_ID:-none}" --query 'SecurityGroups[0].GroupId')
export TASK_SG=$(q ec2 describe-security-groups --filters Name=group-name,Values=mlops-task-sg Name=vpc-id,Values="${VPC_ID:-none}" --query 'SecurityGroups[0].GroupId')
export OIDC_ARN=$(q iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn, '/token.actions.githubusercontent.com')].Arn | [0]")

# Production: cluster mlops-cluster, service pump-health
export PROD_TG=$(q elbv2 describe-target-groups --names pump-health-tg --query 'TargetGroups[0].TargetGroupArn')
export PROD_ALB=$(q elbv2 describe-load-balancers --names pump-health-alb --query 'LoadBalancers[0].LoadBalancerArn')
export PROD_URL=$(q elbv2 describe-load-balancers --names pump-health-alb --query 'LoadBalancers[0].DNSName' | sed '/./s#^#http://#')

# Staging: cluster mlops-staging, service pump-health-staging
export STAGING_TG=$(q elbv2 describe-target-groups --names pump-health-staging-tg --query 'TargetGroups[0].TargetGroupArn')
export STAGING_ALB=$(q elbv2 describe-load-balancers --names pump-health-staging-alb --query 'LoadBalancers[0].LoadBalancerArn')
export STAGING_URL=$(q elbv2 describe-load-balancers --names pump-health-staging-alb --query 'LoadBalancers[0].DNSName' | sed '/./s#^#http://#')
