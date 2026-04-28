provider "aws" {
  region = "us-east-1" # Route 53 is global, but a region is required
}

# -------------------------------------------------------------------
# Single subdomain
# -------------------------------------------------------------------
module "demo_subdomain" {
  source = "../modules/route53-subdomain"

  parent_zone_name = "leonlevy.lol"
  subdomain        = "demo"
  delegation_ttl   = 300

  comment = "Demo environment subdomain"

  tags = {
    Environment = "demo"
    ManagedBy   = "terraform"
  }
}

# module "rhoai_subdomain" {
#   source = "../modules/route53-subdomain"

#   parent_zone_name = "leonlevy.lol"
#   subdomain        = "rhoai"
#   delegation_ttl   = 300

#   comment = "RHOAI environment subdomain"

#   tags = {
#     Environment = "rhoai"
#     ManagedBy   = "terraform"
#   }
# }

# -------------------------------------------------------------------
# Multiple subdomains — just call the module multiple times
# -------------------------------------------------------------------
# module "rhoai_subdomain" {
#   source = "../modules/route53-subdomain"

#   parent_zone_name = "leonlevy.lol"
#   subdomain        = "rhoai"
#   delegation_ttl   = 300

#   tags = {
#     Environment = "rhoai"
#     ManagedBy   = "terraform"
#   }
# }

module "pipeline_subdomain" {
  source = "../modules/route53-subdomain"

  parent_zone_name = "leonlevy.lol"
  subdomain        = "pipeline"
  delegation_ttl   = 60 # lower TTL for a frequently-changing API zone

  tags = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

# # -------------------------------------------------------------------
# # Outputs — useful to hand off zone IDs to other Terraform stacks
# # -------------------------------------------------------------------
output "demo_zone_id" {
  value = module.demo_subdomain.zone_id
}

output "demo_name_servers" {
  value = module.demo_subdomain.name_servers
}

# output "rhoai_zone_id" {
#   value = module.rhoai_subdomain.zone_id
# }

output "pipeline_zone_id" {
  value = module.pipeline_subdomain.zone_id
}
