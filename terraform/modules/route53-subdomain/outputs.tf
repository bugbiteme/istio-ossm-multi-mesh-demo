output "zone_id" {
  description = "The hosted zone ID of the new subdomain zone."
  value       = aws_route53_zone.subdomain.zone_id
}

output "zone_arn" {
  description = "The ARN of the new subdomain hosted zone."
  value       = aws_route53_zone.subdomain.arn
}

output "fqdn" {
  description = "The fully-qualified domain name of the subdomain (e.g. 'demo.leonlevy.lol')."
  value       = local.fqdn
}

output "name_servers" {
  description = "The four nameservers assigned to the subdomain hosted zone."
  value       = aws_route53_zone.subdomain.name_servers
}

output "ns_record_fqdn" {
  description = "The FQDN of the NS delegation record created in the parent zone."
  value       = aws_route53_record.ns_delegation.fqdn
}

output "parent_zone_id" {
  description = "The zone ID of the parent hosted zone (looked up, not managed)."
  value       = data.aws_route53_zone.parent.zone_id
}
