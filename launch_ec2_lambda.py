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
EC2_KEY_NAME = os.environ.get('EC2_KEY_NAME')  # Optional

# Check that all required environment variables are set
required_vars = {
    'AMI_ID': AMI_ID,
    'INSTANCE_TYPE': INSTANCE_TYPE,
    'IAM_INSTANCE_PROFILE': IAM_INSTANCE_PROFILE,
    'S3_BUCKET': S3_BUCKET,
    'AWS_ACCOUNT_ID': AWS_ACCOUNT_ID,
    'TARGET_REGION': TARGET_REGION
}

missing_vars = [var_name for var_name, var_value in required_vars.items() if not var_value]
if missing_vars:
    raise ValueError(f"Missing required environment variables: {', '.join(missing_vars)}")

user_data_template = f"""#!/bin/bash
set -euo pipefail

S3_BUCKET="{S3_BUCKET}"
PROOF_DIR="{{{{PROOF_DIR}}}}"
REGION="{TARGET_REGION}"
USER_PROOFS_ALWAYS="true"

# Log all output
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "Starting bare metal proof processing..."
echo "S3 Bucket: $S3_BUCKET"
echo "Proof Directory: $PROOF_DIR"

# Update system and install dependencies
yum update -y
yum install -y git gcc gcc-c++ make openssl-devel awscli zip

# Install Rust (as ec2-user)
su - ec2-user -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly"

# Clone and build plonky2_por
su - ec2-user -c "
    source ~/.cargo/env
    cd ~
    git clone https://github.com/otter-sec/por_v2
    cd por_v2
    cargo build --release --bin plonky2_por
"

# Create 16GB ramdisk for working directory
echo "Setting up 16GB ramdisk for /workspace..."
mkdir -p /workspace
mount -t tmpfs -o size=16G tmpfs /workspace
chown ec2-user:ec2-user /workspace
echo "16GB ramdisk mounted at /workspace"

# Download private_ledger.json from S3
echo "Downloading private_ledger.json from S3..."
aws s3 cp "s3://$S3_BUCKET/$PROOF_DIR/private_ledger.json" /workspace/private_ledger.json --region $REGION

# Check if the file was downloaded successfully
if [ ! -f /workspace/private_ledger.json ]; then
    echo "Error: Failed to download private_ledger.json"
    exit 1
fi

echo "Successfully downloaded private_ledger.json"
chown ec2-user:ec2-user /workspace/private_ledger.json

# Run plonky2_por to generate proofs
echo "Running plonky2_por to generate proofs..."
cd /workspace

su - ec2-user -c "
    cd /workspace
    ~/por_v2/target/release/plonky2_por prove
"

# Check if proof files were generated
if [ ! -f "/workspace/merkle_tree.json" ] || [ ! -f "/workspace/final_proof.json" ]; then
    echo "Error: Proof generation failed - missing output files"
    exit 1
fi

echo "Proof generation completed successfully"

# Create proofs.zip containing the main proof files
echo "Creating proofs.zip..."
cd /workspace
zip proofs.zip merkle_tree.json final_proof.json

if [ ! -f "proofs.zip" ]; then
    echo "Error: Failed to create proofs.zip"
    exit 1
fi

echo "Successfully created proofs.zip"

# Check if we should upload user proofs
UPLOAD_USER_PROOFS=false
if [ "$USER_PROOFS_ALWAYS" = "true" ]; then
    UPLOAD_USER_PROOFS=true
else
    CURRENT_MINUTE=$(date -u +"%H%M")
    if [ "$CURRENT_MINUTE" -ge "2355" ] || [ "$CURRENT_MINUTE" -le "0005" ]; then
        UPLOAD_USER_PROOFS=true
    fi
fi

# Generate user inclusion proofs if needed
if [ "$UPLOAD_USER_PROOFS" = "true" ]; then
    echo "Generating user inclusion proofs..."
    su - ec2-user -c "
        cd /workspace
        ~/por_v2/target/release/plonky2_por prove-inclusion --all-batched
    "
    echo "User inclusion proofs generated"
fi

# Upload all files back to S3
echo "Uploading results back to S3..."
aws s3 sync /workspace "s3://$S3_BUCKET/$PROOF_DIR/" --region $REGION --exclude "private_ledger.json" --exclude "proofs.zip"

# Upload proofs.zip with public read access
echo "Uploading proofs.zip with public access..."
aws s3 cp /workspace/proofs.zip "s3://$S3_BUCKET/$PROOF_DIR/proofs.zip" --region $REGION --acl public-read

echo "Proof processing completed successfully!"
echo "Results uploaded to: s3://$S3_BUCKET/$PROOF_DIR/"
echo "Public download URL: https://$S3_BUCKET.s3.$REGION.amazonaws.com/$PROOF_DIR/proofs.zip"

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