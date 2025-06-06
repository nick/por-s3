import boto3
import os

ec2 = boto3.client('ec2')

# Configuration variables - all required
AMI_ID = os.environ.get('AMI_ID')
INSTANCE_TYPE = os.environ.get('INSTANCE_TYPE')
IAM_INSTANCE_PROFILE = os.environ.get('IAM_INSTANCE_PROFILE')
S3_BUCKET = os.environ.get('S3_BUCKET')
AWS_ACCOUNT_ID = os.environ.get('AWS_ACCOUNT_ID')
TARGET_REGION = os.environ.get('TARGET_REGION')
ECR_REPOSITORY = os.environ.get('ECR_REPOSITORY')
EC2_KEY_NAME = os.environ.get('EC2_KEY_NAME')  # Optional

# Check that all required environment variables are set
required_vars = {
    'AMI_ID': AMI_ID,
    'INSTANCE_TYPE': INSTANCE_TYPE,
    'IAM_INSTANCE_PROFILE': IAM_INSTANCE_PROFILE,
    'S3_BUCKET': S3_BUCKET,
    'AWS_ACCOUNT_ID': AWS_ACCOUNT_ID,
    'TARGET_REGION': TARGET_REGION,
    'ECR_REPOSITORY': ECR_REPOSITORY
}

missing_vars = [var_name for var_name, var_value in required_vars.items() if not var_value]
if missing_vars:
    raise ValueError(f"Missing required environment variables: {', '.join(missing_vars)}")

# Construct the full ECR image URL
ECR_IMAGE = f"{AWS_ACCOUNT_ID}.dkr.ecr.{TARGET_REGION}.amazonaws.com/{ECR_REPOSITORY}:latest"

user_data_template = f"""#!/bin/bash
set -e

S3_BUCKET="{S3_BUCKET}"
PROOF_DIR="{{{{PROOF_DIR}}}}"
REGION="{TARGET_REGION}"
IMAGE="{ECR_IMAGE}"

# Install AWS CLI and Docker
yum install -y awscli docker
service docker start
usermod -a -G docker ec2-user

# Authenticate Docker to ECR
$(aws ecr get-login --no-include-email --region $REGION)

# Pull the image
docker pull $IMAGE

# Create workspace directory on host for volume mount
mkdir -p /tmp/workspace

# Run the container with volume mount for optimized I/O, passing S3 info as env vars
docker run --rm \\
  -v /tmp/workspace:/workspace \\
  -e S3_BUCKET=$S3_BUCKET \\
  -e PROOF_DIR=$PROOF_DIR \\
  -e AWS_REGION=$REGION \\
  $IMAGE

# Terminate the instance
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION
"""

def lambda_handler(event, context):
    launched_instances = []

    for record in event['Records']:
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']

        # Extract the directory path from the S3 key (remove the filename)
        # For example: "proof-runs/2024-01-15/private_ledger.json" -> "proof-runs/2024-01-15"
        proof_dir = '/'.join(key.split('/')[:-1])

        # Substitute PROOF_DIR in user data
        user_data = user_data_template.replace('{{PROOF_DIR}}', proof_dir)

        try:
            # Build the run_instances parameters
            run_params = {
                'ImageId': AMI_ID,
                'InstanceType': INSTANCE_TYPE,
                'IamInstanceProfile': {'Name': IAM_INSTANCE_PROFILE},
                'UserData': user_data,
                'MinCount': 1,
                'MaxCount': 1
            }

            # Add KeyName only if EC2_KEY_NAME is provided
            if EC2_KEY_NAME:
                run_params['KeyName'] = EC2_KEY_NAME

            response = ec2.run_instances(**run_params)

            instance_id = response['Instances'][0]['InstanceId']
            launched_instances.append(instance_id)
            print(f"Launched EC2 instance {instance_id} for S3 key: {key}")

        except Exception as e:
            print(f"Failed to launch instance for {key}: {str(e)}")
            raise e

    return {
        'statusCode': 200,
        'body': f'Successfully launched {len(launched_instances)} instance(s): {launched_instances}'
    }