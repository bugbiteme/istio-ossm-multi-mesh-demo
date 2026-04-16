# OpenShift Connectivity Demo (OSSM + RHCL)

This repository contains manual setup instructions and Ansible playbooks to install, configure, and test **OpenShift Service Mesh** (OSSM 3.x) and **Red Hat Connectivity Link** (RHCL).

Use it to tailor a demo environment for:

- OSSM single cluster
- OSSM multi-cluster
- OSSM with or without RHCL
- RHCL with a minimal OSSM footprint

RHCL currently supports single-cluster deployments; multi-cluster RHCL is under development.

The OSSM portions have been tested on OpenShift clusters running on:

- AWS
- GCP
- Azure

The demo uses the Kubernetes Gateway API for ingress, which integrates with the DNS providers above. On-prem clusters with local DNS have not been tested.

## OSSM prerequisites

If you can provision an OpenShift cluster with DNS from one of the cloud providers listed above, the mesh setup should work.

`cert-manager` operator needs to be installed manually (may already be present if using RHDP).

For Red Hatters, most testing used **AWS with OpenShift Open Environment** in RHDP:

- OpenShift **4.20+**
- Control plane count: **1**
- Control plane instance type: **m6a.4xlarge**

### Multi-cluster mesh

- Provision two OpenShift clusters with the configuration above.
- The demo works whether the clusters are in the same region or different regions.

### RHCL prerequisites 

- A domain registered with AWS Route 53 (this repo uses `leonlevy.lol` as an example).
- A subdomain public hosted zone (for example `demo.leonlevy.lol`).
- In the **parent** hosted zone (`leonlevy.lol`), an **NS** record that delegates the subdomain to the new zone:
  - **Record name:** `demo` (or the label that matches your subdomain).
  - **Type:** `NS`.
  - **Values:** the four nameservers from the `demo.leonlevy.lol` hosted zone.
  - **Routing policy:** Simple.

The above may be automated at a later time.

**Note:** The examples use a specific domain; use your own domain if you want to demonstrate `TLSPolicy` and `DNSPolicy` with RHCL.

## Demo applications

The environment primarily uses the **bookinfo** sample. A small LLM demo for gateway policies may be added later, along with MCP-oriented examples.

## Documentation

- [Single-cluster OSSM setup](doc/README.ossm.single.cluster.md)
- [Multi-cluster OSSM setup](doc/README.ossm.multi.cluster.md)
- [RHCL setup (single cluster)](doc/README.rhcl.ossm.single.md)
- [Ansible provisioning](doc/README.ansible.provisioning.md)
- [Troubleshooting](doc/README.troubleshooting.md)
