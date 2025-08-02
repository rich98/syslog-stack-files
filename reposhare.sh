#!/bin/bash

set -e

# Define ports and paths
declare -A REPO_PORTS=(
    [7.9]=6558
    [8.10]=6559
    [9.6]=6560
)

REPO_BASE="/srv/repos"

# Ensure Python is installed
if ! command -v python3 &>/dev/null; then
    echo "❌ Python3 is required. Installing..."
    sudo dnf install -y python3
fi

# Create and populate dummy repo directories
echo "📁 Creating repository directories..."
sudo mkdir -p "$REPO_BASE"
for repo in "${!REPO_PORTS[@]}"; do
    dir="$REPO_BASE/$repo"
    sudo mkdir -p "$dir"
    echo "✅ $repo directory: $dir"

    # (Optional) Create dummy RPM or copy actual RPMs
    echo "Dummy package" | sudo tee "$dir/readme.txt" > /dev/null

    # Create repodata
    sudo dnf install -y createrepo
    sudo createrepo "$dir"
done

# Start background servers
echo "🚀 Launching local repo servers on custom ports..."
for repo in "${!REPO_PORTS[@]}"; do
    port=${REPO_PORTS[$repo]}
    dir="$REPO_BASE/$repo"
    echo "  - Serving $repo on port $port from $dir"
    sudo nohup python3 -m http.server "$port" --directory "$dir" >/dev/null 2>&1 &
done

# Open firewall ports
echo "🔓 Opening firewall ports..."
for port in "${REPO_PORTS[@]}"; do
    sudo firewall-cmd --permanent --add-port=$port/tcp
done
sudo firewall-cmd --reload

# Create .repo files to consume the custom-port repos (optional)
echo "📄 Creating sample .repo files under /etc/yum.repos.d/"
for repo in "${!REPO_PORTS[@]}"; do
    port=${REPO_PORTS[$repo]}
    sudo tee /etc/yum.repos.d/local-$repo.repo > /dev/null <<EOF
[local-$repo]
name=Local $repo
baseurl=http://localhost:$port/
enabled=1
gpgcheck=0
EOF
done

echo "✅ Repositories set up successfully on ports 6558, 6559, and 6560."
