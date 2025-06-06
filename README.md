# Proof of Reserves S3 Processing System (Bare Metal)

An automated system for generating cryptographic proofs of reserves using AWS Lambda and EC2. When a `private_ledger.json` file is uploaded to S3, the system automatically launches a bare metal EC2 instance that builds and runs the plonky2_por binary to generate proofs.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Configuration](#configuration)
- [Usage](#usage)
- [Manual Testing](#manual-testing)
- [Monitoring](#monitoring)
- [Output Files](#output-files)
- [Performance](#performance)
- [Cost Considerations](#cost-considerations)
- [Troubleshooting](#troubleshooting)
- [Security](#security)

## Architecture Overview

```
┌─────────────┐      ┌─────────────┐      ┌─────────────┐
│     S3      │ ---> │   Lambda    │ ---> │     EC2     │
│   Upload    │      │  Function   │      │  Instance   │
└─────────────┘      └─────────────┘      └─────────────┘
                                                   │
                                                   v
                                           ┌─────────────┐
                                           │   Build &   │
                                           │ Run plonky2 │
                                           └─────────────┘
                                                   │
                                                   v
                                           ┌─────────────┐
                                           │  Upload to  │
                                           │     S3      │
                                           └─────────────┘
```

### How it Works

1. **S3 Upload Trigger**: When a `private_ledger.json` file is uploaded to S3, it triggers a Lambda function
2. **Lambda Function**: Launches an EC2 instance with user data script that:
   - Installs Rust nightly toolchain
   - Clones and builds plonky2_por from source
   - Downloads the private_ledger.json from S3
   - Runs proof generation directly on bare metal
   - Uploads results back to S3
   - Terminates the instance
3. **Output**: Generated proofs are uploaded to the same S3 directory, with `proofs.zip` publicly accessible

## Prerequisites

Before setting up the system, ensure you have:

1. **AWS Account** with appropriate permissions to:

   - Create IAM roles and policies
   - Deploy Lambda functions
   - Launch EC2 instances
   - Create and manage S3 buckets

2. **AWS CLI** installed and configured:

   ```bash
   aws configure
   ```

3. **Required IAM Permissions**:

   - IAM role creation
   - Lambda function deployment
   - EC2 instance management
   - S3 bucket operations

4. **S3 Bucket** for storing input and output files

## Setup

### 1. Set Environment Variables

```bash
# Required
export AWS_ACCOUNT_ID="123456789012"
export AWS_REGION="us-east-1"
export S3_BUCKET="my-proof-bucket"

# Optional (with defaults)
export AMI_ID="ami-022acf3cdef3c76c1"  # Amazon Linux 2023 ARM64
export INSTANCE_TYPE="c8g.12xlarge"     # ARM-based high-performance
export IAM_INSTANCE_PROFILE="ecsInstanceRole"
export LAMBDA_FUNCTION_NAME="proof-of-reserves-launcher"
export EC2_KEY_NAME="my-key-pair"       # For SSH access (optional)
```

### 2. Generate Setup Instructions

```bash
./generate-setup-instructions.sh
```

This script will output AWS CLI commands customized with your configuration.

### 3. Execute Setup Commands

Follow the generated instructions to:

1. Create IAM roles and policies
2. Deploy the Lambda function
3. Configure S3 event triggers

## Configuration

### Lambda Environment Variables

| Variable               | Description               | Default                 |
| ---------------------- | ------------------------- | ----------------------- |
| `AMI_ID`               | Amazon Machine Image ID   | Amazon Linux 2023 ARM64 |
| `INSTANCE_TYPE`        | EC2 instance type         | `c8g.12xlarge`          |
| `IAM_INSTANCE_PROFILE` | IAM instance profile name | `ecsInstanceRole`       |
| `S3_BUCKET`            | S3 bucket for files       | (required)              |
| `AWS_ACCOUNT_ID`       | AWS account ID            | (required)              |
| `TARGET_REGION`        | AWS region                | (required)              |
| `EC2_KEY_NAME`         | EC2 key pair for SSH      | (optional)              |

### Instance Types

Recommended ARM-based instances for optimal performance:

- `c8g.4xlarge` - Testing and small proofs
- `c8g.8xlarge` - Medium-sized proofs
- `c8g.12xlarge` - Large proofs (default)
- `c8g.16xlarge` - Maximum performance

## Usage

### Automatic Processing

Upload a `private_ledger.json` file to trigger automatic processing:

```bash
aws s3 cp private_ledger.json s3://my-bucket/proof-runs/2024-01-15/private_ledger.json
```

The system will automatically:

1. Launch an EC2 instance
2. Build plonky2_por from source
3. Process the file
4. Upload results to the same S3 directory
5. Terminate the instance

### File Structure

```
s3://my-bucket/
└── proof-runs/
    └── 2024-01-15/
        ├── private_ledger.json     # Input (uploaded by you)
        ├── merkle_tree.json        # Output
        ├── final_proof.json        # Output
        ├── proofs.zip              # Output (public)
        └── user_proofs/            # Output (optional)
```

## Manual Testing

For debugging and testing, you can launch instances manually:

### 1. Create Test Script

```bash
cat > test-user-data.sh << 'EOF'
#!/bin/bash
# Copy the user data from launch_ec2_lambda.py
# Remove the auto-termination lines for testing
EOF
```

### 2. Launch Test Instance

```bash
# Set configuration
export S3_BUCKET="your-bucket"
export PROOF_DIR="test/2024-01-15"

# Upload test file
aws s3 cp private_ledger.json s3://$S3_BUCKET/$PROOF_DIR/private_ledger.json

# Launch instance
aws ec2 run-instances \
  --image-id ami-022acf3cdef3c76c1 \
  --instance-type c8g.4xlarge \
  --iam-instance-profile Name=ecsInstanceRole \
  --key-name your-key-pair \
  --user-data file://test-user-data.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=plonky2-test}]' \
  --region us-east-1
```

### 3. Monitor Progress

```bash
# SSH to instance
ssh -i ~/.ssh/your-key-pair.pem ec2-user@<instance-ip>

# View logs
sudo tail -f /var/log/user-data.log

# Check workspace
ls -la /workspace/
```

### 4. Clean Up

```bash
# IMPORTANT: Manually terminate test instances
aws ec2 terminate-instances --instance-ids <instance-id> --region us-east-1
```

## Monitoring

### Lambda Function Logs

```bash
# View recent logs
aws logs tail /aws/lambda/proof-of-reserves-launcher --follow

# Search logs
aws logs filter-log-events \
  --log-group-name /aws/lambda/proof-of-reserves-launcher \
  --start-time $(date -u -d '1 hour ago' +%s)000
```

### EC2 Instance Monitoring

1. **AWS Console**: EC2 → Instances → Filter by tag "Purpose=proof-of-reserves"
2. **CloudWatch**: Monitor CPU, memory, and network metrics
3. **Instance Logs**: Available at `/var/log/user-data.log`

### S3 Output Monitoring

```bash
# List output files
aws s3 ls s3://my-bucket/proof-runs/2024-01-15/ --recursive

# Download results
aws s3 cp s3://my-bucket/proof-runs/2024-01-15/proofs.zip .
```

## Output Files

| File                 | Description                      | Access  |
| -------------------- | -------------------------------- | ------- |
| `merkle_tree.json`   | Merkle tree structure            | Private |
| `final_proof.json`   | Final cryptographic proof        | Private |
| `proofs.zip`         | Archive of main proof files      | Public  |
| `user_proofs/*.json` | Individual user inclusion proofs | Private |

### Public Access URL

```
https://<bucket>.s3.<region>.amazonaws.com/<proof-dir>/proofs.zip
```

## Troubleshooting

### Common Issues

#### 1. Lambda Function Not Triggering

```bash
# Check S3 event configuration
aws s3api get-bucket-notification-configuration --bucket my-bucket

# Verify Lambda permissions
aws lambda get-policy --function-name proof-of-reserves-launcher
```

#### 2. EC2 Instance Fails to Start

- Check IAM instance profile exists
- Verify AMI is available in your region
- Ensure instance type is available

#### 3. Proof Generation Fails

```bash
# SSH to instance and check logs
sudo cat /var/log/user-data.log

# Common issues:
# - Insufficient memory (upgrade instance type)
# - S3 permissions (check IAM role)
# - Build failures (check Rust installation)
```

#### 4. S3 Upload Fails

- Verify IAM role has S3 write permissions
- Check bucket policy allows uploads
- Ensure bucket exists in the correct region

### Debug Commands

```bash
# List running instances
aws ec2 describe-instances \
  --filters "Name=tag:Purpose,Values=proof-of-reserves" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name,LaunchTime]'

# View instance user data
aws ec2 describe-instance-attribute \
  --instance-id <instance-id> \
  --attribute userData \
  --query 'UserData.Value' \
  --output text | base64 -d
```
