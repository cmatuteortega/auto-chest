#!/bin/bash
# AutoChest Server Setup Script
# Run this on your Ubuntu VPS after uploading the code

set -e  # Exit on error

echo "========================================="
echo "AutoChest Server Setup"
echo "========================================="

# Update system
echo "Updating system packages..."
sudo apt update
sudo apt upgrade -y

# Install Love2D and dependencies
echo "Installing Love2D and Lua dependencies..."
sudo add-apt-repository -y ppa:bartbes/love-stable
sudo apt update
sudo apt install -y love lua5.1 luarocks git xvfb

# Install Lua rocks
echo "Installing Lua dependencies..."
sudo luarocks install lsqlite3complete
sudo luarocks install bcrypt

# Create application directory
echo "Setting up application directory..."
sudo mkdir -p /opt/autochest
sudo chown $USER:$USER /opt/autochest

# Create database directory
sudo mkdir -p /var/lib/autochest
sudo chown $USER:$USER /var/lib/autochest

# Create backup directory
sudo mkdir -p /opt/backups
sudo chown $USER:$USER /opt/backups

echo ""
echo "========================================="
echo "Setup complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Upload your code to /opt/autochest"
echo "2. Run: sudo cp /opt/autochest/deploy/autochest-server.service /etc/systemd/system/"
echo "3. Run: sudo systemctl daemon-reload"
echo "4. Run: sudo systemctl enable autochest-server"
echo "5. Run: sudo systemctl start autochest-server"
echo ""
