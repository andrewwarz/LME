#!/bin/bash

# LME Offline Preparation Script
# This script helps prepare resources for offline LME installation

# Colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
LME_ROOT="$(dirname "$SCRIPT_DIR")"
CONTAINERS_FILE="$LME_ROOT/config/containers.txt"
OUTPUT_DIR="$LME_ROOT/offline_resources"

# Print usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "This script prepares resources for offline LME installation by:"
    echo "- Downloading and saving container images"
    echo "- Creating a package list for manual download"
    echo "- Generating offline installation instructions"
    echo "- Creating a single archive with all resources"
    echo
    echo "OPTIONS:"
    echo "  -o, --output DIR              Output directory for offline resources (default: ./offline_resources)"
    echo "  -h, --help                    Show this help message"
    echo
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Check if running with internet access
check_internet() {
    echo -e "${YELLOW}Checking internet connectivity...${NC}"
    if curl -s --connect-timeout 5 https://www.google.com > /dev/null; then
        echo -e "${GREEN}✓ Internet connection available${NC}"
        return 0
    else
        echo -e "${RED}✗ No internet connection detected${NC}"
        echo -e "${RED}This script requires internet access to download resources${NC}"
        exit 1
    fi
}

# Check if podman is available
check_podman() {
    echo -e "${YELLOW}Checking for Podman...${NC}"
    if command -v podman &> /dev/null || [ -x "/nix/var/nix/profiles/default/bin/podman" ] || [ -x "/usr/local/bin/podman" ]; then
        echo -e "${GREEN}✓ Podman is available${NC}"
        export PATH=$PATH:/nix/var/nix/profiles/default/bin
        return 0
    else
        echo -e "${RED}✗ Podman is not installed${NC}"
        echo -e "${RED}Please install Podman to download container images${NC}"
        exit 1
    fi
}

# Create output directory
create_output_dir() {
    echo -e "${YELLOW}Creating output directory: $OUTPUT_DIR${NC}"
    mkdir -p "$OUTPUT_DIR/container_images"
    mkdir -p "$OUTPUT_DIR/packages"
    mkdir -p "$OUTPUT_DIR/docs"
}

# Download and save container images
download_containers() {
    echo -e "${YELLOW}Downloading and saving container images...${NC}"

    if [ ! -f "$CONTAINERS_FILE" ]; then
        echo -e "${RED}✗ Containers file not found: $CONTAINERS_FILE${NC}"
        exit 1
    fi

    while IFS= read -r container; do
        if [ -n "$container" ] && [[ ! "$container" =~ ^[[:space:]]*# ]]; then
            echo -e "${YELLOW}Processing: $container${NC}"

            # Extract image name for filename
            image_name=$(echo "$container" | sed 's|.*/||' | sed 's/:/_/g')
            output_file="$OUTPUT_DIR/container_images/${image_name}.tar"

            # Pull the image with debugging
            echo -e "${YELLOW}  Pulling image...${NC}"
            if sudo podman pull "$container"; then
                echo -e "${GREEN}  ✓ Successfully pulled $container${NC}"

                # Save the image
                echo -e "${YELLOW}  Saving image to $output_file...${NC}"
                if sudo podman save -o "$output_file" "$container"; then
                    echo -e "${GREEN}  ✓ Successfully saved to $output_file${NC}"
                    # Make the file readable by the user
                    sudo chown $USER:$USER "$output_file"
                else
                    echo -e "${RED}  ✗ Failed to save $container${NC}"
                fi
            else
                echo -e "${RED}  ✗ Failed to pull $container${NC}"
            fi
            echo
        fi
    done < "$CONTAINERS_FILE"
}

# Download packages for offline installation
download_packages() {
    echo -e "${YELLOW}Downloading packages for offline installation...${NC}"

    # Create package cache directory
    mkdir -p "$OUTPUT_DIR/packages/debs"
    mkdir -p "$OUTPUT_DIR/packages/nix"

    # Define package lists
    PACKAGES=(
        "curl"
        "wget"
        "gnupg2"
        "sudo"
        "git"
        "openssh-client"
        "expect"
        "apt-transport-https"
        "ca-certificates"
        "gnupg"
        "lsb-release"
        "software-properties-common"
        "fuse-overlayfs"
        "build-essential"
        "python3-pip"
        "python3-pexpect"
        "locales"
        "uidmap"
        "ansible"
        "nix-bin"
        "nix-setup-systemd"
    )

    # Update package lists first
    echo -e "${YELLOW}Updating package lists...${NC}"
    sudo apt-get update

    # Add Ansible PPA to get latest version
    echo -e "${YELLOW}Adding Ansible PPA...${NC}"
    sudo add-apt-repository --yes --update ppa:ansible/ansible
    sudo apt-get update

    # Download packages
    echo -e "${YELLOW}Downloading packages...${NC}"
    cd "$OUTPUT_DIR/packages/debs"
    for package in "${PACKAGES[@]}"; do
        echo -e "${YELLOW}  Downloading $package...${NC}"
        apt-get download "$package" 2>/dev/null || echo -e "${RED}  ✗ Failed to download $package${NC}"
    done

    # Download dependencies recursively
    echo -e "${YELLOW}Downloading package dependencies...${NC}"
    for package in "${PACKAGES[@]}"; do
        apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances "$package" | grep "^\w" | sort -u) 2>/dev/null || true
    done

    # Return to original directory
    cd "$SCRIPT_DIR"

    # Download Nix packages for offline installation
    echo -e "${YELLOW}Preparing Nix packages for offline installation...${NC}"

    # Check if Nix is available on the prepare system
    if ! command -v nix-build >/dev/null 2>&1; then
        echo -e "${RED}✗ Nix is not available on this preparation system${NC}"
        echo -e "${RED}Cannot prepare podman for offline installation without Nix${NC}"
        echo -e "${YELLOW}Please install Nix on this system and re-run the prepare script${NC}"
        exit 1
    fi

    # Set up Nix channels if not already configured
    echo -e "${YELLOW}Checking Nix channels configuration...${NC}"
    if ! nix-channel --list | grep -q "nixpkgs"; then
        echo -e "${YELLOW}Adding nixpkgs channel...${NC}"
        nix-channel --add https://nixos.org/channels/nixos-unstable nixpkgs
        nix-channel --update
        echo -e "${GREEN}✓ Nixpkgs channel added and updated${NC}"
    else
        echo -e "${GREEN}✓ Nixpkgs channel already configured${NC}"
        # Update channels to ensure we have latest packages
        echo -e "${YELLOW}Updating Nix channels...${NC}"
        nix-channel --update
    fi

    echo -e "${YELLOW}Building podman package with Nix (this may take several minutes)...${NC}"

    # Build podman without installing it locally
    echo -e "${YELLOW}Running nix-build '<nixpkgs>' -A podman --no-out-link${NC}"
    PODMAN_STORE_PATH=$(nix-build '<nixpkgs>' -A podman --no-out-link 2>&1)
    BUILD_EXIT_CODE=$?

    if [ $BUILD_EXIT_CODE -ne 0 ] || [ -z "$PODMAN_STORE_PATH" ] || [ ! -d "$PODMAN_STORE_PATH" ]; then
        echo -e "${RED}✗ Failed to build podman with nix-build${NC}"
        echo -e "${RED}Error output: $PODMAN_STORE_PATH${NC}"
        echo -e "${YELLOW}This could be due to:${NC}"
        echo -e "${YELLOW}  - Nix daemon not running properly${NC}"
        echo -e "${YELLOW}  - Permission issues with Nix store${NC}"
        echo -e "${YELLOW}  - Network issues downloading packages${NC}"
        echo -e "${YELLOW}Please fix Nix installation and re-run the prepare script${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Successfully built podman at: $PODMAN_STORE_PATH${NC}"

    # Get all runtime dependencies
    echo -e "${YELLOW}Calculating runtime dependencies...${NC}"
    PODMAN_PATHS=$(nix-store -qR "$PODMAN_STORE_PATH" 2>&1)
    DEPS_EXIT_CODE=$?

    if [ $DEPS_EXIT_CODE -ne 0 ] || [ -z "$PODMAN_PATHS" ]; then
        echo -e "${RED}✗ Failed to get podman dependencies${NC}"
        echo -e "${RED}Error: $PODMAN_PATHS${NC}"
        exit 1
    fi

    DEPS_COUNT=$(echo "$PODMAN_PATHS" | wc -l)
    echo -e "${GREEN}✓ Found $DEPS_COUNT dependencies${NC}"

    # Export podman and all its dependencies
    echo -e "${YELLOW}Exporting podman closure (this may take a few minutes)...${NC}"
    if nix-store --export $PODMAN_PATHS > "$OUTPUT_DIR/packages/nix/podman-closure.nar" 2>/dev/null; then
        echo -e "${GREEN}✓ Successfully exported podman closure${NC}"
        
        # Save the store path for reference
        echo "$PODMAN_STORE_PATH" > "$OUTPUT_DIR/packages/nix/podman-store-path.txt"
        echo -e "${GREEN}✓ Store path saved to podman-store-path.txt${NC}"
        
        # Get size of the export
        NAR_SIZE=$(du -h "$OUTPUT_DIR/packages/nix/podman-closure.nar" | cut -f1)
        echo -e "${GREEN}✓ Exported closure size: $NAR_SIZE${NC}"
        
        # Verify the file was created and has content
        if [ ! -s "$OUTPUT_DIR/packages/nix/podman-closure.nar" ]; then
            echo -e "${RED}✗ Exported file is empty or missing${NC}"
            exit 1
        fi
    else
        echo -e "${RED}✗ Failed to export podman closure${NC}"
        exit 1
    fi

    # Generate offline installation script
    cat > "$OUTPUT_DIR/packages/install_packages_offline.sh" << 'EOF'
#!/bin/bash

# Script to install packages offline on the target system

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DEBS_DIR="$SCRIPT_DIR/debs"
NIX_DIR="$SCRIPT_DIR/nix"

echo -e "${YELLOW}Installing required packages for LME offline installation...${NC}"

if [ ! -d "$DEBS_DIR" ]; then
    echo -e "${RED}✗ Debs directory not found: $DEBS_DIR${NC}"
    exit 1
fi

# Install packages from local .deb files
echo -e "${YELLOW}Installing packages from local .deb files...${NC}"
cd "$DEBS_DIR"

# Install all .deb files
if ls *.deb 1> /dev/null 2>&1; then
    echo -e "${YELLOW}Installing .deb packages...${NC}"
    sudo dpkg -i *.deb || true
    # Fix any broken dependencies
    echo -e "${YELLOW}Fixing any broken dependencies...${NC}"
    sudo apt-get install -f -y
    echo -e "${GREEN}✓ Package installation complete!${NC}"
else
    echo -e "${RED}✗ No .deb files found in debs directory${NC}"
    exit 1
fi

# Set up Nix and import podman
if [ -f "$NIX_DIR/podman-closure.nar" ]; then
    echo -e "${YELLOW}Setting up Nix daemon...${NC}"
    sudo systemctl enable nix-daemon 2>/dev/null || true
    sudo systemctl start nix-daemon 2>/dev/null || true

    # Wait for Nix daemon to be ready
    echo -e "${YELLOW}Waiting for Nix daemon to start...${NC}"
    sleep 10

    # Verify Nix daemon is running
    if ! systemctl is-active --quiet nix-daemon; then
        echo -e "${RED}✗ Nix daemon failed to start${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Nix daemon is running${NC}"
    
    # Import Nix packages from offline archive
    echo -e "${YELLOW}Importing Nix packages from offline archive...${NC}"
    export PATH=$PATH:/nix/var/nix/profiles/default/bin
    
    # Import the closure
    if sudo nix-store --import < "$NIX_DIR/podman-closure.nar"; then
        echo -e "${GREEN}✓ Podman packages imported from offline archive${NC}"
    else
        echo -e "${RED}✗ Failed to import Nix packages${NC}"
        exit 1
    fi

    # Install podman from the specific store path if available
    if [ -f "$NIX_DIR/podman-store-path.txt" ]; then
        PODMAN_STORE_PATH=$(cat "$NIX_DIR/podman-store-path.txt")
        echo -e "${YELLOW}Installing podman from store path: $PODMAN_STORE_PATH${NC}"
        
        if [ -d "$PODMAN_STORE_PATH" ]; then
            if sudo nix-env -i "$PODMAN_STORE_PATH"; then
                echo -e "${GREEN}✓ Podman installed successfully from Nix${NC}"
                
                # Remove conflicting Ubuntu podman package if present
                sudo apt-get remove -y podman 2>/dev/null || true
                
                # Create symlinks with proper paths for root access
                echo -e "${YELLOW}Creating podman symlinks for root access...${NC}"
                sudo ln -sf /nix/var/nix/profiles/default/bin/podman /usr/local/bin/podman 2>/dev/null || true
                sudo ln -sf /nix/var/nix/profiles/default/bin/podman /usr/bin/podman 2>/dev/null || true
                
                # Update PATH for root user (critical for sudo -i podman)
                echo -e "${YELLOW}Updating PATH for root user...${NC}"
                echo 'export PATH=/nix/var/nix/profiles/default/bin:$PATH' | sudo tee -a /root/.profile >/dev/null
                echo 'export PATH=/nix/var/nix/profiles/default/bin:$PATH' | sudo tee -a /root/.bashrc >/dev/null
                
                # Also update for current user
                echo 'export PATH=/nix/var/nix/profiles/default/bin:$PATH' | tee -a ~/.profile >/dev/null 2>&1 || true
                echo 'export PATH=/nix/var/nix/profiles/default/bin:$PATH' | tee -a ~/.bashrc >/dev/null 2>&1 || true
                
                # Create podman policy configuration (required for container operations)
                echo -e "${YELLOW}Creating podman policy configuration...${NC}"
                sudo mkdir -p /etc/containers
                sudo tee /etc/containers/policy.json > /dev/null << 'POLICY_EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ],
    "transports":
        {
            "docker-daemon":
                {
                    "": [{"type":"insecureAcceptAnything"}]
                }
        }
}
POLICY_EOF
                echo -e "${GREEN}✓ Podman policy configuration created${NC}"
            else
                echo -e "${RED}✗ Failed to install podman from Nix${NC}"
                exit 1
            fi
        else
            echo -e "${RED}✗ Store path not found: $PODMAN_STORE_PATH${NC}"
            exit 1
        fi
    else
        echo -e "${RED}✗ No store path file found${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ No Nix packages found - podman-closure.nar is missing${NC}"
    echo -e "${RED}The prepare script failed to create the Nix packages${NC}"
    exit 1
fi

# Verify podman installation for both regular user and root
echo -e "${YELLOW}Verifying podman installation...${NC}"
export PATH=/nix/var/nix/profiles/default/bin:$PATH

echo -e "${YELLOW}Checking podman for regular user...${NC}"
if command -v podman >/dev/null 2>&1; then
    PODMAN_VERSION=$(podman --version)
    echo -e "${GREEN}✓ Podman is available for regular user: $PODMAN_VERSION${NC}"
    echo -e "${GREEN}✓ Podman location: $(which podman)${NC}"
else
    echo -e "${RED}✗ Podman not found for regular user${NC}"
fi

echo -e "${YELLOW}Checking podman for root user...${NC}"
if sudo bash -c 'command -v podman' >/dev/null 2>&1; then
    ROOT_PODMAN_VERSION=$(sudo podman --version)
    echo -e "${GREEN}✓ Podman is available for root user: $ROOT_PODMAN_VERSION${NC}"
    echo -e "${GREEN}✓ Root podman location: $(sudo which podman)${NC}"
else
    echo -e "${RED}✗ Podman not found for root user${NC}"
    echo -e "${YELLOW}This will cause issues with 'sudo -i podman' commands${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All packages installed successfully!${NC}"
echo -e "${YELLOW}Next: Run ../load_containers.sh to load container images${NC}"
EOF

    chmod +x "$OUTPUT_DIR/packages/install_packages_offline.sh"

    # Generate systemd container fix script
    cat > "$OUTPUT_DIR/fix_container_configs.sh" << 'EOF'
#!/bin/bash

# Script to fix UserNS mapping issues in systemd container files

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}Fixing UserNS mapping issues in systemd container files...${NC}"

SYSTEMD_CONTAINERS_DIR="/etc/containers/systemd"

if [ ! -d "$SYSTEMD_CONTAINERS_DIR" ]; then
    echo -e "${RED}✗ Systemd containers directory not found: $SYSTEMD_CONTAINERS_DIR${NC}"
    exit 1
fi

# List of containers that commonly have UserNS mapping issues in offline mode
CONTAINERS_TO_FIX=(
    "lme-fleet-distribution.container"
    "lme-fleet-server.container"
    "lme-elasticsearch.container"
    "lme-kibana.container"
    "lme-wazuh-manager.container"
    "lme-elastalert.container"
)

for container_file in "${CONTAINERS_TO_FIX[@]}"; do
    CONTAINER_PATH="$SYSTEMD_CONTAINERS_DIR/$container_file"
    
    if [ -f "$CONTAINER_PATH" ]; then
        echo -e "${YELLOW}Fixing $container_file...${NC}"
        
        # Backup original file
        sudo cp "$CONTAINER_PATH" "$CONTAINER_PATH.backup.$(date +%Y%m%d-%H%M%S)"
        
        # Remove problematic UserNS line
        sudo sed -i '/^UserNS=auto:uidmapping=/d' "$CONTAINER_PATH"
        
        echo -e "${GREEN}✓ Fixed $container_file${NC}"
    else
        echo -e "${YELLOW}⚠ $container_file not found, skipping${NC}"
    fi
done

echo -e "${GREEN}✓ Container configuration fixes applied${NC}"
echo -e "${YELLOW}Reloading systemd daemon...${NC}"
sudo systemctl daemon-reload

echo -e "${GREEN}✓ SystemD container fixes complete${NC}"
EOF

    chmod +x "$OUTPUT_DIR/fix_container_configs.sh"

    echo -e "${GREEN}✓ Packages downloaded and scripts created${NC}"
}

# Create single archive with all offline resources
create_offline_archive() {
    echo -e "${YELLOW}Creating single offline installation archive...${NC}"

    ARCHIVE_NAME="lme-offline-$(date +%Y%m%d-%H%M%S).tar.gz"
    ARCHIVE_PATH="$LME_ROOT/$ARCHIVE_NAME"

    echo -e "${YELLOW}Creating compressed archive: $ARCHIVE_PATH${NC}"
    cd "$(dirname "$OUTPUT_DIR")"
    if tar -czf "$ARCHIVE_PATH" "$(basename "$OUTPUT_DIR")"; then
        echo -e "${GREEN}✓ Archive created successfully: $ARCHIVE_PATH${NC}"

        # Get archive size
        ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
        echo -e "${GREEN}Archive size: $ARCHIVE_SIZE${NC}"
    else
        echo -e "${RED}✗ Failed to create archive${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Single offline archive created: $ARCHIVE_NAME${NC}"
    echo -e "${YELLOW}Transfer this file to your target system and extract it for offline installation.${NC}"
}

# Generate load script for target system
generate_load_script() {
    echo -e "${YELLOW}Generating container load script...${NC}"

    cat > "$OUTPUT_DIR/load_containers.sh" << 'EOF'
#!/bin/bash

# Container Loading Script for Offline LME Installation

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
IMAGES_DIR="$SCRIPT_DIR/container_images"

echo -e "${YELLOW}Loading container images for offline LME installation...${NC}"

if [ ! -d "$IMAGES_DIR" ]; then
    echo -e "${RED}✗ Container images directory not found: $IMAGES_DIR${NC}"
    exit 1
fi

# Check if podman is available (try multiple paths, prioritize root access)
export PATH=/nix/var/nix/profiles/default/bin:$PATH
PODMAN_CMD=""

echo -e "${YELLOW}Checking for podman availability...${NC}"

# Check if root can access podman (this is what we actually need)
if sudo bash -c 'command -v podman' >/dev/null 2>&1; then
    PODMAN_CMD="podman"
    echo -e "${GREEN}✓ Podman is available for root user${NC}"
elif sudo test -x "/nix/var/nix/profiles/default/bin/podman"; then
    PODMAN_CMD="/nix/var/nix/profiles/default/bin/podman"
    echo -e "${GREEN}✓ Podman found in Nix profile${NC}"
elif sudo test -x "/usr/local/bin/podman"; then
    PODMAN_CMD="/usr/local/bin/podman"
    echo -e "${GREEN}✓ Podman found in /usr/local/bin${NC}"
else
    echo -e "${RED}✗ Podman is not installed or not accessible to root${NC}"
    echo -e "${YELLOW}Please install Podman first or run the package installation script${NC}"
    exit 1
fi

echo -e "${GREEN}Using Podman: $PODMAN_CMD${NC}"

# Load all tar files in the images directory
LOADED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0

for tar_file in "$IMAGES_DIR"/*.tar; do
    if [ -f "$tar_file" ]; then
        # Extract expected image name from tar filename
        image_name=$(basename "$tar_file" .tar)
        
        # Check if image is already loaded
        if sudo $PODMAN_CMD images --format "{{.Repository}}:{{.Tag}}" | grep -q "$image_name" || \
           sudo $PODMAN_CMD images --format "{{.Repository}}" | grep -q "$(echo $image_name | cut -d'_' -f1)"; then
            echo -e "${GREEN}✓ $(basename "$tar_file") already loaded, skipping${NC}"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        else
            echo -e "${YELLOW}Loading $(basename "$tar_file")...${NC}"
            if sudo $PODMAN_CMD load -i "$tar_file"; then
                echo -e "${GREEN}✓ Successfully loaded $(basename "$tar_file")${NC}"
                LOADED_COUNT=$((LOADED_COUNT + 1))
            else
                echo -e "${RED}✗ Failed to load $(basename "$tar_file")${NC}"
                FAILED_COUNT=$((FAILED_COUNT + 1))
            fi
        fi
    fi
done

echo
echo -e "${GREEN}Container loading summary:${NC}"
echo -e "${GREEN}  Successfully loaded: $LOADED_COUNT${NC}"
echo -e "${YELLOW}  Already loaded (skipped): $SKIPPED_COUNT${NC}"
if [ $FAILED_COUNT -gt 0 ]; then
    echo -e "${RED}  Failed to load: $FAILED_COUNT${NC}"
fi

echo -e "${YELLOW}Verify loaded images with: sudo $PODMAN_CMD images${NC}"

if [ $FAILED_COUNT -gt 0 ]; then
    exit 1
fi
EOF

    chmod +x "$OUTPUT_DIR/load_containers.sh"
    echo -e "${GREEN}✓ Container load script created: $OUTPUT_DIR/load_containers.sh${NC}"
}

# Generate installation instructions
generate_instructions() {
    echo -e "${YELLOW}Generating offline installation instructions...${NC}"

    cat > "$OUTPUT_DIR/docs/OFFLINE_INSTALLATION_INSTRUCTIONS.txt" << EOF
LME Offline Installation Instructions
====================================

This directory contains all resources needed for offline LME installation.

Directory Structure:
- container_images/     : Container image tar files
- packages/            : Package lists and installation scripts
- docs/               : Documentation
- load_containers.sh  : Script to load container images

Steps for Offline Installation:
==============================

1. Transfer this entire directory to the target system

2. Install required system packages:
   cd packages/
   sudo ./install_packages_offline.sh

3. Load container images:
   cd ../
   ./load_containers.sh

4. Verify images are loaded:
   sudo podman images

5. Run LME installation in offline mode:
   ./install.sh --offline

CRITICAL NOTES:
===============

- Podman is installed via Nix and must be accessible to root user
- Use 'sudo podman' or 'sudo -i podman' for container operations
- All container images will be loaded for root user access
- The installation scripts handle root PATH configuration

Troubleshooting:
===============

- Ensure all packages from packages/ directory are installed
- Verify Ansible is installed: ansible --version
- Verify podman is available to root: sudo podman --version
- Verify all container images are loaded with 'sudo podman images'
- Check that root can access podman: sudo which podman

Security Notes:
==============

- HIBP password checks are skipped in offline mode
- Use strong, unique passwords (minimum 12 characters)
- Implement proper network security measures
- Apply security updates when internet access becomes available
EOF

    echo -e "${GREEN}✓ Installation instructions created: $OUTPUT_DIR/docs/OFFLINE_INSTALLATION_INSTRUCTIONS.txt${NC}"
}

# Main execution
main() {
    echo -e "${GREEN}LME Offline Preparation Script${NC}"
    echo -e "${GREEN}==============================${NC}"
    echo

    check_internet
    check_podman
    create_output_dir
    download_containers
    download_packages
    generate_load_script
    generate_instructions
    create_offline_archive

    echo -e "${GREEN}✓ Offline preparation complete!${NC}"
    echo -e "${YELLOW}Resources saved to archive: lme-offline-*.tar.gz${NC}"
    echo
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Transfer the lme-offline-*.tar.gz file to your target system"
    echo "2. Extract: tar -xzf lme-offline-*.tar.gz"
    echo "3. On target system: cd offline_resources/packages && sudo ./install_packages_offline.sh"
    echo "4. On target system: cd .. && ./load_containers.sh"
    echo "5. Run LME installation with --offline flag"
    echo
    echo -e "${YELLOW}For detailed instructions, see the extracted docs/OFFLINE_INSTALLATION_INSTRUCTIONS.txt${NC}"
}

# Run main function
main