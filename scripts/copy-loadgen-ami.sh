#!/usr/bin/env bash
# One-shot: copy the us-east-1 loadgen AMI to the two Phase 3 cross-region loadgens.
#
# AMI copies are asynchronous — this script kicks them off and prints the new
# AMI IDs. The copies finish in 5-10 min; check with:
#   aws ec2 describe-images --region us-west-2    --image-ids ami-XXXX
#   aws ec2 describe-images --region ap-northeast-1 --image-ids ami-XXXX
# until State=available.
#
# Cost: ~pennies, one-time.

set -euo pipefail

SRC_REGION="us-east-1"
SRC_AMI="${SRC_AMI:-ami-00c8da86ef207f15d}"   # loadgen AMI from ~/.ami-id

TARGET_REGIONS=(us-west-2 ap-northeast-1)

echo "==> Source: $SRC_AMI in $SRC_REGION"
aws ec2 describe-images --region "$SRC_REGION" --image-ids "$SRC_AMI" \
    --query 'Images[0].[Name,CreationDate,State]' --output text

for region in "${TARGET_REGIONS[@]}"; do
    echo ""
    echo "==> Copying to $region"
    new_ami=$(aws ec2 copy-image \
        --region "$region" \
        --source-region "$SRC_REGION" \
        --source-image-id "$SRC_AMI" \
        --name "pqc-bench-loadgen-phase3-$(date +%Y%m%d)" \
        --description "PQC-Bench Phase 3 loadgen (copied from $SRC_REGION/$SRC_AMI)" \
        --query 'ImageId' --output text)
    echo "    loadgen_ami_${region//-/_}=$new_ami"
done

echo ""
echo "==> Save these in terraform/phase-3/terraform.tfvars once State=available:"
echo "    loadgen_ami_us_west_2    = \"ami-XXXX\""
echo "    loadgen_ami_ap_northeast_1 = \"ami-XXXX\""
echo ""
echo "==> Poll for availability:"
for region in "${TARGET_REGIONS[@]}"; do
    echo "    aws ec2 describe-images --region $region --owners self --query 'Images[?Name==\`pqc-bench-loadgen-phase3-$(date +%Y%m%d)\`].[ImageId,State]' --output text"
done
