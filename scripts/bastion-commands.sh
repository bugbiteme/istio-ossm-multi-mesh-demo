# for blank RHEL bastion ... helper script 

# Don't run as a script. just use it for reference. 
# TODO: May move this into an md file at some point

# Check available Node.js versions
dnf module list nodejs

# Install (pick the latest available, e.g. 22)
sudo dnf module install nodejs:24 -y

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

# set contect names for each cluster (east/west)
oc config current-context
admin
oc config rename-context $(oc config current-context) admin-east

oc config use-context admin-east