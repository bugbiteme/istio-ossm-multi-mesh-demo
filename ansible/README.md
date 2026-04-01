# Ansible Playbooks – Multi-Mesh Demo

Two modular playbooks that automate the full deployment described in the project READMEs.

| Playbook | Covers |
|---|---|
| `multi_cluster/` | [README.md](../README.md) – two-cluster mesh with east-west federation |
| `single_cluster/` | [README.single.cluster.md](../README.single.cluster.md) – single east cluster |

---

## Directory layout

```
ansible/
├── multi_cluster/
│   ├── site.yml            ← entry point
│   ├── vars/main.yml       ← all variables (contexts, cluster names, versions)
│   └── tasks/
│       ├── 01_rename_contexts.yml
│       ├── 02_install_istioctl.yml
│       ├── 03_verify_clusters.yml
│       ├── 04_install_operators.yml
│       ├── 05_root_ca.yml
│       ├── 06_tracing_system.yml
│       ├── 07_istio_resources.yml
│       ├── 08_kiali.yml
│       └── 09_bookinfo.yml
└── single_cluster/
    ├── site.yml
    ├── vars/main.yml
    └── tasks/
        ├── 01_rename_context.yml
        ├── 02_install_istioctl.yml
        ├── 03_verify_cluster.yml
        ├── 04_install_operators.yml
        ├── 05_root_ca.yml
        ├── 06_tracing_system.yml
        ├── 07_istio_resources.yml
        ├── 08_kiali.yml
        └── 09_bookinfo.yml
```

---

## Prerequisites

- `oc` CLI installed and logged into the target cluster(s)
- Ansible 2.9+
- `become` (sudo) access on the bastion host for the `istioctl` install step

---

## Usage

Run from inside the `multi_cluster/` or `single_cluster/` directory.

```bash
# Run all steps
ansible-playbook site.yml

# Run a single step by tag
ansible-playbook site.yml --tags step5

# Run multiple steps
ansible-playbook site.yml --tags "step6,step7"

# Skip istioctl install (Dev Spaces already has it)
ansible-playbook site.yml --skip-tags step2

# Dry-run (check mode)
ansible-playbook site.yml --check
```

### Available tags

| Tag | Step |
|---|---|
| `step1` | Rename cluster context(s) |
| `step2` | Install `istioctl` |
| `step3` | Verify cluster connectivity |
| `step4` | Install operators + enable user workload monitoring |
| `step5` | Create shared root CA and load into cert-manager |
| `step6` | Install tracing system (MinIO + Tempo) |
| `step7` | Install Istio resources (CNI, control plane, gateways) |
| `step8` | Deploy Kiali |
| `step9` | Deploy Bookinfo app and validate |

---

## Configuration

All tuneable values are in `vars/main.yml`. Key variables:

| Variable | Default | Description |
|---|---|---|
| `ctx_east` | `admin-east` | East cluster kubeconfig context name |
| `ctx_west` | `admin-west` | West cluster kubeconfig context name *(multi only)* |
| `east_cluster` | `cluster-east` | East cluster name for remote secrets |
| `west_cluster` | `cluster-west` | West cluster name for remote secrets *(multi only)* |
| `istio_version` | `1.27.5` | Istio version to download for `istioctl` |
| `apply_console_notifications` | `false` | Apply optional OCP web console banner |
| `start_load_generators` | `false` | Auto-start `loadgen-web.sh` and `loadgen-api.sh` |

---

## Design decisions

| Concern | Approach |
|---|---|
| **Idempotency** | `oc apply` throughout; `--dry-run=client \| oc apply` for `create` commands; `creates:` guard for certificate generation |
| **Waiting** | `oc wait` and `rollout status` for Kubernetes resources; `until/retries/delay` loops for polling custom resources |
| **Context rename** | Checks whether the target context name already exists before renaming; `pause` prompts the user to log into the west cluster before its rename (multi-cluster only) |
| **Root CA** | `stat` check skips key and certificate generation if files already exist |
| **Load generators** | Not started automatically — set `start_load_generators: true` in `vars/main.yml` or run the scripts manually |
| **Dev Spaces** | Steps 2 and 3 can be skipped with `--skip-tags step2,step3` |
| **Multi vs. single** | `07_istio_resources.yml` in `multi_cluster` includes sections 7.3–7.5 (east-west gateways, service exposure, cross-cluster endpoint discovery); `single_cluster` omits these entirely |
