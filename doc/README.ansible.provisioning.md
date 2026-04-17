# Ansible provisioning

One modular playbook under `ansible/cluster` automates the full deployment described in the [repository README](../README.md).

---

## Directory layout

```
ansible/cluster
├── site.yml
├── tasks
│   ├── 01_check_contexts.yml
│   ├── 02_install_istioctl.yml
│   ├── 03_install_operators.yml
│   ├── 04_user_workload_monitoring.yml
│   ├── 05_root_ca.yml
│   ├── 06_tracing_system.yml
│   ├── 07_istio_resources.yml
│   ├── 08_kiali.yml
│   ├── 09_bookinfo.yml
│   ├── 10_rhcl_install_operators.yml
│   ├── 11_rhcl_deploy_kuadrant_system.yml
│   ├── 12_rhcl_tls_dns_setup.yml
│   ├── 13_rhcl_enabled_gw.yml
│   ├── 14_rhcl_apply_tls_policy.yml
│   ├── 15_rhcl_apply_dns_policy.yml
│   └── 16_rhcl_update_bookinfo_httproute.yml
└── vars
    └── main.yml
```

### Notable variables in `vars/main.yml`

- `multi_cluster` — set to `true` for multi-cluster tasks, `false` for single-cluster.
- `rhcl_enabled` — set to `true` to deploy RHCL, `false` to skip.

---

## Prerequisites

- `oc` installed on the Ansible controller.
- **Single-cluster:** log into the target cluster with `oc login` before running the playbook (step 1 renames the current context to `ctx_east`).
- **Multi-cluster:** log into **both** east and west clusters and set kubeconfig contexts `**admin-east`** and `**admin-west**` before you run the playbook (see **Multi-cluster kubeconfig** below). The playbook does **not** run `oc login` for you; step 1 only verifies those contexts exist and optionally applies console banners.
- `kubectl` or `kustomize` on the controller (used by the `kubernetes.core.kustomize` lookup for `-k` overlays).
- Python 3.10+ (3.11+ recommended) in a local **virtual environment** on the host that runs Ansible.
- `become` (sudo) on that host for the `istioctl` install step (step 2), unless you skip it.

### Multi-cluster kubeconfig (east and west)

From the repository root (or adjust paths), configure **both** clusters so `oc config get-contexts admin-east` and `oc config get-contexts admin-west` succeed. This mirrors [README.md](../README.md) step **1. Rename contexts for east/west clusters**, without the optional `console-notification.yaml` apply (the playbook can still apply banners in step 1 when `apply_console_notifications` is `true`).

For single-cluster runs, configure the `admin-east` context so the playbook can use it consistently.

**East cluster** — after `oc login` to the east API:

```bash
oc config current-context

oc config rename-context $(oc config current-context) admin-east

oc config use-context admin-east
```

**West cluster** — after `oc login` to the west API:

```bash
oc config current-context

oc config rename-context $(oc config current-context) admin-west

oc config use-context admin-west
```

---

## Python virtual environment (recommended)

Run these once per clone from the repository root (or adjust paths). The venv keeps `ansible-core`, the Kubernetes Python client, and `ansible-galaxy` collections isolated from system Python.

```bash
cd ansible

python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate

pip install --upgrade pip
pip install -r requirements.txt

ansible-galaxy collection install -r collections/requirements.yml
```

Keep the venv activated whenever you run `ansible-playbook` or `ansible-lint`. To leave the venv: `deactivate`.

---

## Usage

Run from inside `ansible/cluster` with the venv **activated** so `ansible-playbook` uses the same Python as `pip install`.

```bash
cd ansible/cluster

# All steps, default vars (single cluster, no RHCL)
ansible-playbook site.yml

# Single cluster with RHCL (assumes ../rhcl/env.sh from rhcl/env.sh.example)
ansible-playbook site.yml -e rhcl_enabled=true

# Multi-cluster OSSM without RHCL (run again later with rhcl_enabled to add RHCL on admin-east)
ansible-playbook site.yml -e multi_cluster=true

# RHCL with MaaS Proxy from RHDP
export LLM_API_KEY='<your token>'
ansible-playbook site.yml -e 'rhcl_enabled=true rhcl_secure_llm=true' 

# Single step by tag
ansible-playbook site.yml --tags step5

# Multiple steps
ansible-playbook site.yml --tags "step6,step7"

# Skip istioctl install (for example when Dev Spaces already provides it)
ansible-playbook site.yml --skip-tags step2

# Dry run (check mode; many tasks still call the cluster or shell)
ansible-playbook site.yml --check
```

Steps assume earlier steps already succeeded on the cluster (for example, **step8** expects the Tempo signing secret from **step6**, and **step9** expects the ingress **Gateway** from **step7**). To re-run a later step after a failure, either run the missing earlier steps again or fix the cluster by hand to match what those steps would have created.

**API preflight:** Before other steps, plays run `oc cluster-info` with retries, tagged `**always`** and `**preflight**`. It runs automatically with `--tags step5`, full playbooks, and so on. It is **skipped** when you pass **only** `--tags step1` (no `preflight` in the list), so step 1 is not blocked by API checks up front. To run **only** preflight: `ansible-playbook site.yml --tags preflight` from `ansible/cluster/`. **Single-cluster** preflight uses the **current** kubeconfig context (`oc cluster-info` with no `--context`) so it still works before step 1 renames the context to `ctx_east`. **Multi-cluster** preflight runs `oc cluster-info` for `**ctx_east`** and `**ctx_west**` only when each context **already exists** in kubeconfig (if a context is missing, that cluster’s preflight is skipped and **step 1** fails with a message pointing at the repository README).

**Useful skips**

- `**--skip-tags step2`** if `istioctl` is already installed (for example in Dev Spaces).

