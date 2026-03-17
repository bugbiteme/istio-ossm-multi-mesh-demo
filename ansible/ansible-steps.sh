# Prereq 
# Ensure you have `[defalt]` and `[redhat]` login profiles in ~/.aws/credentials if you have your own domain
# ```
# [default]
# aws_access_key_id = <ID>
# aws_secret_access_key = <key>

# [redhat]
# aws_access_key_id = <ID>
# aws_secret_access_key = <key>

# ```

#install ansible
sudo dnf install ansible-core -y

# install aws collection and boto3
ansible-galaxy collection install amazon.aws
pip install boto3

# Set your domain before running (e.g. export YOUR_DOMAIN=example.com)
export YOUR_DOMAIN="leonlevy.lol"
echo "YOUR_DOMAIN: ${YOUR_DOMAIN}"

# set up AWS access id/key (if you havent already, make sure you have the [default] and [redhat] profiles)
# aws configure

#Get hosted zone ID
export HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name ${YOUR_DOMAIN} \
  --query "HostedZones[0].Id" \
  --output text | sed 's|/hostedzone/||')

echo "HOSTED_ZONE_ID: ${HOSTED_ZONE_ID}"  

# get ELB DNS name
export INGRESS_HOST=$(aws elb describe-load-balancers --profile redhat \
  --query "LoadBalancerDescriptions[0].DNSName" \
  --output text)

echo "INGRESS_HOST: ${INGRESS_HOST}"

# get ELB hosted zone ID
export ELB_HOSTED_ZONE_ID=$(aws elb describe-load-balancers --profile redhat \
  --query "LoadBalancerDescriptions[0].CanonicalHostedZoneNameID" \
  --output text)

echo "ELB_HOSTED_ZONE_ID: ${ELB_HOSTED_ZONE_ID}"

# run playbook to point domain to ELB (explicit inventory + ansible.cfg reduce warnings)
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-$(dirname "$0")/ansible.cfg}"
ansible-playbook ansible/playbook.yaml -i "localhost," -e "ansible_python_interpreter=/usr/bin/python3.9"