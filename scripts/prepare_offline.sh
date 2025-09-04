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
            echo -e "${YELLOW}  Debug: Using podman command: $(which podman)${NC}"
            echo -e "${YELLOW}  Debug: PATH: $PATH${NC}"
            echo -e "${YELLOW}  Debug: User: $(whoami)${NC}"
            echo -e "${YELLOW}  Debug: Groups: $(groups)${NC}"

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
    sudo dpkg -i *.deb

    echo -e "${GREEN}✓ Package installation complete!${NC}"
else
    echo -e "${RED}✗ No .deb files found in debs directory${NC}"
    exit 1
fi

# Set up Nix daemon
echo -e "${YELLOW}Setting up Nix daemon...${NC}"
sudo systemctl enable nix-daemon 2>/dev/null || true
sudo systemctl start nix-daemon 2>/dev/null || true

echo -e "${GREEN}✓ All packages installed successfully!${NC}"
echo -e "${YELLOW}Next: Run ../load_containers.sh to load container images${NC}"
EOF

    chmod +x "$OUTPUT_DIR/packages/install_packages_offline.sh"

    echo -e "${GREEN}✓ Packages downloaded to $OUTPUT_DIR/packages/debs/${NC}"
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
# Run this script on the target system to load container images

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

# Check if podman is available (try multiple paths)
PODMAN_CMD=""
if command -v podman &> /dev/null; then
    PODMAN_CMD="podman"
elif [ -x "/nix/var/nix/profiles/default/bin/podman" ]; then
    PODMAN_CMD="/nix/var/nix/profiles/default/bin/podman"
elif [ -x "/usr/local/bin/podman" ]; then
    PODMAN_CMD="/usr/local/bin/podman"
else
    echo -e "${RED}✗ Podman is not installed or not found${NC}"
    echo -e "${YELLOW}Please install Podman first or run the package installation script${NC}"
    exit 1
fi

echo -e "${GREEN}Using Podman from: $PODMAN_CMD${NC}"

# Load all tar files in the images directory
for tar_file in "$IMAGES_DIR"/*.tar; do
    if [ -f "$tar_file" ]; then
        echo -e "${YELLOW}Loading $(basename "$tar_file")...${NC}"
        if sudo $PODMAN_CMD load -i "$tar_file"; then
            echo -e "${GREEN}✓ Successfully loaded $(basename "$tar_file")${NC}"
        else
            echo -e "${RED}✗ Failed to load $(basename "$tar_file")${NC}"
        fi
    fi
done

echo -e "${GREEN}Container loading complete!${NC}"
echo -e "${YELLOW}Verify loaded images with: $PODMAN_CMD images${NC}"
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
   podman images

5. Run LME installation in offline mode:
   ./install.sh --offline

Alternative Ansible command:
   ansible-playbook ansible/site.yml --extra-vars '{"offline_mode": true}'

CRITICAL NOTES:
===============

- The install_packages_offline.sh script INCLUDES Ansible installation
- This was the missing piece in the original preparation
- Ansible is required before running LME installation
- All packages will be installed via apt (requires internet on prep system)

Troubleshooting:
===============

- Ensure all packages from packages/ directory are installed
- Verify Ansible is installed: ansible --version
- Verify all container images are loaded with 'podman images'
- Check that Nix is properly configured if using Nix-based installation
- Review OFFLINE_INSTALLATION.md for detailed troubleshooting

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
