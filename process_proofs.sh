#!/bin/bash

set -euo pipefail

# Environment variables that should be set:
# S3_BUCKET - The S3 bucket name
# PROOF_DIR - The S3 directory path containing private_ledger.json
# AWS_REGION - AWS region (optional, defaults to us-east-1)
# USER_PROOFS_ALWAYS - if set to true, always upload user proofs (default: true for now)

AWS_REGION=${AWS_REGION:-us-east-1}
USER_PROOFS_ALWAYS=${USER_PROOFS_ALWAYS:-true}

if [ -z "${S3_BUCKET:-}" ] || [ -z "${PROOF_DIR:-}" ]; then
    echo "Error: S3_BUCKET and PROOF_DIR environment variables must be set"
    exit 1
fi

echo "Starting proof of reserves processing..."
echo "S3 Bucket: $S3_BUCKET"
echo "Proof Directory: $PROOF_DIR"

# Create working directory
mkdir -p /workspace

# Download private_ledger.json from S3
echo "Downloading private_ledger.json from S3..."
aws s3 cp "s3://$S3_BUCKET/$PROOF_DIR/private_ledger.json" /workspace/private_ledger.json --region $AWS_REGION

# Check if the file was downloaded successfully
if [ ! -f /workspace/private_ledger.json ]; then
    echo "Error: Failed to download private_ledger.json"
    exit 1
fi

echo "Successfully downloaded private_ledger.json"

# Run plonky2_por to generate proofs
echo "Running plonky2_por to generate proofs..."
cd /workspace

# Run the proof generation
plonky2_por prove

# Check if proof files were generated
if [ ! -f "merkle_tree.json" ] || [ ! -f "final_proof.json" ]; then
    echo "Error: Proof generation failed - missing output files"
    exit 1
fi

echo "Proof generation completed successfully"

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
    plonky2_por prove-inclusion --all-batched
    echo "User inclusion proofs generated"
fi

# Upload all files back to S3
echo "Uploading results back to S3..."
aws s3 sync /workspace "s3://$S3_BUCKET/$PROOF_DIR/" --region $AWS_REGION --exclude "private_ledger.json"

echo "Proof processing completed successfully!"
echo "Results uploaded to: s3://$S3_BUCKET/$PROOF_DIR/"
