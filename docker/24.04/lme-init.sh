#!/bin/bash

INIT_FLAG="/opt/.lme_initialized"

if [ ! -f "$INIT_FLAG" ]; then
    echo "Running first-time LME initialization..."
    rm -rf /opt/lme/lme-environment.env
    
    # Copy environment file if it doesn't exist
    cp -n /root/LME/config/example.env /root/LME/config/lme-environment.env

    . /root/LME/docker/24.04/environment.sh    
     
    # Update IPVAR in the environment file with the passed HOST_IP
    if [ ! -z "$HOST_IP" ]; then
        echo "Using HOST_IP: $HOST_IP"
        sed -i "s/IPVAR=.*/IPVAR=$HOST_IP/" /root/LME/config/lme-environment.env
        export IPVAR=$HOST_IP
    else
        echo "Warning: HOST_IP not set, using default IPVAR value"
    fi
    cp -n /root/LME/config/lme-environment.env /opt/lme/lme-environment.env
    
    # Run initial setup with timing
    cd /root/LME/ansible/
    echo "Starting system setup at $(date)"
    time ansible-playbook install_lme_local.yml --tags system
    echo "Starting post-install setup at $(date)"
    time ansible-playbook post_install_local.yml -e "IPVAR=$IPVAR" -e "debug_mode=true"
    echo "Setup completed at $(date)"
    
    # Create flag file to indicate initialization is complete
    touch "$INIT_FLAG"
    echo "First-time initialization complete."
else
    echo "LME already initialized, skipping first-time setup."
    systemctl disable lme-setup.service
    systemctl daemon-reload
fi 