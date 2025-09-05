#!/bin/bash

# Test script to verify UserNS mapping fixes work correctly

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}Testing UserNS mapping fix functionality...${NC}"

# Create a test directory structure
TEST_DIR="test_quadlet"
mkdir -p "$TEST_DIR"

# Create test container files with UserNS mappings
cat > "$TEST_DIR/lme-fleet-distribution.container" << 'EOF'
[Unit]
Description=Fleet Distribution Server Container Service
Requires=lme-elasticsearch.service
After=lme-elasticsearch.service
PartOf=lme.service
ConditionPathExists=/opt/lme/OFFLINE_MODE

[Service]
Restart=always
TimeoutStartSec=300

[Install]
WantedBy=default.target lme.service

[Container]
ContainerName=lme-fleet-distribution
Image=localhost/distribution:LME_LATEST
Network=lme
HostName=lme-fleet-distribution
PodmanArgs=--network-alias lme-fleet-distribution
PublishPort=8080:8080
UserNS=auto:uidmapping=0:171632:3048,gidmapping=0:171632:3048

# Health check to ensure the distribution server is ready
HealthCmd=CMD-SHELL curl -f http://localhost:8080/health || exit 1
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
EOF

cat > "$TEST_DIR/lme-fleet-server.container" << 'EOF'
[Unit]
Description=Fleet Container Service
Requires=lme-elasticsearch.service
After=lme-elasticsearch.service lme-kibana.service
PartOf=lme.service
ConditionPathExists=/opt/lme/FLEET_SETUP_FINISHED

[Service]
Restart=always
TimeoutStartSec=5400
Environment=ANSIBLE_VAULT_PASSWORD_FILE=/etc/lme/pass.sh

[Install]
WantedBy=default.target lme.service

[Container]
ContainerName=lme-fleet-server
EnvironmentFile=/opt/lme/lme-environment.env
Secret=elastic,type=env,target=KIBANA_FLEET_PASSWORD
Image=localhost/elastic-agent:LME_LATEST
Network=lme
HostName=lme-fleet-server
PodmanArgs=--network-alias lme-fleet-server --requires 'lme-elasticsearch,lme-kibana'
PublishPort=8220:8220
Volume=lme_certs:/certs:ro
Volume=lme_fleet_data:/usr/share/elastic-agent
UserNS=auto:uidmapping=0:171632:3048,gidmapping=0:171632:3048
EOF

echo -e "${YELLOW}Created test container files with UserNS mappings${NC}"

# Test the fix logic
CONTAINERS_TO_FIX=(
    "lme-fleet-distribution.container"
    "lme-fleet-server.container"
)

for container_file in "${CONTAINERS_TO_FIX[@]}"; do
    CONTAINER_PATH="$TEST_DIR/$container_file"
    
    if [ -f "$CONTAINER_PATH" ]; then
        echo -e "${YELLOW}Testing fix for $container_file...${NC}"
        
        # Check if UserNS line exists before fix
        if grep -q "^UserNS=auto:uidmapping=" "$CONTAINER_PATH"; then
            echo -e "${GREEN}✓ Found UserNS mapping line before fix${NC}"
        else
            echo -e "${RED}✗ UserNS mapping line not found before fix${NC}"
            exit 1
        fi
        
        # Backup original file
        cp "$CONTAINER_PATH" "$CONTAINER_PATH.backup.$(date +%Y%m%d-%H%M%S)"
        
        # Apply fix (macOS compatible)
        sed -i '' '/^UserNS=auto:uidmapping=/d' "$CONTAINER_PATH"
        
        # Check if UserNS line was removed
        if ! grep -q "^UserNS=auto:uidmapping=" "$CONTAINER_PATH"; then
            echo -e "${GREEN}✓ UserNS mapping line successfully removed${NC}"
        else
            echo -e "${RED}✗ UserNS mapping line still present after fix${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}✓ Fix test passed for $container_file${NC}"
    else
        echo -e "${RED}✗ Test file not found: $container_file${NC}"
        exit 1
    fi
done

echo -e "${GREEN}✓ All UserNS mapping fix tests passed!${NC}"

# Clean up test files
rm -rf "$TEST_DIR"
echo -e "${YELLOW}Test cleanup completed${NC}"

echo -e "${GREEN}UserNS mapping fix functionality verified successfully!${NC}"
