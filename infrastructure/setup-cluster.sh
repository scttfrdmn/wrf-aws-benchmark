#!/bin/bash
# setup-cluster.sh - One-command cluster creation for WRF benchmark
set -e

CLUSTER_NAME="${1:-wrf-benchmark}"
CONFIG_FILE="${2:-cluster-config.yaml}"
REGION="${AWS_DEFAULT_REGION:-us-east-2}"
SCRIPTS_BUCKET="${SCRIPTS_BUCKET:-}"

echo "========================================"
echo "WRF Benchmark Cluster Setup"
echo "========================================"
echo "Cluster name: ${CLUSTER_NAME}"
echo "Region: ${REGION}"
echo "Config: ${CONFIG_FILE}"
echo ""

# Check prerequisites
check_prerequisites() {
    echo "Checking prerequisites..."
    
    # AWS CLI
    if ! command -v aws &> /dev/null; then
        echo "ERROR: AWS CLI not found. Install from https://aws.amazon.com/cli/"
        exit 1
    fi
    
    # ParallelCluster CLI
    if ! command -v pcluster &> /dev/null; then
        echo "ERROR: ParallelCluster CLI not found."
        echo "Install with: pip install aws-parallelcluster"
        exit 1
    fi
    
    # Check version
    PCLUSTER_VERSION=$(pcluster version | grep -oP '\d+\.\d+\.\d+' | head -1)
    echo "ParallelCluster version: ${PCLUSTER_VERSION}"
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        echo "ERROR: AWS credentials not configured"
        exit 1
    fi
    
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    echo "AWS Account: ${ACCOUNT_ID}"
    
    echo "Prerequisites OK"
    echo ""
}

# Check HPC quota
check_quotas() {
    echo "Checking HPC instance quotas..."
    
    HPC_QUOTA=$(aws service-quotas get-service-quota \
        --service-code ec2 \
        --quota-code L-74FC7D96 \
        --region ${REGION} \
        --query 'Quota.Value' \
        --output text 2>/dev/null || echo "0")
    
    echo "Current HPC vCPU quota: ${HPC_QUOTA}"
    
    if (( $(echo "${HPC_QUOTA} < 1920" | bc -l) )); then
        echo ""
        echo "WARNING: HPC quota (${HPC_QUOTA} vCPUs) may be insufficient."
        echo "Recommended: At least 1,920 vCPUs (10 × hpc7a.96xlarge)"
        echo ""
        echo "Request increase at:"
        echo "https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas/L-74FC7D96"
        echo ""
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "HPC quota OK"
    fi
    echo ""
}

# Create/update configuration
prepare_config() {
    echo "Preparing cluster configuration..."
    
    # Get default VPC and subnet if not specified
    if grep -q "subnet-REPLACE_ME" ${CONFIG_FILE}; then
        echo "Finding default subnet..."
        
        DEFAULT_VPC=$(aws ec2 describe-vpcs \
            --filters "Name=is-default,Values=true" \
            --query 'Vpcs[0].VpcId' \
            --output text \
            --region ${REGION})
        
        if [ "${DEFAULT_VPC}" == "None" ] || [ -z "${DEFAULT_VPC}" ]; then
            echo "ERROR: No default VPC found. Please specify subnet in config."
            exit 1
        fi
        
        # Find a subnet in an AZ with hpc7a availability
        # hpc7a is available in us-east-2a, us-east-2b
        DEFAULT_SUBNET=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${DEFAULT_VPC}" \
                      "Name=availability-zone,Values=${REGION}a" \
            --query 'Subnets[0].SubnetId' \
            --output text \
            --region ${REGION})
        
        echo "Using VPC: ${DEFAULT_VPC}"
        echo "Using Subnet: ${DEFAULT_SUBNET}"
        
        # Create working config
        sed -e "s/subnet-REPLACE_ME/${DEFAULT_SUBNET}/g" \
            ${CONFIG_FILE} > ${CONFIG_FILE}.tmp
        mv ${CONFIG_FILE}.tmp ${CONFIG_FILE}.generated
        CONFIG_FILE="${CONFIG_FILE}.generated"
    fi
    
    # Check for SSH key
    if grep -q "KeyName: REPLACE_ME" ${CONFIG_FILE}; then
        echo ""
        echo "No SSH key specified. Available keys:"
        aws ec2 describe-key-pairs --query 'KeyPairs[*].KeyName' --output table --region ${REGION}
        echo ""
        read -p "Enter key name: " KEY_NAME
        sed -i "s/KeyName: REPLACE_ME/KeyName: ${KEY_NAME}/" ${CONFIG_FILE}
    fi
    
    echo "Configuration prepared: ${CONFIG_FILE}"
    echo ""
}

# Upload bootstrap scripts to S3
upload_scripts() {
    if [ -z "${SCRIPTS_BUCKET}" ]; then
        echo "Creating S3 bucket for scripts..."
        SCRIPTS_BUCKET="wrf-benchmark-scripts-${ACCOUNT_ID}-${REGION}"
        
        if ! aws s3 ls "s3://${SCRIPTS_BUCKET}" 2>/dev/null; then
            aws s3 mb "s3://${SCRIPTS_BUCKET}" --region ${REGION}
        fi
    fi
    
    echo "Uploading scripts to s3://${SCRIPTS_BUCKET}..."
    
    # Upload the head node setup script
    cat > /tmp/head_node_setup.sh << 'SCRIPT'
#!/bin/bash
# Head node post-configuration

# Install useful tools
yum install -y htop tmux git

# Create shared directories
mkdir -p /shared/software
mkdir -p /shared/data
mkdir -p /shared/scripts

# Download Spack setup script
curl -o /shared/scripts/install_wrf.sh \
    https://raw.githubusercontent.com/aws/aws-parallelcluster-spack-configs/main/scripts/install.sh

chmod +x /shared/scripts/install_wrf.sh

echo "Head node setup complete"
SCRIPT
    
    aws s3 cp /tmp/head_node_setup.sh "s3://${SCRIPTS_BUCKET}/scripts/head_node_setup.sh"
    
    # Update config with bucket name
    sed -i "s|s3://REPLACE_BUCKET|s3://${SCRIPTS_BUCKET}|g" ${CONFIG_FILE}
    
    echo "Scripts uploaded"
    echo ""
}

# Create the cluster
create_cluster() {
    echo "Creating cluster ${CLUSTER_NAME}..."
    echo "This will take approximately 15-20 minutes."
    echo ""
    
    pcluster create-cluster \
        --cluster-name ${CLUSTER_NAME} \
        --cluster-configuration ${CONFIG_FILE} \
        --region ${REGION} \
        --wait
    
    echo ""
    echo "Cluster created successfully!"
    echo ""
}

# Print connection info
print_info() {
    echo "========================================"
    echo "Cluster Ready!"
    echo "========================================"
    echo ""
    echo "Connect with:"
    echo "  pcluster ssh -n ${CLUSTER_NAME} --region ${REGION}"
    echo ""
    echo "Or use SSM (no SSH key needed):"
    echo "  pcluster ssh -n ${CLUSTER_NAME} --region ${REGION}"
    echo ""
    echo "Next steps on the cluster:"
    echo "  1. cd /shared/scripts"
    echo "  2. ./install_wrf.sh  # Install WRF via Spack (~20 min)"
    echo "  3. cd /fsx && mkdir benchmark && cd benchmark"
    echo "  4. # Run benchmarks!"
    echo ""
    echo "To delete the cluster when done:"
    echo "  pcluster delete-cluster -n ${CLUSTER_NAME} --region ${REGION}"
    echo ""
}

# Main execution
main() {
    check_prerequisites
    check_quotas
    prepare_config
    upload_scripts
    create_cluster
    print_info
}

main "$@"
