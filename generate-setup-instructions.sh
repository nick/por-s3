#!/bin/bash

# =============================================================================
# CONFIGURATION - Set these as environment variables before running
# =============================================================================

# Required environment variables
required_vars=(
    "AWS_ACCOUNT_ID"
    "AWS_REGION"
    "S3_BUCKET"
)

# Optional environment variables (with defaults)
ECR_REPOSITORY=${ECR_REPOSITORY:-"proof-of-reserves-processor"}
AMI_ID=${AMI_ID:-"ami-022acf3cdef3c76c1"}  # Amazon Linux 2023 ARM64
INSTANCE_TYPE=${INSTANCE_TYPE:-"c8g.12xlarge"}
IAM_INSTANCE_PROFILE=${IAM_INSTANCE_PROFILE:-"ecsInstanceRole"}
LAMBDA_FUNCTION_NAME=${LAMBDA_FUNCTION_NAME:-"proof-of-reserves-launcher"}
LAMBDA_ROLE_NAME=${LAMBDA_ROLE_NAME:-"ProofOfReservesLambdaRole"}
EC2_ROLE_NAME=${EC2_ROLE_NAME:-"ProofOfReservesEC2Role"}
EC2_KEY_NAME=${EC2_KEY_NAME:-""}  # Optional: EC2 key pair name for SSH access

# Check for missing required variables
missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -ne 0 ]; then
    echo "Error: Missing required environment variables:"
    printf "  %s\n" "${missing_vars[@]}"
    echo ""
    echo "Please set all required environment variables before running this script."
    echo ""
    echo "Example:"
    echo "  export AWS_ACCOUNT_ID=\"123456789012\""
    echo "  export AWS_REGION=\"us-east-1\""
    echo "  export S3_BUCKET=\"my-bucket\""
    echo ""
    echo "Optional variables (defaults shown):"
    echo "  export ECR_REPOSITORY=\"$ECR_REPOSITORY\""
    echo "  export AMI_ID=\"$AMI_ID\""
    echo "  export INSTANCE_TYPE=\"$INSTANCE_TYPE\""
    echo "  export IAM_INSTANCE_PROFILE=\"$IAM_INSTANCE_PROFILE\""
    echo "  export LAMBDA_FUNCTION_NAME=\"$LAMBDA_FUNCTION_NAME\""
    echo "  export LAMBDA_ROLE_NAME=\"$LAMBDA_ROLE_NAME\""
    echo "  export EC2_ROLE_NAME=\"$EC2_ROLE_NAME\""
    echo "  export EC2_KEY_NAME=\"my-key-pair\"  # Optional for SSH access"
    echo ""
    echo "Then run: $0"
    exit 1
fi

# =============================================================================
# GENERATED INSTRUCTIONS
# =============================================================================

cat << EOF
======================================================================
Proof of Reserves S3 Processing System Setup Instructions
======================================================================

Configuration:
  AWS Account ID: $AWS_ACCOUNT_ID
  AWS Region: $AWS_REGION
  S3 Bucket: $S3_BUCKET
  ECR Repository: $ECR_REPOSITORY
  Instance Type: $INSTANCE_TYPE

======================================================================
1. BUILD AND PUSH DOCKER CONTAINER
======================================================================

# Create ECR repository if it doesn't exist
aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION 2>/dev/null || \\
aws ecr create-repository --repository-name $ECR_REPOSITORY --region $AWS_REGION

# Build the Docker image
docker build --platform linux/arm64 -t $ECR_REPOSITORY .

# Tag for ECR
docker tag $ECR_REPOSITORY:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:latest

# Authenticate Docker to ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Push the image
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:latest

# Verify upload
aws ecr describe-images --repository-name $ECR_REPOSITORY --region $AWS_REGION

======================================================================
2. CREATE IAM ROLES AND POLICIES
======================================================================

# Create EC2 IAM Role
aws iam create-role --role-name $EC2_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}'

# Attach policy to EC2 role
aws iam put-role-policy --role-name $EC2_ROLE_NAME --policy-name ProofOfReservesPolicy --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:PutObjectAcl"],
      "Resource": ["arn:aws:s3:::$S3_BUCKET", "arn:aws:s3:::$S3_BUCKET/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["ec2:TerminateInstances"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "ec2:Region": "$AWS_REGION"
        }
      }
    }
  ]
}'

# Create instance profile
aws iam create-instance-profile --instance-profile-name $IAM_INSTANCE_PROFILE

# Add role to instance profile
aws iam add-role-to-instance-profile --instance-profile-name $IAM_INSTANCE_PROFILE --role-name $EC2_ROLE_NAME

# Create Lambda IAM Role
aws iam create-role --role-name $LAMBDA_ROLE_NAME --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}'

# Attach basic execution role to Lambda
aws iam attach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Attach custom policy to Lambda role
aws iam put-role-policy --role-name $LAMBDA_ROLE_NAME --policy-name LambdaEC2Policy --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "iam:PassRole"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::$S3_BUCKET/*"
    }
  ]
}'

======================================================================
3. CREATE LAMBDA FUNCTION
======================================================================

# Package the Lambda function
zip lambda-function.zip launch_ec2_lambda.py

# Create the Lambda function
aws lambda create-function \\
  --function-name $LAMBDA_FUNCTION_NAME \\
  --runtime python3.9 \\
  --role arn:aws:iam::$AWS_ACCOUNT_ID:role/$LAMBDA_ROLE_NAME \\
  --handler launch_ec2_lambda.lambda_handler \\
  --zip-file fileb://lambda-function.zip \\
  --timeout 60 \\
  --environment Variables="{AMI_ID=$AMI_ID,INSTANCE_TYPE=$INSTANCE_TYPE,IAM_INSTANCE_PROFILE=$IAM_INSTANCE_PROFILE,S3_BUCKET=$S3_BUCKET,AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID,TARGET_REGION=$AWS_REGION,ECR_REPOSITORY=$ECR_REPOSITORY,EC2_KEY_NAME=$EC2_KEY_NAME}"

======================================================================
4. CONFIGURE S3 EVENT TRIGGER
======================================================================

# Add S3 trigger permission to Lambda function
aws lambda add-permission \\
  --function-name $LAMBDA_FUNCTION_NAME \\
  --principal s3.amazonaws.com \\
  --action lambda:InvokeFunction \\
  --statement-id s3-trigger-permission \\
  --source-arn arn:aws:s3:::$S3_BUCKET

# Configure S3 bucket notification
aws s3api put-bucket-notification-configuration \\
  --bucket $S3_BUCKET \\
  --notification-configuration '{
    "LambdaFunctionConfigurations": [
      {
        "Id": "proof-of-reserves-trigger",
        "LambdaFunctionArn": "arn:aws:lambda:$AWS_REGION:$AWS_ACCOUNT_ID:function:$LAMBDA_FUNCTION_NAME",
        "Events": ["s3:ObjectCreated:*"],
        "Filter": {
          "Key": {
            "FilterRules": [
              {
                "Name": "suffix",
                "Value": "private_ledger.json"
              }
            ]
          }
        }
      }
    ]
  }'

======================================================================
5. TEST THE SETUP
======================================================================

# Upload a test file to trigger the system
aws s3 cp /path/to/your/private_ledger.json s3://$S3_BUCKET/test/private_ledger.json

# Monitor Lambda logs
aws logs tail /aws/lambda/$LAMBDA_FUNCTION_NAME --follow

# Check for output files
aws s3 ls s3://$S3_BUCKET/latest/

======================================================================
SETUP COMPLETE!
======================================================================

The system will now automatically process any private_ledger.json files
uploaded to s3://$S3_BUCKET/

Monitor the system:
- Lambda logs: /aws/lambda/$LAMBDA_FUNCTION_NAME
- EC2 instances in AWS console
- Output files in s3://$S3_BUCKET/latest/

======================================================================
UPDATING THE LAMBDA FUNCTION
======================================================================

After making changes to launch_ec2_lambda.py, update the deployed function:

# Package the updated Lambda function
zip lambda-function.zip launch_ec2_lambda.py

# Update the Lambda function code
aws lambda update-function-code \\
  --function-name $LAMBDA_FUNCTION_NAME \\
  --zip-file fileb://lambda-function.zip

# Update environment variables (if needed)
aws lambda update-function-configuration \\
  --function-name $LAMBDA_FUNCTION_NAME \\
  --environment Variables="{AMI_ID=$AMI_ID,INSTANCE_TYPE=$INSTANCE_TYPE,IAM_INSTANCE_PROFILE=$IAM_INSTANCE_PROFILE,S3_BUCKET=$S3_BUCKET,AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID,TARGET_REGION=$AWS_REGION,ECR_REPOSITORY=$ECR_REPOSITORY,EC2_KEY_NAME=$EC2_KEY_NAME}"

# View the updated function
aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME

EOF