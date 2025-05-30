# Proof of Reserves S3 Processing System

This system automatically processes proof-of-reserves files when they are uploaded to S3. When a new file is uploaded, a Lambda function launches an EC2 instance that runs a Docker container to generate proofs.

## Quick Setup

1. **Configure the deployment**: Set the required environment variables for your AWS account and preferences
2. **Run the setup script**: `./generate-setup-instructions.sh` to get complete setup instructions with all values pre-filled
3. **Copy and paste**: The script outputs ready-to-run commands that you can copy and paste

## Architecture Overview

1. **S3 Upload Trigger**: When a `private_ledger.json` file is uploaded to S3
2. **Lambda Function**: Automatically launches an EC2 instance
3. **EC2 Instance**: Runs a Docker container with the proof generation binary
4. **Docker Container**: Processes the ledger file and uploads results back to S3
5. **Auto-termination**: EC2 instance terminates itself after completion

## Output Files

The system generates the following outputs in S3 (in the same directory as the input file):

- `merkle_tree.json`: Merkle tree proof
- `final_proof.json`: Final proof
- User inclusion proofs (generated when `USER_PROOFS_ALWAYS=true` or around midnight UTC)

## Monitoring

- Check CloudWatch logs for the Lambda function: `/aws/lambda/{LAMBDA_FUNCTION_NAME}`
- Monitor EC2 instances in the AWS console
- Check S3 bucket for output files

## Configuration

All configuration is done by setting environment variables before running `generate-setup-instructions.sh`:

**Required variables:**

```bash
export AWS_ACCOUNT_ID="your-aws-account-id"
export AWS_REGION="us-east-1"
export S3_BUCKET="your-bucket-name"
```

**Optional variables (with defaults):**

```bash
export ECR_REPOSITORY="proof-of-reserves-processor"
export AMI_ID="ami-022acf3cdef3c76c1"  # Amazon Linux 2023 ARM64
export INSTANCE_TYPE="c8g.8xlarge"
export IAM_INSTANCE_PROFILE="ecsInstanceRole"
export LAMBDA_FUNCTION_NAME="proof-of-reserves-launcher"
export EC2_KEY_NAME="your-key-pair"  # Optional for SSH access
```

The setup script will generate all AWS CLI commands with these values pre-filled, making deployment error-free and fast.
