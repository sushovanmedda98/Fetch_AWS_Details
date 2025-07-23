#!/bin/bash

set -euo pipefail

# Configuration - Auto-detect input file format
INPUT_FILES=("aws_vms.yaml" "aws_vms_friendly.csv" "aws_vms.txt")
INPUT_FILE=""
OUTPUT_JSON_FILE="aws_alerts_output.json"
LOG_FILE="aws_alerts.log"

# AWS SNS Topic ARN
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:us-west-2:123456789012:YourSNSTopic}"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Auto-detect input file
detect_input_file() {
    for file in "${INPUT_FILES[@]}"; do
        if [ -f "$file" ]; then
            INPUT_FILE="$file"
            log "📁 Found input file: $INPUT_FILE"
            return 0
        fi
    done
    
    log "❌ Error: No input file found! Please create one of:"
    for file in "${INPUT_FILES[@]}"; do
        log "   - $file"
    done
    exit 1
}

# Parse YAML file (requires yq or python)
parse_yaml() {
    local yaml_file=$1
    
    if command -v yq &> /dev/null; then
        # Using yq (preferred)
        yq eval '.instances[] | .name + "|" + .region + "|" + .instance_id' "$yaml_file"
    elif command -v python3 &> /dev/null; then
        # Using Python as fallback
        python3 -c "
import yaml, sys
with open('$yaml_file', 'r') as f:
    data = yaml.safe_load(f)
    for instance in data.get('instances', []):
        print(f\"{instance['name']}|{instance['region']}|{instance['instance_id']}\")
"
    else
        log "❌ Error: YAML parsing requires 'yq' or 'python3' with PyYAML"
        exit 1
    fi
}

# Parse CSV file
parse_csv() {
    local csv_file=$1
    # Skip header line and comments, convert CSV to pipe-delimited
    grep -v '^#' "$csv_file" | tail -n +2 | while IFS=',' read -r name region instance_id description; do
        # Remove quotes and whitespace
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')
        region=$(echo "$region" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')
        instance_id=$(echo "$instance_id" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"')
        
        if [ -n "$name" ] && [ -n "$region" ] && [ -n "$instance_id" ]; then
            echo "$name|$region|$instance_id"
        fi
    done
}

# Parse traditional pipe-delimited file
parse_txt() {
    local txt_file=$1
    grep -v '^#' "$txt_file" | grep -v '^[[:space:]]*$'
}

# Get instances based on file format
get_instances() {
    case "$INPUT_FILE" in
        *.yaml|*.yml)
            log "📋 Parsing YAML format..."
            parse_yaml "$INPUT_FILE"
            ;;
        *.csv)
            log "📋 Parsing CSV format..."
            parse_csv "$INPUT_FILE"
            ;;
        *.txt)
            log "📋 Parsing text format..."
            parse_txt "$INPUT_FILE"
            ;;
        *)
            log "❌ Error: Unsupported file format for $INPUT_FILE"
            exit 1
            ;;
    esac
}

# Validation function
validate_prerequisites() {
    log "🔍 Validating prerequisites..."
    
    detect_input_file
    
    # Check if AWS CLI is available
    if ! command -v aws &> /dev/null; then
        log "❌ Error: AWS CLI not found!"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log "❌ Error: AWS credentials not configured or invalid!"
        exit 1
    fi
    
    log "✅ Prerequisites validation passed"
}

# Initialize output file
initialize_output() {
    log "📝 Initializing output file..."
    echo "[]" > "$OUTPUT_JSON_FILE"
    touch "$LOG_FILE"
    log "🚀 Starting AWS CloudWatch alarm creation process"
}

# Function to create or update a CloudWatch alarm
create_or_update_alarm() {
    local INSTANCE_NAME=$1
    local REGION=$2
    local INSTANCE_ID=$3
    local ALARM_NAME="EC2-Availability-${INSTANCE_NAME}"
    
    log "🔄 Processing: $INSTANCE_NAME ($INSTANCE_ID) in $REGION"
    
    # Validate instance exists
    if ! aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --output text &> /dev/null; then
        log "⚠️  Warning: Instance $INSTANCE_ID not found in region $REGION"
        return 1
    fi
    
    # Create/update the alarm with retry logic
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if aws cloudwatch put-metric-alarm \
            --alarm-name "$ALARM_NAME" \
            --alarm-description "EC2 instance $INSTANCE_NAME failed status checks" \
            --metric-name "StatusCheckFailed" \
            --namespace "AWS/EC2" \
            --statistic "Average" \
            --period 300 \
            --threshold 1 \
            --comparison-operator "GreaterThanOrEqualToThreshold" \
            --dimensions "Name=InstanceId,Value=$INSTANCE_ID" \
            --evaluation-periods 1 \
            --alarm-actions "$SNS_TOPIC_ARN" \
            --region "$REGION" \
            --output json &> /dev/null; then
            
            log "✅ Alarm created/updated: $ALARM_NAME"
            
            # Update output JSON safely
            local temp_file=$(mktemp)
            jq --argjson new_alarm "{\"alarm_name\": \"$ALARM_NAME\", \"instance_id\": \"$INSTANCE_ID\", \"region\": \"$REGION\", \"status\": \"success\"}" \
               '. + [$new_alarm]' "$OUTPUT_JSON_FILE" > "$temp_file" && mv "$temp_file" "$OUTPUT_JSON_FILE"
            
            return 0
        else
            retry_count=$((retry_count + 1))
            log "⚠️  Attempt $retry_count failed for $ALARM_NAME"
            
            if [ $retry_count -lt $max_retries ]; then
                log "🔄 Retrying in 5 seconds..."
                sleep 5
            fi
        fi
    done
    
    log "❌ Failed to create/update alarm after $max_retries attempts: $ALARM_NAME"
    return 1
}

# Main processing function
process_instances() {
    local processed_lines=0
    local successful_alarms=0
    local failed_alarms=0
    
    log "📊 Processing instances from $INPUT_FILE..."
    
    # Process each instance
    while IFS='|' read -r INSTANCE_NAME REGION INSTANCE_ID; do
        processed_lines=$((processed_lines + 1))
        
        # Trim whitespace
        INSTANCE_NAME=$(echo "$INSTANCE_NAME" | xargs)
        REGION=$(echo "$REGION" | xargs)
        INSTANCE_ID=$(echo "$INSTANCE_ID" | xargs)
        
        # Skip empty lines
        if [ -z "$INSTANCE_NAME" ] || [ -z "$REGION" ] || [ -z "$INSTANCE_ID" ]; then
            continue
        fi
        
        log "📍 Processing instance $processed_lines: $INSTANCE_NAME"
        
        if create_or_update_alarm "$INSTANCE_NAME" "$REGION" "$INSTANCE_ID"; then
            successful_alarms=$((successful_alarms + 1))
        else
            failed_alarms=$((failed_alarms + 1))
        fi
        
    done < <(get_instances)
    
    # Summary
    log "📈 Processing Summary:"
    log "   Total processed: $processed_lines"
    log "   Successful alarms: $successful_alarms"
    log "   Failed alarms: $failed_alarms"
    log "   Input file format: $(basename "$INPUT_FILE")"
    log "   Output saved to: $OUTPUT_JSON_FILE"
}

# Main execution
main() {
    log "🎯 AWS CloudWatch Alarm Creation Script Started"
    
    validate_prerequisites
    initialize_output
    process_instances
    
    log "✅ Script execution completed successfully"
}

# Execute main function
main "$@"
