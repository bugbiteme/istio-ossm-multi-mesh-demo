# for blank RHEL bastion ... helper script 

# Check available Node.js versions
dnf module list nodejs

# Install (pick the latest available, e.g. 22)
sudo dnf module install nodejs:22 -y

# Verify
node --version
npm --version

#install claude-code
sudo npm install -g @anthropic-ai/claude-code

# Download the latest istio release
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.27.5 sh -

# Move istioctl to your PATH
sudo mv istio-*/bin/istioctl /usr/local/bin/

# Verify
istioctl version