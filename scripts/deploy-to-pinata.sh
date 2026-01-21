#!/bin/bash

# IPFS Deployment to Pinata with Environment Support
# Usage: ./deploy-to-pinata.sh <environment> <build_dir> <project_name> <timestamp> <branch> <commit_hash>
#
# Notes:
# - Requires: PINATA_JWT
# - Optional: IPNS publishing (ENABLE_IPNS=true)
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
  if [ "${DAEMON_STARTED:-false}" = "true" ] && [ -n "${IPFS_PID:-}" ]; then
    kill "$IPFS_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT ERR

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
ENVIRONMENT=${1:-}
BUILD_DIR=${2:-}
PROJECT_NAME=${3:-}
TIMESTAMP=${4:-}
BRANCH=${5:-unknown}
COMMIT_HASH=${6:-unknown}

ENABLE_IPNS=${ENABLE_IPNS:-false}

# Validate arguments
if [ -z "$ENVIRONMENT" ] || [ -z "$BUILD_DIR" ] || [ -z "$PROJECT_NAME" ] || [ -z "$TIMESTAMP" ]; then
  echo -e "${RED}❌ Usage: $0 <environment> <build_dir> <project_name> <timestamp> [branch] [commit_hash]${NC}"
  echo -e "${YELLOW}   environment: dev or prod${NC}"
  echo -e "${YELLOW}   build_dir: path to build directory${NC}"
  echo -e "${YELLOW}   project_name: name of the project${NC}"
  echo -e "${YELLOW}   timestamp: deployment timestamp${NC}"
  exit 1
fi

# Validate environment
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
IPNS_KEY_NAME="${PROJECT_NAME}-${ENVIRONMENT}"
DEPLOYMENT_FILE="${DEPLOYMENTS_DIR}/${ENVIRONMENT}/deployment-${TIMESTAMP}.json"
LOG_FILE="${DEPLOYMENTS_DIR}/logs/${ENVIRONMENT}-deployments.log"

echo -e "${BLUE}🚀 Starting IPFS Deployment to Pinata${NC}"
echo -e "${BLUE}====================================${NC}"
echo -e "Environment: ${YELLOW}${ENVIRONMENT}${NC}"
echo -e "Project: ${YELLOW}${PROJECT_NAME}${NC}"
echo -e "Build Directory: ${YELLOW}${BUILD_DIR}${NC}"
echo -e "Branch: ${YELLOW}${BRANCH}${NC}"
echo -e "Commit: ${YELLOW}${COMMIT_HASH}${NC}"
echo -e "Timestamp: ${YELLOW}${TIMESTAMP}${NC}"
echo -e "IPNS: ${YELLOW}${ENABLE_IPNS}${NC}"
echo ""

# Step 1: Create temporary directory and prepare files
echo -e "${YELLOW}📦 Preparing files for upload...${NC}"
TEMP_DIR=$(mktemp -d)

# Validate build directory has files
if [ ! "$(ls -A "$BUILD_DIR" 2>/dev/null)" ]; then
  echo -e "${RED}❌ Build directory '$BUILD_DIR' is empty${NC}"
  exit 1
fi

# Copy files and validate copy succeeded
if ! cp -r "$BUILD_DIR"/* "$TEMP_DIR/" 2>/dev/null; then
  echo -e "${RED}❌ Failed to copy files from '$BUILD_DIR' to temporary directory${NC}"
  exit 1
fi

# Verify files were copied
FILE_COUNT=$(find "$TEMP_DIR" -type f | wc -l)
if [ "$FILE_COUNT" -eq 0 ]; then
  echo -e "${RED}❌ No files found in build directory after copy${NC}"
  exit 1
fi

# Add deployment metadata file
cat >"$TEMP_DIR/deployment-info.json" <<EOF
{
  "project": "$PROJECT_NAME",
  "environment": "$ENVIRONMENT",
  "timestamp": "$TIMESTAMP",
  "branch": "$BRANCH",
  "commit": "$COMMIT_HASH",
  "deployed_at": "$(date -Iseconds)"
}
EOF

echo -e "${GREEN}✅ Files prepared in temporary directory (${FILE_COUNT} files)${NC}"

# Step 2: Upload directory to Pinata using Node.js helper
echo -e "${YELLOW}📤 Uploading directory to Pinata...${NC}"

# Validate upload script exists
if [ ! -f "$UPLOAD_SCRIPT" ]; then
  echo -e "${RED}❌ Upload script not found at: $UPLOAD_SCRIPT${NC}"
  exit 1
fi

UPLOAD_OUTPUT=$(node "$UPLOAD_SCRIPT" "$TEMP_DIR" "${PROJECT_NAME}-${ENVIRONMENT}-${TIMESTAMP}" 2>&1)
UPLOAD_JSON=$(echo "$UPLOAD_OUTPUT" | tail -n 1)

if echo "$UPLOAD_JSON" | jq -e '.IpfsHash' >/dev/null 2>&1; then
  IPFS_HASH=$(echo "$UPLOAD_JSON" | jq -r '.IpfsHash')
  # Validate IPFS hash format (should be a valid multihash)
  if [ -z "$IPFS_HASH" ] || [ "$IPFS_HASH" = "null" ]; then
    echo -e "${RED}❌ Invalid IPFS hash received from Pinata${NC}"
    echo -e "${RED}Response: $UPLOAD_JSON${NC}"
    exit 1
  fi
  UPLOAD_RESPONSE="$UPLOAD_JSON"
  echo -e "${GREEN}✅ Successfully uploaded to Pinata${NC}"
  echo -e "   IPFS Hash: ${YELLOW}${IPFS_HASH}${NC}"
else
  echo -e "${RED}❌ Failed to upload to Pinata${NC}"
  echo -e "${RED}Output: $UPLOAD_OUTPUT${NC}"
  exit 1
fi

# Optional: IPNS
IPNS_ADDRESS=""
DAEMON_STARTED=false
IPFS_PID=""

if [ "$ENABLE_IPNS" = "true" ]; then
  # Step 3: Install IPFS if not available
  if ! command -v ipfs &>/dev/null; then
    echo -e "${YELLOW}⚠️  IPFS not found. Installing kubo for IPNS...${NC}"
    IPFS_VERSION="v0.24.0"
    IPFS_DIST="https://dist.ipfs.io/kubo/${IPFS_VERSION}/kubo_${IPFS_VERSION}_$(uname -s | tr '[:upper:]' '[:lower:]')-amd64.tar.gz"
    curl -s -L "$IPFS_DIST" | tar -xz
    sudo install kubo/ipfs /usr/local/bin/
    rm -rf kubo/
    if [ ! -d "$HOME/.ipfs" ]; then
      ipfs init
    fi
    echo -e "${GREEN}✅ IPFS installed and initialized${NC}"
  fi

  # Step 4: Start IPFS daemon if not running
  if ! ipfs id &>/dev/null; then
    echo -e "${YELLOW}🔄 Starting IPFS daemon...${NC}"
    # Start daemon in background and capture PID
    ipfs daemon >/dev/null 2>&1 &
    IPFS_PID=$!
    
    # Wait for daemon to be ready (max 30 seconds)
    MAX_WAIT=30
    WAITED=0
    while [ $WAITED -lt $MAX_WAIT ]; do
      if ipfs id &>/dev/null; then
        break
      fi
      sleep 1
      WAITED=$((WAITED + 1))
    done
    
    if ! ipfs id &>/dev/null; then
      echo -e "${RED}❌ Failed to start IPFS daemon after ${MAX_WAIT}s${NC}"
      kill "$IPFS_PID" 2>/dev/null || true
      exit 1
    fi
    echo -e "${GREEN}✅ IPFS daemon started (waited ${WAITED}s)${NC}"
    DAEMON_STARTED=true
  else
    echo -e "${GREEN}✅ IPFS daemon already running${NC}"
    # Don't set DAEMON_STARTED=true if we didn't start it
  fi

  # Step 5: Create/get IPNS key
  echo -e "${YELLOW}🔑 Managing IPNS key...${NC}"
  if ipfs key list | grep -q "^${IPNS_KEY_NAME}$"; then
    echo -e "${GREEN}✅ IPNS key '${IPNS_KEY_NAME}' already exists${NC}"
  else
    ipfs key gen --type=rsa --size=2048 "$IPNS_KEY_NAME"
    echo -e "${GREEN}✅ IPNS key created${NC}"
  fi

  IPNS_ADDRESS=$(ipfs key list -l | grep "$IPNS_KEY_NAME" | awk '{print $1}')

  # Step 6: Publish to IPNS
  echo -e "${YELLOW}🔗 Publishing to IPNS...${NC}"
  if ipfs name publish --key="$IPNS_KEY_NAME" "$IPFS_HASH"; then
    echo -e "${GREEN}✅ Successfully published to IPNS${NC}"
    echo -e "   IPNS Address: ${YELLOW}${IPNS_ADDRESS}${NC}"
  else
    echo -e "${YELLOW}⚠️  Failed to publish to IPNS (continuing; IPFS hash is still valid)${NC}"
  fi
fi

# Step 7: Verify via Pinata gateway (best-effort)
echo -e "${YELLOW}🔍 Verifying deployment (Pinata gateway)...${NC}"
PINATA_URL="https://gateway.pinata.cloud/ipfs/$IPFS_HASH"
if curl -s --head --max-time 10 "$PINATA_URL" >/dev/null; then
  echo -e "${GREEN}✅ Content accessible via Pinata gateway${NC}"
else
  echo -e "${YELLOW}⚠️  Content not yet accessible via Pinata gateway (may take a moment)${NC}"
fi

# Step 8: Save deployment metadata
echo -e "${YELLOW}💾 Saving deployment metadata...${NC}"
mkdir -p "$(dirname "$DEPLOYMENT_FILE")" "$(dirname "$LOG_FILE")"

# Validate and sanitize JSON response before embedding
PINATA_RESPONSE_JSON=$(echo "$UPLOAD_RESPONSE" | jq . 2>/dev/null || echo "null")
if [ "$PINATA_RESPONSE_JSON" = "null" ]; then
  echo -e "${YELLOW}⚠️  Warning: Could not parse Pinata response as JSON, using empty object${NC}"
  PINATA_RESPONSE_JSON="{}"
fi

# Sanitize project_name for filesystem safety (remove dangerous characters)
SANITIZED_PROJECT_NAME=$(echo "$PROJECT_NAME" | tr -cd '[:alnum:]-_' | head -c 100)

cat >"$DEPLOYMENT_FILE" <<EOF
{
  "project": "$SANITIZED_PROJECT_NAME",
  "environment": "$ENVIRONMENT",
  "ipfs_hash": "$IPFS_HASH",
  "ipns_address": "$IPNS_ADDRESS",
  "ipns_key": "$IPNS_KEY_NAME",
  "timestamp": "$TIMESTAMP",
  "branch": "$BRANCH",
  "commit": "$COMMIT_HASH",
  "deployed_at": "$(date -Iseconds)",
  "pinata_response": $PINATA_RESPONSE_JSON,
  "urls": {
    "ipfs": [
      "https://gateway.pinata.cloud/ipfs/$IPFS_HASH",
      "https://ipfs.io/ipfs/$IPFS_HASH",
      "https://cloudflare-ipfs.com/ipfs/$IPFS_HASH",
      "https://dweb.link/ipfs/$IPFS_HASH"
    ],
    "ipns": [
      "https://gateway.pinata.cloud/ipns/$IPNS_ADDRESS",
      "https://ipfs.io/ipns/$IPNS_ADDRESS",
      "https://cloudflare-ipfs.com/ipns/$IPNS_ADDRESS",
      "https://dweb.link/ipns/$IPNS_ADDRESS"
    ]
  }
}
EOF

# Validate the created JSON file
if ! jq empty "$DEPLOYMENT_FILE" 2>/dev/null; then
  echo -e "${RED}❌ Failed to create valid deployment metadata JSON${NC}"
  exit 1
fi

cd "$(dirname "$DEPLOYMENT_FILE")"
ln -sf "$(basename "$DEPLOYMENT_FILE")" latest.json
cd - >/dev/null

echo "$(date -Iseconds) | $ENVIRONMENT | $IPFS_HASH | $IPNS_ADDRESS | $BRANCH | $COMMIT_HASH" >>"$LOG_FILE"

echo -e "${GREEN}✅ Deployment metadata saved${NC}"

echo ""
echo -e "${GREEN}🎉 Deployment Complete!${NC}"
echo -e "📍 IPFS Hash: ${YELLOW}$IPFS_HASH${NC}"
if [ -n "$IPNS_ADDRESS" ]; then
  echo -e "🏷️  IPNS Address: ${YELLOW}$IPNS_ADDRESS${NC}"
fi
echo -e "🌿 Branch: ${YELLOW}$BRANCH${NC}"
echo -e "📝 Commit: ${YELLOW}$COMMIT_HASH${NC}"

# Cleanup is handled by trap, but explicit cleanup message for IPNS
if [ "$DAEMON_STARTED" = "true" ] && [ -n "${IPFS_PID:-}" ]; then
  echo -e "${YELLOW}🔄 Stopping IPFS daemon...${NC}"
  kill "$IPFS_PID" 2>/dev/null || true
fi

