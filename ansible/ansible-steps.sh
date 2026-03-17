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
export YOUR_DOMAIN="<change to your domain here>"
echo "YOUR_DOMAIN: ${YOUR_DOMAIN}"

# set up AWS access id/key (if you havent already, make sure you have the [default] and [redhat] profiles)
# aws configure

#Get hosted zone ID
export HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name ${YOUR_DOMAIN} \
  --query "HostedZones[0].Id" \
  --output text | sed 's|/hostedzone/||')

# get ELB DNS name
export INGRESS_HOST=$(aws elb describe-load-balancers --profile redhat \
  --query "LoadBalancerDescriptions[0].DNSName" \
  --output text)

# get ELB hosted zone ID
export ELB_HOSTED_ZONE_ID=$(aws elb describe-load-balancers --profile redhat \
  --query "LoadBalancerDescriptions[0].CanonicalHostedZoneNameID" \
  --output text)

# run playbook to point domain to ELB
ansible-playbook ansible/playbook.yaml -e "ansible_python_interpreter=/usr/bin/python3.9"

# URl should be
# http://${YOUR_DOMAIN}/productpage

curl -so  -w "%{http_code}\n" http://${YOUR_DOMAIN}/productpage | grep "<title>Simple Bookstore App</title>"