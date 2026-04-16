locals {
  fqdn = "${var.subdomain}.${var.parent_zone_name}"
}

# ------------------------------------------------------------------
# Look up the existing parent hosted zone (read-only — never managed
# or destroyed by this module).
# ------------------------------------------------------------------
data "aws_route53_zone" "parent" {
  name         = var.parent_zone_name
  private_zone = false
}

# ------------------------------------------------------------------
# Create the new subdomain public hosted zone.
# ------------------------------------------------------------------
resource "aws_route53_zone" "subdomain" {
  name    = local.fqdn
  comment = var.comment != "" ? var.comment : "Delegated subdomain zone for ${local.fqdn}"
  tags    = var.tags
}

# ------------------------------------------------------------------
# Add an NS delegation record in the parent zone pointing at the
# four nameservers that AWS assigned to the new subdomain zone.
# ------------------------------------------------------------------
resource "aws_route53_record" "ns_delegation" {
  zone_id = data.aws_route53_zone.parent.zone_id
  name    = local.fqdn
  type    = "NS"
  ttl     = var.delegation_ttl

  records = aws_route53_zone.subdomain.name_servers
}
