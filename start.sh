#!/bin/bash

# Suppress orphan container warnings (multiple compose files share same project)
export COMPOSE_IGNORE_ORPHANS=true

echo "🚀 Starting Story Localnet..."

# Build images if they don't exist (build specific services to avoid parallel conflicts)
# Binary paths (relative to script directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GETH_BINARY="${SCRIPT_DIR}/../story-geth/build/bin/geth"
DEFAULT_STORY_BINARY="${SCRIPT_DIR}/../story/story"

# Parse options
USE_LOCAL_BINARY=${USE_LOCAL_BINARY:-false}
STORY_BINARY_OVERRIDE=""
for arg in "$@"; do
    case "$arg" in
        --use-local-binary)
            USE_LOCAL_BINARY="true"
            ;;
        --story-binary=*)
            USE_LOCAL_BINARY="true"
            STORY_BINARY_OVERRIDE="${arg#*=}"
            ;;
        -h|--help)
            echo "Usage: $0 [--use-local-binary] [--story-binary PATH]"
            exit 0
            ;;
    esac
done

if [ -z "$STORY_BINARY_OVERRIDE" ]; then
    # Support --story-binary PATH (space-separated)
    for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "--story-binary" ]; then
            j=$((i+1))
            if [ -z "${!j}" ] || [[ "${!j}" == --* ]]; then
                echo "Error: --story-binary requires a path argument"
                exit 1
            fi
            STORY_BINARY_OVERRIDE="${!j}"
            USE_LOCAL_BINARY="true"
            break
        fi
    done
fi

if [ -n "$STORY_BINARY_OVERRIDE" ]; then
    STORY_BINARY="$STORY_BINARY_OVERRIDE"
else
    STORY_BINARY="$DEFAULT_STORY_BINARY"
fi

# Check binary versions
echo "🔍 Checking binary versions..."
echo ""

# Check geth version
if [ -f "$GETH_BINARY" ]; then
    echo "📦 Geth binary found: $GETH_BINARY"
    echo "   Version info:"
    "$GETH_BINARY" version 2>&1 | sed 's/^/   /' || echo "   ⚠️  Failed to get geth version"
else
    echo "⚠️  Geth binary not found at: $GETH_BINARY"
fi

echo ""

# Function to get binary architecture and OS
get_binary_info() {
    local binary="$1"
    local arch="unknown"
    local os="unknown"
    
    if command -v file >/dev/null 2>&1; then
        local file_info
        file_info=$(file "$binary" 2>/dev/null)
        
        # Extract architecture
        if echo "$file_info" | grep -qE "(x86-64|amd64|x86_64)"; then
            arch="amd64"
        elif echo "$file_info" | grep -qE "(aarch64|arm64)"; then
            arch="arm64"
        elif echo "$file_info" | grep -qE "386"; then
            arch="386"
        fi
        
        # Extract OS
        if echo "$file_info" | grep -qE "Mach-O"; then
            os="darwin"
        elif echo "$file_info" | grep -qE "ELF"; then
            os="linux"
        elif echo "$file_info" | grep -qE "PE32"; then
            os="windows"
        fi
    elif command -v go >/dev/null 2>&1; then
        # Try to get arch from go version -m
        local go_info
        go_info=$(go version -m "$binary" 2>/dev/null)
        arch=$(echo "$go_info" | grep -oE "GOARCH=[a-z0-9]+" | cut -d= -f2 || echo "unknown")
        os=$(echo "$go_info" | grep -oE "GOOS=[a-z0-9]+" | cut -d= -f2 || echo "unknown")
    fi
    
    echo "$arch|$os"
}

# Check story version
if [ -f "$STORY_BINARY" ]; then
    echo "📦 Story binary found: $STORY_BINARY"
    echo "   Version info:"
    # Try different version command formats
    VERSION_OUTPUT=$("$STORY_BINARY" version 2>&1)
    if [ $? -eq 0 ] && [ -n "$VERSION_OUTPUT" ]; then
        echo "$VERSION_OUTPUT" | sed 's/^/   /'
    else
        VERSION_OUTPUT=$("$STORY_BINARY" --version 2>&1)
        if [ $? -eq 0 ] && [ -n "$VERSION_OUTPUT" ]; then
            echo "$VERSION_OUTPUT" | sed 's/^/   /'
        else
            echo "   ⚠️  Failed to get story version"
        fi
    fi
    
    # Check binary compatibility for Docker
    echo "   Checking Docker compatibility..."
    BINARY_INFO=$(get_binary_info "$STORY_BINARY")
    BINARY_ARCH=$(echo "$BINARY_INFO" | cut -d'|' -f1)
    BINARY_OS=$(echo "$BINARY_INFO" | cut -d'|' -f2)
    
    if [[ "$BINARY_OS" != "linux" ]]; then
        echo "   ❌ Binary OS is $BINARY_OS, but Docker requires Linux"
        echo "   ⚠️  This binary cannot run in Docker containers"
        echo "   💡 You need to build a Linux binary:"
        echo "      GOOS=linux GOARCH=$BINARY_ARCH go build -o story ./client"
    else
        echo "   ✓ Binary OS is Linux (compatible)"
        
        # Try to check Docker container architecture if available
        if command -v docker >/dev/null 2>&1; then
            # Check if we can determine container architecture from an existing container
            # or from docker info
            DOCKER_ARCH=$(docker info --format '{{.Architecture}}' 2>/dev/null | tr -d '\r\n ' || echo "")
            if [ -n "$DOCKER_ARCH" ]; then
                # Normalize architecture names
                case "$DOCKER_ARCH" in
                    x86_64|amd64) DOCKER_ARCH="amd64" ;;
                    aarch64|arm64) DOCKER_ARCH="arm64" ;;
                esac
                
                case "$BINARY_ARCH" in
                    x86-64|amd64|x86_64) BINARY_ARCH_NORM="amd64" ;;
                    aarch64|arm64) BINARY_ARCH_NORM="arm64" ;;
                    *) BINARY_ARCH_NORM="$BINARY_ARCH" ;;
                esac
                
                if [[ "$BINARY_ARCH_NORM" != "unknown" ]] && [[ "$DOCKER_ARCH" != "" ]]; then
                    if [[ "$BINARY_ARCH_NORM" == "$DOCKER_ARCH" ]]; then
                        echo "   ✓ Architecture match: $BINARY_ARCH_NORM (compatible with Docker)"
                    else
                        echo "   ⚠️  Architecture mismatch: binary is $BINARY_ARCH_NORM, Docker is $DOCKER_ARCH"
                        echo "   ⚠️  This may cause issues when running in Docker containers"
                    fi
                fi
            fi
        fi
    fi
else
    echo "⚠️  Story binary not found at: $STORY_BINARY"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -p "Do you want to continue starting the localnet? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Startup cancelled by user"
    exit 1
fi
echo ""


if [ "$USE_LOCAL_BINARY" = "true" ] || [ "$1" = "--use-local-binary" ]; then
    echo "Using local story binary..."
    echo "   Path: $STORY_BINARY"
    
    # Check if story binary exists
    if [ ! -f "$STORY_BINARY" ]; then
        echo "Error: story binary not found at $STORY_BINARY"
        echo "Please build it first: cd ../story && go build -o story ./client"
        exit 1
    fi
    
    # Build image using local binary
    STORY_BINARY_DIR="$(cd "$(dirname "$STORY_BINARY")" && pwd)"
    STORY_BINARY_NAME="$(basename "$STORY_BINARY")"
    docker build -f "${SCRIPT_DIR}/Dockerfile.story-node-local" -t story-node:localnet --build-arg STORY_BINARY="$STORY_BINARY_NAME" "$STORY_BINARY_DIR"
    
    # Use existing image, skip build
    BUILD_FLAG=""
else
    BUILD_FLAG="--build"
fi

# Clean up conflicting containers before starting
echo ""
echo "🧹 Cleaning up any conflicting containers..."
MONITORING_CONTAINERS=("loki" "prometheus" "promtail" "grafana")
for container in "${MONITORING_CONTAINERS[@]}"; do
    if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
        echo "  Stopping and removing $container..."
        docker stop "$container" 2>/dev/null || true
        docker rm "$container" 2>/dev/null || true
    fi
done
echo ""

# Build images if they don't exist (build specific services to avoid parallel conflicts)
if ! docker image inspect story-geth:localnet >/dev/null 2>&1; then
    echo "🔨 Building story-geth image..."
    docker compose -f docker-compose-bootnode1.yml build bootnode1-geth
fi
if ! docker image inspect story-node:localnet >/dev/null 2>&1; then
    echo "🔨 Building story-node image..."
    docker compose -f docker-compose-bootnode1.yml build bootnode1-node
fi

# Start monitoring
docker compose -f docker-compose-monitoring.yml up -d

# Start bootnode (no build needed, images already exist)
docker compose -f docker-compose-bootnode1.yml up -d --no-build
sleep 5

# Start validators (no build needed, images already exist)
docker compose -f docker-compose-validator1.yml up -d --no-build
docker compose -f docker-compose-validator2.yml up -d --no-build
docker compose -f docker-compose-validator3.yml up -d --no-build
docker compose -f docker-compose-validator4.yml up -d --no-build

# Start RPC node
echo "🔗 Starting RPC node..."
docker compose -f docker-compose-rpc1.yml up -d --no-build

# Wait for RPC to be ready
echo "⏳ Waiting for RPC to be ready..."
until curl -s http://localhost:8545 -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | grep -qE '"result":"0x[1-9a-fA-F]'; do
    echo "   Waiting for blocks..."
    sleep 3
done
echo "✅ RPC is ready and producing blocks"

# Start Blockscout
echo "🔍 Starting Blockscout..."
cd blockscout && docker compose up -d
cd ..

# Wait for Blockscout to be ready
echo "⏳ Waiting for Blockscout to be ready..."
until curl -s http://localhost:3080/api/v2/blocks 2>/dev/null | grep -q '"height"'; do
    echo "   Waiting for Blockscout..."
    sleep 5
done
echo "✅ Blockscout is ready"

echo "✅ Story Localnet started!"
echo ""
echo "📍 Endpoints:"
echo "   RPC HTTP:     http://localhost:8545"
echo "   RPC WS:       ws://localhost:8546"
echo "   Blockscout:   http://localhost:3080"
echo "   Grafana:      http://localhost:3000"
