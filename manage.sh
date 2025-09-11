#!/bin/bash

# Script to manage Aries Mediator Service with automatic internal IP detection and .env update
# Usage: ./manage-mediator.sh [start|stop|restart|logs]

set -e

ENV_FILE=".env"
CADDYFILE="caddy/Caddyfile"

# Get Docker's bridge gateway IP (what actually works for container-to-host communication)
get_internal_ip() {
    # First try Docker's bridge gateway (most reliable for container-to-host communication)
    local docker_gateway=$(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "")
    
    if [ -n "$docker_gateway" ] && [ "$docker_gateway" != "<no value>" ]; then
        echo "$docker_gateway"
        return
    fi
    
    # Fallback: Get the first non-docker, non-loopback private IP
    hostname -I | tr ' ' '\n' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | grep -v '^172\.1[78]\.' | head -1
}

# Enhanced start function with better error handling
start() {
    echo "🚀 Starting Aries Mediator Service..."
    
    # Get and validate internal IP
    local ip=$(get_internal_ip)
    if [ -z "$ip" ]; then
        echo "❌ Could not determine internal IP address."
        echo "Available IPs: $(hostname -I)"
        exit 1
    fi
    
    echo "🔍 Detected internal IP: $ip"
    echo "💡 Using IP as environment variable (not modifying .env)"
    
    # Export the IP for docker-compose
    export INTERNAL_IP="$ip"
    
    # Start services
    echo "🐳 Starting Docker containers..."
    if docker-compose up -d; then
        echo "✅ Mediator stack started successfully!"
        echo "🔍 Using INTERNAL_IP: $ip"
        echo "📊 View logs with: $0 logs"
        echo "📱 Get invitation URL with: $0 invitation"
        echo ""
        echo "⏳ Waiting for mediator to fully initialize..."
        sleep 5
        echo "📱 Attempting to fetch invitation URL..."
        get_invitation
        echo ""
        echo "🔄 Automatically updating wallet .env file..."
        update_wallet_env
    else
        echo "❌ Failed to start containers"
        exit 1
    fi
}

# Enhanced stop function
stop() {
    echo "🛑 Stopping Aries Mediator Service..."
    if docker-compose down; then
        echo "✅ Mediator stack stopped successfully!"
    else
        echo "❌ Failed to stop containers"
        exit 1
    fi
}

# Enhanced restart function
restart() {
    echo "🔄 Restarting Aries Mediator Service..."
    stop
    sleep 2
    start
}

# Enhanced logs function
logs() {
    echo "📋 Showing logs (Ctrl+C to exit)..."
    docker-compose logs --tail=100 --follow
}

# Status function
status() {
    echo "📊 Service Status:"
    docker-compose ps
    echo ""
    echo "🔍 Current INTERNAL_IP: ${INTERNAL_IP:-'Not set'}"
    echo "🔍 Detected IP would be: $(get_internal_ip)"
}

# Validate environment
validate() {
    echo "🔍 Validating environment..."
    
    # Check if docker-compose exists
    if ! command -v docker-compose &> /dev/null; then
        echo "❌ docker-compose not found. Please install Docker Compose."
        exit 1
    fi
    
    # Check if .env file exists
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ .env file not found. Please create it first."
        exit 1
    fi
    
    # Check if Caddyfile exists
    if [ ! -f "$CADDYFILE" ]; then
        echo "❌ Caddyfile not found at $CADDYFILE"
        exit 1
    fi
    
    echo "✅ Environment validation passed!"
}

# Test IP detection
test_ip() {
    echo "🧪 Testing IP detection..."
    echo "🔍 Available IPs: $(hostname -I)"
    echo "🔍 Docker gateway IP: $(docker network inspect bridge --format='{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo 'Not found')"
    echo "🔍 Detected internal IP: $(get_internal_ip)"
    echo ""
    echo "📋 Docker bridge network info:"
    docker network inspect bridge | grep -A 10 -B 2 "Gateway" || echo "Docker bridge network not found"
}

# Get invitation URL from mediator logs
get_invitation() {
    echo "📱 Extracting mediator invitation for mobile wallet..."
    
    # Check if mediator is running
    if ! docker-compose ps mediator | grep -q "Up"; then
        echo "❌ Mediator service is not running. Please start it first with: $0 start"
        return 1
    fi
    
    # Wait a moment for logs to be available
    echo "⏳ Waiting for invitation to be generated..."
    sleep 3
    
    # Extract the invitation URL from logs
    local invitation_url=$(docker-compose logs mediator 2>/dev/null | grep -A 1 "Invitation URL (Connections protocol):" | tail -1 | grep -o 'https://[^[:space:]]*' | head -1)
    
    if [ -n "$invitation_url" ]; then
        echo ""
        echo "✅ Mediator invitation found!"
        echo "📱 Add this URL to your mobile wallet to connect to the mediator:"
        echo ""
        echo "🔗 $invitation_url"
        echo ""
        # update_wallet_env
        echo ""
        echo "💡 This invitation allows your mobile wallet to use this mediator"
        echo "   for receiving messages when your wallet is offline."
        echo ""
        echo "📋 Instructions for mobile wallet setup:"
        echo "   1. Open your Aries-compatible mobile wallet"
        echo "   2. Look for 'Add Connection' or 'Scan QR Code' option"
        echo "   3. Either scan the QR code above or paste the URL"
        echo "   4. Accept the connection to enable mediation"
        echo ""
        update_wallet_env
        echo ""
    else
        echo "❌ No invitation URL found in logs. The mediator might still be starting up."
        echo "💡 Try again in a few seconds, or check logs manually:"
        echo "   docker-compose logs mediator | grep -i invitation"
    fi
}

# Update wallet .env file with new invitation URL
update_wallet_env() {
    local wallet_env_file="/home/azureuser/Downloads/code/aries-wallet/app/.env"
    
    echo "🔄 Updating wallet .env file with new invitation..."
    
    # Check if mediator is running
    if ! docker-compose ps mediator | grep -q "Up"; then
        echo "❌ Mediator service is not running. Please start it first with: $0 start"
        return 1
    fi
    
    # Wait a moment for logs to be available
    echo "⏳ Waiting for invitation to be generated..."
    sleep 3
    
    # Extract the invitation URL from logs
    local invitation_url=$(docker-compose logs mediator 2>/dev/null | grep -A 1 "Invitation URL (Connections protocol):" | tail -1 | grep -o 'https://[^[:space:]]*' | head -1)
    
    if [ -n "$invitation_url" ]; then
        if [ -f "$wallet_env_file" ]; then
            # Backup the original file
            local backup_file="${wallet_env_file}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$wallet_env_file" "$backup_file"
            
            # Update the MEDIATOR_URL in the wallet .env file
            sed -i "s|^MEDIATOR_URL=.*|MEDIATOR_URL=$invitation_url|" "$wallet_env_file"
            
            echo ""
            echo "✅ Successfully updated wallet .env file!"
            echo "📂 File: $wallet_env_file"
            echo "🔗 New MEDIATOR_URL: $invitation_url"
            echo "💾 Backup created: $backup_file"
            echo ""
            echo "📱 Your mobile wallet should now be able to connect using the updated configuration"
            echo "💡 Remember to restart your wallet app to pick up the new configuration"
            return 0
        else
            echo "❌ Wallet .env file not found at: $wallet_env_file"
            echo "💡 Please ensure the aries-wallet project exists at the expected location"
            echo "📂 Expected path: $wallet_env_file"
            return 1
        fi
    else
        echo "❌ No invitation URL found in logs. The mediator might still be starting up."
        echo "💡 Try again in a few seconds, or check logs manually:"
        echo "   docker-compose logs mediator | grep -i invitation"
        return 1
    fi
}

# Enhanced command handling with validation
case "$1" in
    start)
        validate
        start
        ;;
    stop)
        stop
        ;;
    restart)
        validate
        restart
        ;;
    logs)
        logs
        ;;
    status)
        status
        ;;
    validate)
        validate
        ;;
    test-ip)
        test_ip
        ;;
    invitation)
        get_invitation
        ;;
    update-wallet)
        update_wallet_env
        ;;
    validate)
        validate
        ;;
    test-ip)
        test_ip
        ;;
    *)
        echo "🚀 Aries Mediator Service Management Script"
        echo ""
        echo "Usage: $0 [start|stop|restart|logs|status|validate|test-ip|invitation|update-wallet]"
        echo ""
        echo "Commands:"
        echo "  start        - Start the mediator service"
        echo "  stop         - Stop the mediator service"
        echo "  restart      - Restart the mediator service"
        echo "  logs         - Show service logs"
        echo "  status       - Show service status"
        echo "  validate     - Validate environment setup"
        echo "  test-ip      - Test IP detection mechanisms"
        echo "  invitation   - Get mediator invitation URL for mobile wallet"
        echo "  update-wallet - Update aries-wallet .env with new invitation URL"
        echo ""
        exit 1
        ;;
esac
