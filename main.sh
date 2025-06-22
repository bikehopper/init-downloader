# S3 Copy Script
# Reads source:destination pairs from S3_COPY_LIST environment variable
# Format: "source1:dest1,source2:dest2,source3:dest3"

set -uo pipefail

# Function to display usage
usage() {
    echo "Usage: $0"
    echo ""
    echo "This script reads source and destination pairs from the S3_COPY_LIST environment variable."
    echo "Sources and destinations can be S3 URLs or local file paths."
    echo "Format: S3_COPY_LIST=\"s3://bucket1/path1:/local/path,/local/file:s3://bucket2/file\""
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  -v, --verbose  Enable verbose output"
    echo "  -n, --dry-run  Show what would be copied without actually copying"
    echo ""
    echo "Environment Variables:"
    echo "  S3_COPY_LIST   Comma-separated list of source:destination pairs (S3 URLs or local paths)"
    echo "  AWS_PROFILE    (Optional) AWS profile to use"
    exit 1
}

# Parse command line arguments
VERBOSE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "Error: AWS CLI is not installed or not in PATH"
    exit 1
fi

# Check if S3_COPY_LIST environment variable is set
if [[ -z "${S3_COPY_LIST:-}" ]]; then
    echo "Error: S3_COPY_LIST environment variable is not set"
    echo ""
    echo "Example:"
    echo "export S3_COPY_LIST=\"s3://source-bucket/file1.txt:/local/path/file1.txt,/local/dir/:s3://dest-bucket/backup/\""
    exit 1
fi

# Logging function
log() {
    if [[ "$VERBOSE" == true ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
}

# Function to copy between S3 and local filesystem
copy_data() {
    local source="$1"
    local destination="$2"

    log "Processing: $source -> $destination"

    # Determine the type of operation based on source and destination
    local is_source_s3=false
    local is_dest_s3=false
    local cmd=""

    if [[ "$source" =~ ^s3:// ]]; then
        is_source_s3=true
    fi

    if [[ "$destination" =~ ^s3:// ]]; then
        is_dest_s3=true
    fi

    # Build appropriate AWS CLI command based on source/destination types
    if [[ "$is_source_s3" == true && "$is_dest_s3" == true ]]; then
        # S3 to S3 copy
        if [[ "$source" == */ ]]; then
            cmd="aws s3 sync \"$source\" \"$destination\""
        else
            cmd="aws s3 cp \"$source\" \"$destination\""
        fi
    elif [[ "$is_source_s3" == true && "$is_dest_s3" == false ]]; then
        # S3 to local
        if [[ "$source" == */ ]]; then
            # Create destination directory if it doesn't exist (for sync operations)
            if [[ "$DRY_RUN" == false ]]; then
                mkdir -p "$destination"
            fi
            cmd="aws s3 sync \"$source\" \"$destination\""
        else
            # Create destination directory if copying to a directory path
            local dest_dir
            if [[ "$destination" == */ ]]; then
                dest_dir="$destination"
            else
                dest_dir=$(dirname "$destination")
            fi
            if [[ "$DRY_RUN" == false ]]; then
                mkdir -p "$dest_dir"
            fi
            cmd="aws s3 cp \"$source\" \"$destination\""
        fi
    elif [[ "$is_source_s3" == false && "$is_dest_s3" == true ]]; then
        # Local to S3
        if [[ -d "$source" ]]; then
            cmd="aws s3 sync \"$source\" \"$destination\""
        else
            cmd="aws s3 cp \"$source\" \"$destination\""
        fi
    else
        # Local to local (regular file copy)
        log "Local to local copy detected, using standard cp/rsync"
        if [[ -d "$source" ]]; then
            cmd="rsync -av \"$source\" \"$destination\""
        else
            # Create destination directory if needed
            local dest_dir
            if [[ "$destination" == */ ]]; then
                dest_dir="$destination"
            else
                dest_dir=$(dirname "$destination")
            fi
            if [[ "$DRY_RUN" == false ]]; then
                mkdir -p "$dest_dir"
            fi
            cmd="cp \"$source\" \"$destination\""
        fi
    fi

    # Add dry-run flag for AWS commands
    if [[ "$DRY_RUN" == true && "$cmd" =~ ^aws ]]; then
        cmd="$cmd --dryrun"
    fi

    # Add dry-run simulation for non-AWS commands
    if [[ "$DRY_RUN" == true && ! "$cmd" =~ ^aws ]]; then
        cmd="echo \"[DRY-RUN] Would execute: $cmd\""
    fi

    if [[ "$VERBOSE" == true ]] || [[ "$DRY_RUN" == true ]]; then
        echo "Executing: $cmd"
    fi

    # Execute the command with explicit error handling
    eval "$cmd"
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "Error: Failed to copy $source to $destination (exit code: $exit_code)"
        return 1
    fi

    if [[ "$DRY_RUN" == false ]]; then
        echo "✓ Successfully copied: $source -> $destination"
    fi

    return 0
}

# Main execution
main() {
    log "Starting S3 copy operations"
    log "S3_COPY_LIST: $S3_COPY_LIST"

    if [[ "$DRY_RUN" == true ]]; then
        echo "DRY RUN MODE - No actual copying will be performed"
        echo ""
    fi

    # Split the environment variable by commas and process each pair
    IFS=',' read -ra COPY_PAIRS <<< "$S3_COPY_LIST"

    local total_pairs=${#COPY_PAIRS[@]}
    local successful_copies=0
    local failed_copies=0

    echo "Found $total_pairs copy operations to perform"
    log "Parsed pairs: ${COPY_PAIRS[*]}"
    echo ""

    for i in "${!COPY_PAIRS[@]}"; do
        local pair="${COPY_PAIRS[$i]}"

        # Trim whitespace
        pair=$(echo "$pair" | xargs)

        # Skip empty pairs
        if [[ -z "$pair" ]]; then
            echo "Skipping empty pair"
            continue
        fi

        # Split source and destination - use a simpler, more reliable approach
        if [[ "$pair" == *":"* ]]; then
            local source=""
            local destination=""

            # Find the split point by looking at the structure
            if [[ "$pair" =~ ^s3:// ]]; then
                # Source is S3 - find the colon that's NOT part of s3://
                # Skip the s3:// part and find the next colon
                local temp="${pair#s3://}"  # Remove s3:// prefix
                if [[ "$temp" == *":"* ]]; then
                    # Find position of first colon after s3://
                    local bucket_and_path="${temp%%:*}"  # Everything before first colon
                    local dest="${temp#*:}"              # Everything after first colon
                    source="s3://$bucket_and_path"
                    destination="$dest"
                else
                    echo "Warning: Could not find destination in pair '$pair'"
                    ((failed_copies++))
                    continue
                fi
            else
                # Source is local - split on colon before s3:// or use last colon
                if [[ "$pair" == *":s3://"* ]]; then
                    # Local to S3
                    source="${pair%:s3://*}"
                    destination="s3://${pair##*:s3://}"
                else
                    # Local to local - use last colon
                    source="${pair%:*}"
                    destination="${pair##*:}"
                fi
            fi

            # Verify we got both source and destination
            if [[ -z "$source" || -z "$destination" ]]; then
                echo "Warning: Could not parse pair '$pair'. Expected format: 'source:destination'"
                ((failed_copies++))
                continue
            fi


            # Trim whitespace from source and destination
            source=$(echo "$source" | xargs)
            destination=$(echo "$destination" | xargs)

            # Validate paths (either S3 URLs or local paths)
            if [[ "$source" =~ ^s3:// ]] || [[ -e "$source" ]] || [[ -d "$(dirname "$source")" ]]; then
                # Source is valid (S3 URL, existing file/dir, or parent dir exists)
                :
            else
                echo "Warning: Source '$source' does not exist and is not a valid S3 URL, skipping..."
                ((failed_copies++))
                continue
            fi

            # For destination, we don't need to validate existence since it will be created
            # Just ensure it's either an S3 URL or a valid local path format
            if [[ "$destination" =~ ^s3:// ]] || [[ "$destination" =~ ^/ ]] || [[ "$destination" =~ ^\./ ]] || [[ "$destination" =~ ^[a-zA-Z] ]]; then
                # Destination appears to be valid format (S3 URL or local path)
                :
            else
                echo "Warning: Destination '$destination' does not appear to be a valid path format, skipping..."
                ((failed_copies++))
                continue
            fi

            # Perform the copy
            if copy_data "$source" "$destination"; then
                ((successful_copies++))
            else
                ((failed_copies++))
            fi

            echo ""

            echo ""
        else
            echo "Warning: No colon separator found in pair '$pair'. Expected format: 'source:destination'"
            ((failed_copies++))
        fi

    done

    # Summary
    echo "===================="
    echo "Copy Operations Summary:"
    echo "Total pairs processed: $total_pairs"
    echo "Successful copies: $successful_copies"
    echo "Failed copies: $failed_copies"

    if [[ "$failed_copies" -gt 0 ]]; then
        exit 1
    fi

    log "All copy operations completed successfully"
}

# Run main function
main