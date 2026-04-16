variable "parent_zone_name" {
  description = "The domain name of the existing parent hosted zone (e.g. 'leonlevy.lol')."
  type        = string
}

variable "subdomain" {
  description = "The subdomain label to create (e.g. 'demo'). The module will manage '<subdomain>.<parent_zone_name>'."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9\\-]*[a-z0-9])?$", var.subdomain))
    error_message = "subdomain must be lowercase alphanumeric and may contain hyphens, but cannot start or end with a hyphen."
  }
}

variable "delegation_ttl" {
  description = "TTL (in seconds) for the NS delegation record in the parent zone."
  type        = number
  default     = 300
}

variable "tags" {
  description = "Tags to apply to the new hosted zone."
  type        = map(string)
  default     = {}
}

variable "comment" {
  description = "A comment to attach to the new hosted zone."
  type        = string
  default     = ""
}
