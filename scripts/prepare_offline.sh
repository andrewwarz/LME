#!/bin/bash

# LME Offline Preparation Script
# This script creates a single archive containing everything needed for offline LME installation
#
# What this script does:
# 1. Downloads and caches all required APT packages (.deb files)
# 2. Downloads and caches Nix packages
# 3. Downloads and saves all container images
# 4. Creates a single compressed archive with all resources
# 5. Generates complete offline installation system
#
# The result is a single .tar.gz file that can be transferred to an air-gapped
# system for complete offline installation.

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
    echo "This script prepares a SINGLE ARCHIVE for offline LME installation by:"
    echo "- Installing all prerequisites including Ansible"
    echo "- Downloading and caching all required APT packages (.deb files)"
    echo "- Downloading and caching Nix packages"
    echo "- Downloading and saving all container images"
    echo "- Creating a single compressed archive with everything needed"
    echo "- Generating complete offline installation system"
    echo
    echo "The result is a single .tar.gz file that contains everything needed"
    echo "for offline installation on an air-gapped system."
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

# Install all prerequisites needed for LME
install_prerequisites() {
    echo -e "${YELLOW}Installing all prerequisites...${NC}"

    # Update system
    sudo apt-get update
    sudo apt-get upgrade -y

    # Install common packages
    sudo apt-get install -y curl wget gnupg2 sudo git openssh-client expect

    # Install Debian/Ubuntu specific packages
    sudo apt-get install -y apt-transport-https ca-certificates gnupg lsb-release software-properties-common fuse-overlayfs build-essential python3-pip python3-pexpect locales uidmap

    # Install Ansible properly
    echo -e "${YELLOW}Installing Ansible...${NC}"
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository --yes --update ppa:ansible/ansible
    sudo apt-get update
    sudo apt-get install -y ansible

    # Verify Ansible installation
    if command -v ansible &> /dev/null; then
        echo -e "${GREEN}✓ Ansible installed successfully: $(ansible --version | head -n1)${NC}"
    else
        echo -e "${RED}✗ Failed to install Ansible${NC}"
        exit 1
    fi

    # Install Nix properly
    echo -e "${YELLOW}Installing Nix...${NC}"
    sudo apt-get install -y nix-bin nix-setup-systemd
    sudo systemctl enable nix-daemon
    sudo systemctl start nix-daemon
    
    # Add user to nix-users group
    sudo usermod -a -G nix-users $USER
    
    # Wait a moment for the service to be ready
    sleep 5

    # Set up nix channels as root
    echo -e "${YELLOW}Setting up Nix channels...${NC}"
    sudo nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs
    sudo nix-channel --update

    # Install Podman via Nix as root
    echo -e "${YELLOW}Installing Podman via Nix...${NC}"
    sudo nix-env -iA nixpkgs.podman

    # Create symlink and add to PATH
    sudo ln -sf /nix/var/nix/profiles/default/bin/podman /usr/local/bin/podman
    export PATH=$PATH:/nix/var/nix/profiles/default/bin

    # Set up containers directories and policy (matching playbook setup)
    mkdir -p ~/.config/containers
    sudo mkdir -p /etc/containers

    # Create policy.json file (matching what the playbook does)
    sudo tee /etc/containers/policy.json > /dev/null << 'EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ]
}
EOF

    # Set up storage.conf (matching playbook setup)
    sudo tee /etc/containers/storage.conf > /dev/null << 'EOF'
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
EOF

    # Set up subuid/subgid (matching playbook setup)
    echo "containers:165536:65536" | sudo tee -a /etc/subuid
    echo "containers:165536:65536" | sudo tee -a /etc/subgid

    echo -e "${GREEN}✓ All prerequisites installed${NC}"
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

# Download and cache APT packages
download_apt_packages() {
    echo -e "${YELLOW}Downloading APT packages for offline installation...${NC}"

    # Create package cache directory
    mkdir -p "$OUTPUT_DIR/packages/apt_cache"

    # Define package lists
    COMMON_PACKAGES=(
        "curl"
        "wget"
        "gnupg2"
        "sudo"
        "git"
        "openssh-client"
        "expect"
    )

    DEBIAN_UBUNTU_PACKAGES=(
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
    )

    # Update package lists first
    echo -e "${YELLOW}Updating package lists...${NC}"
    sudo apt-get update

    # Add Ansible PPA to get latest version
    echo -e "${YELLOW}Adding Ansible PPA...${NC}"
    sudo add-apt-repository --yes --update ppa:ansible/ansible
    sudo apt-get update

    # Download common packages
    echo -e "${YELLOW}Downloading common packages...${NC}"
    cd "$OUTPUT_DIR/packages/apt_cache"
    for package in "${COMMON_PACKAGES[@]}"; do
        echo -e "${YELLOW}  Downloading $package...${NC}"
        if apt-get download "$package" 2>/dev/null; then
            echo -e "${GREEN}  ✓ Downloaded $package${NC}"
        else
            echo -e "${RED}  ✗ Failed to download $package${NC}"
        fi
    done

    # Download Debian/Ubuntu specific packages
    echo -e "${YELLOW}Downloading Debian/Ubuntu packages...${NC}"
    for package in "${DEBIAN_UBUNTU_PACKAGES[@]}"; do
        echo -e "${YELLOW}  Downloading $package...${NC}"
        if apt-get download "$package" 2>/dev/null; then
            echo -e "${GREEN}  ✓ Downloaded $package${NC}"
        else
            echo -e "${RED}  ✗ Failed to download $package${NC}"
        fi
    done

    # Download dependencies recursively
    echo -e "${YELLOW}Downloading package dependencies...${NC}"
    ALL_PACKAGES=("${COMMON_PACKAGES[@]}" "${DEBIAN_UBUNTU_PACKAGES[@]}")
    for package in "${ALL_PACKAGES[@]}"; do
        echo -e "${YELLOW}  Downloading dependencies for $package...${NC}"
        apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances "$package" | grep "^\w" | sort -u) 2>/dev/null || true
    done

    # Return to original directory
    cd "$SCRIPT_DIR"

    # Generate package installation script
    cat > "$OUTPUT_DIR/packages/install_packages_offline.sh" << 'EOF'
#!/bin/bash

# Script to install packages offline on the target system
# Run this before running LME installation

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APT_CACHE_DIR="$SCRIPT_DIR/apt_cache"

echo -e "${YELLOW}Installing required packages for LME offline installation...${NC}"

if [ ! -d "$APT_CACHE_DIR" ]; then
    echo -e "${RED}✗ APT cache directory not found: $APT_CACHE_DIR${NC}"
    exit 1
fi

# Install packages from local cache
echo -e "${YELLOW}Installing packages from local cache...${NC}"
cd "$APT_CACHE_DIR"

# Install all .deb files
if ls *.deb 1> /dev/null 2>&1; then
    echo -e "${YELLOW}Installing .deb packages...${NC}"
    sudo dpkg -i *.deb 2>/dev/null || true

    # Fix any dependency issues
    echo -e "${YELLOW}Fixing any dependency issues...${NC}"
    sudo apt-get install -f -y 2>/dev/null || true

    echo -e "${GREEN}✓ Package installation complete!${NC}"
else
    echo -e "${RED}✗ No .deb files found in cache directory${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All packages installed successfully!${NC}"
echo -e "${YELLOW}Next: Run ../load_containers.sh to load container images${NC}"
EOF

    chmod +x "$OUTPUT_DIR/packages/install_packages_offline.sh"

    echo -e "${GREEN}✓ APT packages downloaded and cached in $OUTPUT_DIR/packages/apt_cache/${NC}"
}

# Download and cache Nix packages
download_nix_packages() {
    echo -e "${YELLOW}Downloading Nix packages for offline installation...${NC}"

    # Create Nix cache directory
    mkdir -p "$OUTPUT_DIR/packages/nix_cache"

    # Ensure Nix is available
    if ! command -v nix-env &> /dev/null && ! [ -x "/nix/var/nix/profiles/default/bin/nix-env" ]; then
        echo -e "${RED}✗ Nix is not available. Installing Nix first...${NC}"
        # Nix should already be installed by install_prerequisites
        export PATH=$PATH:/nix/var/nix/profiles/default/bin
    fi

    # Set up environment for Nix operations
    export PATH=$PATH:/nix/var/nix/profiles/default/bin
    export NIX_PATH=nixpkgs=https://nixos.org/channels/nixpkgs-unstable

    # Download Podman and its dependencies
    echo -e "${YELLOW}Downloading Podman via Nix...${NC}"
    if sudo nix-store --export $(sudo nix-instantiate --eval -E 'with import <nixpkgs> {}; podman' | tr -d '"') > "$OUTPUT_DIR/packages/nix_cache/podman.nar" 2>/dev/null; then
        echo -e "${GREEN}✓ Podman exported to NAR archive${NC}"
    else
        echo -e "${YELLOW}Attempting alternative Nix export method...${NC}"
        # Alternative: use nix-env to install and then export
        sudo nix-env -iA nixpkgs.podman
        PODMAN_PATH=$(sudo nix-env -q --out-path podman | cut -d' ' -f2)
        if [ -n "$PODMAN_PATH" ]; then
            sudo nix-store --export $PODMAN_PATH > "$OUTPUT_DIR/packages/nix_cache/podman.nar"
            echo -e "${GREEN}✓ Podman exported to NAR archive${NC}"
        else
            echo -e "${RED}✗ Failed to export Podman${NC}"
        fi
    fi

    # Create Nix installation script
    cat > "$OUTPUT_DIR/packages/install_nix_packages.sh" << 'EOF'
#!/bin/bash

# Script to install Nix packages offline on the target system

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
NIX_CACHE_DIR="$SCRIPT_DIR/nix_cache"

echo -e "${YELLOW}Installing Nix packages for offline LME installation...${NC}"

# Check if Nix is installed
if ! command -v nix-env &> /dev/null && ! [ -x "/nix/var/nix/profiles/default/bin/nix-env" ]; then
    echo -e "${RED}✗ Nix is not installed. Please install Nix first.${NC}"
    echo -e "${YELLOW}Install with: sudo apt-get install nix-bin nix-setup-systemd${NC}"
    exit 1
fi

# Set up Nix environment
export PATH=$PATH:/nix/var/nix/profiles/default/bin

# Ensure Nix daemon is running
if ! systemctl is-active --quiet nix-daemon; then
    echo -e "${YELLOW}Starting Nix daemon...${NC}"
    sudo systemctl enable nix-daemon
    sudo systemctl start nix-daemon
    sleep 5
fi

# Import Nix packages from cache
if [ -f "$NIX_CACHE_DIR/podman.nar" ]; then
    echo -e "${YELLOW}Importing Podman from NAR archive...${NC}"
    if sudo nix-store --import < "$NIX_CACHE_DIR/podman.nar"; then
        echo -e "${GREEN}✓ Podman imported successfully${NC}"

        # Create symlink for easy access
        sudo ln -sf /nix/var/nix/profiles/default/bin/podman /usr/local/bin/podman 2>/dev/null || true

        echo -e "${GREEN}✓ Podman is now available at /usr/local/bin/podman${NC}"
    else
        echo -e "${RED}✗ Failed to import Podman${NC}"
    fi
else
    echo -e "${YELLOW}⚠ No Podman NAR archive found, skipping Nix package installation${NC}"
fi

echo -e "${GREEN}✓ Nix package installation complete!${NC}"
EOF

    chmod +x "$OUTPUT_DIR/packages/install_nix_packages.sh"

    echo -e "${GREEN}✓ Nix packages cached in $OUTPUT_DIR/packages/nix_cache/${NC}"
}

# Create single archive with all offline resources
create_offline_archive() {
    echo -e "${YELLOW}Creating single offline installation archive...${NC}"

    ARCHIVE_NAME="lme-offline-$(date +%Y%m%d-%H%M%S).tar.gz"
    ARCHIVE_PATH="$LME_ROOT/$ARCHIVE_NAME"

    # Create a temporary directory for archive contents
    TEMP_ARCHIVE_DIR=$(mktemp -d)
    ARCHIVE_CONTENT_DIR="$TEMP_ARCHIVE_DIR/lme-offline"

    echo -e "${YELLOW}Preparing archive contents in $ARCHIVE_CONTENT_DIR...${NC}"
    mkdir -p "$ARCHIVE_CONTENT_DIR"

    # Copy all offline resources
    echo -e "${YELLOW}Copying offline resources...${NC}"
    cp -r "$OUTPUT_DIR"/* "$ARCHIVE_CONTENT_DIR/"

    # Copy essential LME files needed for installation
    echo -e "${YELLOW}Copying LME installation files...${NC}"
    mkdir -p "$ARCHIVE_CONTENT_DIR/lme"

    # Copy critical installation files
    cp "$LME_ROOT/install.sh" "$ARCHIVE_CONTENT_DIR/lme/" 2>/dev/null || echo -e "${YELLOW}⚠ install.sh not found${NC}"
    cp -r "$LME_ROOT/ansible" "$ARCHIVE_CONTENT_DIR/lme/" 2>/dev/null || echo -e "${YELLOW}⚠ ansible directory not found${NC}"
    cp -r "$LME_ROOT/config" "$ARCHIVE_CONTENT_DIR/lme/" 2>/dev/null || echo -e "${YELLOW}⚠ config directory not found${NC}"
    cp "$LME_ROOT/README.md" "$ARCHIVE_CONTENT_DIR/lme/" 2>/dev/null || true
    cp "$LME_ROOT/OFFLINE_INSTALLATION.md" "$ARCHIVE_CONTENT_DIR/lme/" 2>/dev/null || true

    # Create master installation script
    cat > "$ARCHIVE_CONTENT_DIR/install_offline.sh" << 'EOF'
#!/bin/bash

# LME Offline Installation Master Script
# This script extracts and installs LME in offline mode

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

echo -e "${GREEN}LME Offline Installation${NC}"
echo -e "${GREEN}========================${NC}"
echo

# Check if we're in the extracted archive directory
if [ ! -d "$SCRIPT_DIR/packages" ] || [ ! -d "$SCRIPT_DIR/container_images" ] || [ ! -d "$SCRIPT_DIR/lme" ]; then
    echo -e "${RED}✗ This script must be run from the extracted LME offline archive directory${NC}"
    echo -e "${YELLOW}Expected directory structure:${NC}"
    echo "  - packages/"
    echo "  - container_images/"
    echo "  - lme/"
    echo "  - install_offline.sh (this script)"
    exit 1
fi

echo -e "${YELLOW}Step 1: Installing system packages...${NC}"
cd "$SCRIPT_DIR/packages"
if [ -f "install_packages_offline.sh" ]; then
    ./install_packages_offline.sh
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Package installation failed${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ Package installation script not found${NC}"
    exit 1
fi

echo -e "${YELLOW}Step 2: Installing Nix packages...${NC}"
if [ -f "install_nix_packages.sh" ]; then
    ./install_nix_packages.sh
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}⚠ Nix package installation had issues, continuing...${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Nix package installation script not found, skipping...${NC}"
fi

echo -e "${YELLOW}Step 3: Loading container images...${NC}"
cd "$SCRIPT_DIR"
if [ -f "load_containers.sh" ]; then
    ./load_containers.sh
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Container loading failed${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ Container loading script not found${NC}"
    exit 1
fi

echo -e "${YELLOW}Step 4: Running LME installation in offline mode...${NC}"
cd "$SCRIPT_DIR/lme"
if [ -f "install.sh" ]; then
    echo -e "${YELLOW}Starting LME installation with offline mode...${NC}"
    ./install.sh --offline "$@"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ LME offline installation completed successfully!${NC}"
    else
        echo -e "${RED}✗ LME installation failed${NC}"
        exit 1
    fi
else
    echo -e "${RED}✗ LME install.sh script not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓ LME offline installation complete!${NC}"
echo -e "${YELLOW}Please refer to the documentation for next steps and configuration.${NC}"
EOF

    chmod +x "$ARCHIVE_CONTENT_DIR/install_offline.sh"

    # Create README for the archive
    cat > "$ARCHIVE_CONTENT_DIR/README_OFFLINE.md" << 'EOF'
# LME Offline Installation Archive

This archive contains everything needed to install LME (Logging Made Easy) on an air-gapped or offline system.

## Contents

- `packages/` - System packages (.deb files) and Nix packages
- `container_images/` - Container image tar files
- `lme/` - LME source code and installation scripts
- `docs/` - Documentation
- `install_offline.sh` - Master installation script
- `load_containers.sh` - Container loading script

## Quick Installation

1. Extract this archive on your target system
2. Run the master installation script:
   ```bash
   sudo ./install_offline.sh
   ```

## Manual Installation Steps

If you prefer to run steps manually:

1. Install system packages:
   ```bash
   cd packages/
   sudo ./install_packages_offline.sh
   ```

2. Install Nix packages (optional):
   ```bash
   sudo ./install_nix_packages.sh
   ```

3. Load container images:
   ```bash
   cd ../
   ./load_containers.sh
   ```

4. Run LME installation:
   ```bash
   cd lme/
   ./install.sh --offline
   ```

## Additional Options

You can pass additional options to the LME installer:
```bash
./install_offline.sh --ip 192.168.1.100 --debug
```

## Troubleshooting

- Ensure you have sudo privileges
- Verify all files extracted properly
- Check that the target system meets LME requirements
- Review logs in case of installation failures

For detailed troubleshooting, see `docs/OFFLINE_INSTALLATION_INSTRUCTIONS.txt`
EOF

    # Create the archive
    echo -e "${YELLOW}Creating compressed archive: $ARCHIVE_PATH${NC}"
    cd "$TEMP_ARCHIVE_DIR"
    if tar -czf "$ARCHIVE_PATH" lme-offline/; then
        echo -e "${GREEN}✓ Archive created successfully: $ARCHIVE_PATH${NC}"

        # Get archive size
        ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
        echo -e "${GREEN}Archive size: $ARCHIVE_SIZE${NC}"
    else
        echo -e "${RED}✗ Failed to create archive${NC}"
        rm -rf "$TEMP_ARCHIVE_DIR"
        exit 1
    fi

    # Clean up temporary directory
    rm -rf "$TEMP_ARCHIVE_DIR"

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

This archive contains all resources needed for offline LME installation in a single file.

Archive Contents:
================
- packages/apt_cache/      : Downloaded .deb packages for offline installation
- packages/nix_cache/      : Nix packages (NAR archives)
- container_images/        : Container image tar files
- lme/                     : LME source code and installation scripts
- docs/                    : Documentation
- install_offline.sh      : Master installation script (RECOMMENDED)
- load_containers.sh       : Container loading script

Quick Installation (RECOMMENDED):
=================================

1. Transfer the lme-offline-*.tar.gz file to your target system

2. Extract the archive:
   tar -xzf lme-offline-*.tar.gz

3. Run the master installation script:
   cd lme-offline
   sudo ./install_offline.sh

That's it! The master script will:
- Install all system packages from the local cache
- Install Nix packages if available
- Load all container images
- Run LME installation in offline mode

Manual Installation Steps:
=========================

If you prefer to run steps manually:

1. Extract the archive:
   tar -xzf lme-offline-*.tar.gz
   cd lme-offline

2. Install system packages:
   cd packages/
   sudo ./install_packages_offline.sh

3. Install Nix packages (optional):
   sudo ./install_nix_packages.sh

4. Load container images:
   cd ../
   ./load_containers.sh

5. Run LME installation:
   cd lme/
   ./install.sh --offline

Additional Options:
==================

You can pass additional options to the installer:
   sudo ./install_offline.sh --ip 192.168.1.100 --debug

Or for manual installation:
   cd lme/
   ./install.sh --offline --ip 192.168.1.100 --debug

CRITICAL NOTES:
===============

- This is a COMPLETE offline installation system
- No internet access required on target system
- All packages are pre-downloaded and cached
- Ansible is included in the package cache
- All container images are pre-downloaded
- HIBP password checks are automatically skipped in offline mode

Troubleshooting:
===============

- Ensure you have sudo privileges on the target system
- Verify the archive extracted completely
- Check available disk space (archive can be several GB)
- Verify all .deb files are present in packages/apt_cache/
- Verify all container .tar files are present in container_images/
- Check that the target system meets LME requirements

Security Notes:
==============

- HIBP password checks are skipped in offline mode
- Use strong, unique passwords (minimum 12 characters)
- Implement proper network security measures
- Apply security updates when internet access becomes available
- The offline installation is designed for air-gapped environments

System Requirements:
===================

- Ubuntu 20.04+ or Debian 10+ (for .deb packages)
- Minimum 8GB RAM
- Minimum 50GB disk space
- sudo privileges
- No internet connection required
EOF

    echo -e "${GREEN}✓ Installation instructions created: $OUTPUT_DIR/docs/OFFLINE_INSTALLATION_INSTRUCTIONS.txt${NC}"
}

# Main execution
main() {
    echo -e "${GREEN}LME Offline Preparation Script${NC}"
    echo -e "${GREEN}==============================${NC}"
    echo

    check_internet
    install_prerequisites
    check_podman
    create_output_dir
    download_containers
    download_apt_packages
    download_nix_packages
    generate_load_script
    generate_instructions
    create_offline_archive

    echo -e "${GREEN}✓ Offline preparation complete!${NC}"
    echo
    echo -e "${GREEN}SINGLE ARCHIVE CREATED!${NC}"
    echo -e "${YELLOW}A single archive file has been created containing:${NC}"
    echo "  - All required system packages (.deb files)"
    echo "  - All required Nix packages"
    echo "  - All container images"
    echo "  - LME installation scripts"
    echo "  - Complete offline installation system"
    echo
    echo -e "${YELLOW}Next steps:${NC}"
    echo "1. Transfer the lme-offline-*.tar.gz file to your target system"
    echo "2. Extract: tar -xzf lme-offline-*.tar.gz"
    echo "3. Run: cd lme-offline && sudo ./install_offline.sh"
    echo
    echo -e "${GREEN}That's it! The single archive contains everything needed for offline installation.${NC}"
}

# Run main function
main
