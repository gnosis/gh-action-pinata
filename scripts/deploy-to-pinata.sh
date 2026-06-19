#!/bin/bash

# IPFS Deployment to Pinata with Environment Support
# Usage: ./deploy-to-pinata.sh <environment> <build_dir> <project_name> <timestamp> <branch> <commit_hash>
#
# Notes:
# - Requires: PINATA_JWT
# - Optional: UPLOAD_SCRIPT_PATH to override upload script location

set -euo pipefail

# Determine script directory and upload script path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOAD_SCRIPT="${UPLOAD_SCRIPT_PATH:-${SCRIPT_DIR}/upload-pinata.mjs}"

# Cleanup trap for temp directory
cleanup() {
  if [ -n "${TEMP_DIR:-}" ] && [ -d "${TEMP_DIR:-}" ]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT ERR

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
ENVIRONMENT=${1:-}
BUILD_DIR=${2:-}
PROJECT_NAME=${3:-}
TIMESTAMP=${4:-}
BRANCH=${5:-unknown}
COMMIT_HASH=${6:-unknown}

# Validate arguments
if [ -z "$ENVIRONMENT" ] || [ -z "$BUILD_DIR" ] || [ -z "$PROJECT_NAME" ] || [ -z "$TIMESTAMP" ]; then
  echo -e "${RED}❌ Usage: $0 <environment> <build_dir> <project_name> <timestamp> [branch] [commit_hash]${NC}"
  echo -e "${YELLOW}   environment: dev or prod${NC}"
  echo -e "${YELLOW}   build_dir: path to build directory${NC}"
  echo -e "${YELLOW}   project_name: name of the project${NC}"
  echo -e "${YELLOW}   timestamp: deployment timestamp${NC}"
  exit 1
fi

if [ "$ENVIRONMENT" != "dev" ] && [ "$ENVIRONMENT" != "prod" ]; then
  echo -e "${RED}❌ Environment must be 'dev' or 'prod'${NC}"
  exit 1
fi

# Check build directory exists
if [ ! -d "$BUILD_DIR" ]; then
  echo -e "${RED}❌ Build directory '$BUILD_DIR' not found${NC}"
  exit 1
fi

# Check required env vars
if [ -z "${PINATA_JWT:-}" ]; then
  echo -e "${RED}❌ Required environment variable not set: PINATA_JWT${NC}"
  exit 1
fi

# Configuration
DEPLOYMENTS_DIR="deployments"
DEPLOYMENT_FILE="${DEPLOYMENTS_DIR}/${ENVIRONMENT}/deployment-${TIMESTAMP}.json"
LOG_FILE="${DEPLOYMENTS_DIR}/logs/${ENVIRONMENT}-deployments.log"

# IPFS gateway bases — single source of truth for this deployment.
# The first entry is the primary/dedicated gateway used for verification and as
# the canonical pinata_url. Full URLs and metadata are derived from this list,
# and the workflow reads them back out of the deployment JSON (no duplication).
IPFS_GATEWAYS=(
  "https://gnosis.mypinata.cloud/ipfs"
  "https://ipfs.io/ipfs"
  "https://dweb.link/ipfs"
)

# Build full "<base>/<hash>/" URL for a gateway base.
gateway_url() {
  printf '%s/%s/' "$1" "$2"
}

echo -e "${BLUE}🚀 Starting IPFS Deployment to Pinata${NC}"
echo -e "${BLUE}====================================${NC}"
echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "Project: ${YELLOW}${PROJECT_NAME}${NC}"
echo -e "Build Directory: ${YELLOW}${BUILD_DIR}${NC}"
echo -e "Branch: ${YELLOW}${BRANCH}${NC}"
echo -e "Commit: ${YELLOW}${COMMIT_HASH}${NC}"
echo -e "Timestamp: ${YELLOW}${TIMESTAMP}${NC}"
echo ""

# Step 1: Create temporary directory and prepare files
echo -e "${YELLOW}📦 Preparing files for upload...${NC}"
TEMP_DIR=$(mktemp -d)

# Copy files and count in single operation
if ! cp -r "$BUILD_DIR"/* "$TEMP_DIR/" 2>/dev/null; then
  echo -e "${RED}❌ Failed to copy files from '$BUILD_DIR' to temporary directory${NC}"
  exit 1
fi

# Verify files were copied and count them
FILE_COUNT=$(find "$TEMP_DIR" -type f 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
  echo -e "${RED}❌ Build directory '$BUILD_DIR' is empty or no files copied${NC}"
  exit 1
fi

# Add deployment metadata file
jq -n \
  --arg project "$PROJECT_NAME" \
  --arg environment "$ENVIRONMENT" \
  --arg timestamp "$TIMESTAMP" \
  --arg branch "$BRANCH" \
  --arg commit "$COMMIT_HASH" \
  --arg deployed_at "$(date -Iseconds)" \
  '{
    project: $project,
    environment: $environment,
    timestamp: $timestamp,
    branch: $branch,
    commit: $commit,
    deployed_at: $deployed_at
  }' > "$TEMP_DIR/deployment-info.json"

echo -e "${GREEN}✅ Files prepared in temporary directory (${FILE_COUNT} files)${NC}"

# Step 2: Upload directory to Pinata using Node.js helper
echo -e "${YELLOW}📤 Uploading directory to Pinata...${NC}"

# Validate upload script exists
if [ ! -f "$UPLOAD_SCRIPT" ]; then
  echo -e "${RED}❌ Upload script not found at: $UPLOAD_SCRIPT${NC}"
  exit 1
fi

# Run upload script and capture both stdout and stderr
# Temporarily disable exit on error to capture the exit code properly
set +e
UPLOAD_OUTPUT_FILE=$(mktemp)
node "$UPLOAD_SCRIPT" "$TEMP_DIR" "${PROJECT_NAME}-${ENVIRONMENT}-${TIMESTAMP}" > "$UPLOAD_OUTPUT_FILE" 2>&1
UPLOAD_EXIT_CODE=$?
set -euo pipefail

# Always show the full output for debugging (filter sensitive info)
echo ""
echo "=== Upload script output ==="
# Show output but filter sensitive tokens
grep -v -i -E '(jwt|token|secret|password|auth|bearer|authorization)' "$UPLOAD_OUTPUT_FILE" || cat "$UPLOAD_OUTPUT_FILE"
echo "=== End of upload script output ==="
echo ""

if [ $UPLOAD_EXIT_CODE -ne 0 ]; then
  echo -e "${RED}❌ Failed to upload to Pinata (exit code: $UPLOAD_EXIT_CODE)${NC}"
  echo ""
  echo "=== Error details (last 30 lines) ==="
  # Filter out sensitive info but show errors
  grep -v -i -E '(jwt|token|secret|password|auth|bearer|authorization)' "$UPLOAD_OUTPUT_FILE" | tail -n 30 || tail -n 30 "$UPLOAD_OUTPUT_FILE"
  echo "=== End of error details ==="
  echo ""
  
  # Check for specific error types and provide helpful messages
  if grep -qi "NO_SCOPES_FOUND\|403.*Forbidden\|scopes" "$UPLOAD_OUTPUT_FILE"; then
    echo -e "${YELLOW}💡 Tip: Your PINATA_JWT token is missing required scopes.${NC}"
    echo -e "${YELLOW}   Please ensure your Pinata API key has the 'pinFileToIPFS' scope enabled.${NC}"
    echo -e "${YELLOW}   Check your Pinata dashboard: https://app.pinata.cloud/developers/api-keys${NC}"
    echo ""
  elif grep -qi "401\|Unauthorized" "$UPLOAD_OUTPUT_FILE"; then
    echo -e "${YELLOW}💡 Tip: Authentication failed. Please check your PINATA_JWT token is valid.${NC}"
    echo ""
  elif grep -qi "timeout\|ETIMEDOUT" "$UPLOAD_OUTPUT_FILE"; then
    echo -e "${YELLOW}💡 Tip: Upload timed out. Try increasing PINATA_UPLOAD_TIMEOUT_MS.${NC}"
    echo ""
  fi
  
  rm -f "$UPLOAD_OUTPUT_FILE"
  exit 1
fi

UPLOAD_OUTPUT=$(cat "$UPLOAD_OUTPUT_FILE")
rm -f "$UPLOAD_OUTPUT_FILE"

UPLOAD_JSON=$(echo "$UPLOAD_OUTPUT" | tail -n 1)

# Parse JSON once and extract hash in single operation
IPFS_HASH=$(echo "$UPLOAD_JSON" | jq -r '.IpfsHash // empty' 2>/dev/null)

if [ -n "$IPFS_HASH" ] && [ "$IPFS_HASH" != "null" ] && [ "$IPFS_HASH" != "empty" ]; then
  # Store full response for metadata
  UPLOAD_RESPONSE="$UPLOAD_JSON"
  echo -e "${GREEN}✅ Successfully uploaded to Pinata${NC}"
  echo -e "   IPFS Hash: ${YELLOW}${IPFS_HASH}${NC}"
else
  echo -e "${RED}❌ Failed to parse IPFS hash from Pinata response${NC}"
  echo "Last line of upload output: $UPLOAD_JSON"
  echo ""
  echo "Full upload output (last 20 lines):"
  echo "$UPLOAD_OUTPUT" | grep -v -i -E '(jwt|token|secret|password|auth|bearer)' | tail -n 20
  exit 1
fi

# Step 3: Verify via Pinata gateway (best-effort)
echo -e "${YELLOW}🔍 Verifying deployment (Pinata gateway)...${NC}"
PINATA_URL="$(gateway_url "${IPFS_GATEWAYS[0]}" "$IPFS_HASH")"
if curl -s --head --max-time 10 "$PINATA_URL" >/dev/null; then
  echo -e "${GREEN}✅ Content accessible via Pinata gateway${NC}"
else
  echo -e "${YELLOW}⚠️  Content not yet accessible via Pinata gateway (may take a moment)${NC}"
fi

# Step 4: Save deployment metadata
echo -e "${YELLOW}💾 Saving deployment metadata...${NC}"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")" "$(dirname "$LOG_FILE")"

# Validate and sanitize JSON response
PINATA_RESPONSE_JSON=$(echo "$UPLOAD_RESPONSE" | jq . 2>/dev/null || echo "null")
if [ "$PINATA_RESPONSE_JSON" = "null" ]; then
  echo -e "${YELLOW}⚠️  Warning: Could not parse Pinata response as JSON, using empty object${NC}"
  PINATA_RESPONSE_JSON="{}"
fi

# Sanitize project_name
SANITIZED_PROJECT_NAME=$(echo "$PROJECT_NAME" | tr -cd '[:alnum:]-_' | head -c 100)

# Derive the gateway URL list from IPFS_GATEWAYS (first entry = primary).
GATEWAY_URLS=()
for base in "${IPFS_GATEWAYS[@]}"; do
  GATEWAY_URLS+=("$(gateway_url "$base" "$IPFS_HASH")")
done
URLS_JSON=$(printf '%s\n' "${GATEWAY_URLS[@]}" | jq -R . | jq -s .)

jq -n \
  --arg project "$SANITIZED_PROJECT_NAME" \
  --arg environment "$ENVIRONMENT" \
  --arg ipfs_hash "$IPFS_HASH" \
  --arg timestamp "$TIMESTAMP" \
  --arg branch "$BRANCH" \
  --arg commit "$COMMIT_HASH" \
  --arg deployed_at "$(date -Iseconds)" \
  --argjson pinata_response "$PINATA_RESPONSE_JSON" \
  --arg pinata_url "$PINATA_URL" \
  --argjson urls "$URLS_JSON" \
  '{
    project: $project,
    environment: $environment,
    ipfs_hash: $ipfs_hash,
    timestamp: $timestamp,
    branch: $branch,
    commit: $commit,
    deployed_at: $deployed_at,
    pinata_response: $pinata_response,
    pinata_url: $pinata_url,
    urls: {
      ipfs: $urls
    }
  }' > "$DEPLOYMENT_FILE"

# Validate the created JSON file
if ! jq empty "$DEPLOYMENT_FILE" 2>/dev/null; then
  echo -e "${RED}❌ Failed to create valid deployment metadata JSON${NC}"
  exit 1
fi

cd "$(dirname "$DEPLOYMENT_FILE")"
ln -sf "$(basename "$DEPLOYMENT_FILE")" latest.json
cd - >/dev/null

echo "$(date -Iseconds) | $ENVIRONMENT | $IPFS_HASH | $BRANCH | $COMMIT_HASH" >>"$LOG_FILE"

echo -e "${GREEN}✅ Deployment metadata saved${NC}"

echo ""
echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo -e "📍 IPFS Hash: ${YELLOW}$IPFS_HASH${NC}"
echo -e "🌿 Branch: ${YELLOW}$BRANCH${NC}"
echo -e "📝 Commit: ${YELLOW}$COMMIT_HASH${NC}"

