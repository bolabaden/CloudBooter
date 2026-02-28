#!/bin/bash

FLAG_FILE="$HOME/.oci/instance_launched"
SUCCESS_LOG="$HOME/.oci/instance_launch_success.log"
ERROR_LOG="$HOME/.oci/instance_launch_error.log"
MAX_ERROR_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB in bytes

# Function to rotate error log file
rotate_error_log() {
    if [ -f "$ERROR_LOG" ] && [ $(stat -f%z "$ERROR_LOG") -ge $MAX_ERROR_LOG_SIZE ]; then
        mv "$ERROR_LOG" "${ERROR_LOG}.old"
    fi
}

# Rotate error log before writing
rotate_error_log

# Function to log messages
log_message() {
    local log_file="$1"
    local message="$2"
    echo "$(date): $message" >> "$log_file"
}

# Check if the flag file exists
if [ -f "$FLAG_FILE" ]; then
    log_message "$SUCCESS_LOG" "Instance already launched. Skipping..."
    exit 0
fi

# Launch the instance and capture the output
output=$(oci compute instance launch \
  --metadata '{"ssh_authorized_keys":"ssh-rsa xxxxxxxx ubuntu"}' \
  --availability-domain EPHk:AP-TOKYO-1-AD-1 \
  --compartment-id ocid1.tenancy.oc1..xxxxxxxxx \
  --subnet-id ocid1.subnet.oc1.ap-tokyo-1.xxxxxq \
  --image-id ocid1.image.oc1.ap-tokyo-1.aaaaaaaagupkwu6yar4fcxrybrz763z6ndedu3syyclc2ozjimiglyhz62va \
  --shape-config '{ "ocpus": 4, "memoryInGBs": 24 }' \
  --shape VM.Standard.A1.Flex \
  --display-name oracle \
  --hostname-label oracle \
  --assign-public-ip true \
  --assign-private-dns-record true \
  --no-retry 2>&1)

# Check if the command was successful and the output is valid JSON
if echo "$output" | jq -e . >/dev/null 2>&1; then
    log_message "$SUCCESS_LOG" "Instance launched successfully."
    
    # Create the .oci directory if it doesn't exist
    mkdir -p "$HOME/.oci"
    
    # Create the flag file
    touch "$FLAG_FILE"
    log_message "$SUCCESS_LOG" "Flag file created: $FLAG_FILE"
else
    log_message "$ERROR_LOG" "Failed to launch instance. Output:"
    echo "$output" >> "$ERROR_LOG"
    exit 1
fi

echo "Next steps:"
echo "crontab -e"
echo "*/2 * * * * /home/path/to/bin/ociauto.sh"
