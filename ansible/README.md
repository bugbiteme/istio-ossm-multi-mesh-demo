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
├── requirements.txt        ← pip deps for a local venv (ansible-core + kubernetes client)
├── collections/
│   └── requirements.yml    ← ansible-galaxy (kubernetes.core)
├── includes/
│   └── preflight_oc_api.yml  ← shared `oc` context + API checks (pre_tasks)
├── ansible.cfg
├── multi_cluster/
│   ├── site.yml            ← entry point
│   ├── vars/main.yml       ← all variables (contexts, cluster names, versions)
│   └── tasks/
│       ├── 01_rename_contexts.yml
│       ├── 02_install_istioctl.yml
│       ├── 03_install_operators.yml
│       ├── 04_user_workload_monitoring.yml
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
        ├── 03_install_operators.yml
        ├── 04_user_workload_monitoring.yml
        ├── 05_root_ca.yml
        ├── 06_tracing_system.yml
        ├── 07_istio_resources.yml
        ├── 08_kiali.yml
        └── 09_bookinfo.yml
```

---

## Prerequisites

- `oc` CLI installed on the Ansible controller
- **Single-cluster** (`ansible/single_cluster`): log into the target cluster with `oc login` before running the playbook (step 1 renames the current context to `ctx_east`).
- **Multi-cluster** (`ansible/multi_cluster`): step 1 can create both contexts via `oc login` using environment variables (see **Multi-cluster credentials** below). Later steps still use `oc` / `istioctl` with those context names (for example multi-cluster step 7.5).
- `kubectl` or `kustomize` on the controller host (used by the `kubernetes.core.kustomize` lookup to render `-k` overlays)
- Python 3.10+ (3.11+ recommended) for a local **virtual environment** on the machine that runs Ansible
- `become` (sudo) access on that host for the `istioctl` install step (step 2), unless you skip it

---

## Python virtual environment (recommended)

Run these once per clone (from the repository root, or adjust paths). The venv keeps `ansible-core`, the Kubernetes Python client, and `ansible-galaxy` collections isolated from system Python.

```bash
cd path/to/istio-ossm-multi-mesh-demo/ansible

python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate

pip install --upgrade pip
pip install -r requirements.txt

ansible-galaxy collection install -r collections/requirements.yml
```

Keep the venv activated whenever you run `ansible-playbook` or `ansible-lint`. To leave the venv: `deactivate`.

---

## Usage

Run from inside the `multi_cluster/` or `single_cluster/` directory (with the venv **activated** so `ansible-playbook` uses the same Python as `pip install`).

```bash
source ansible/.venv/bin/activate   # if not already active
cd ansible/single_cluster           # or ansible/multi_cluster

# Run all steps
ansible-playbook site.yml

# Run a single step by tag
ansible-playbook site.yml --tags step5

# Run multiple steps
ansible-playbook site.yml --tags "step6,step7"

# Skip istioctl install (Dev Spaces already has it)
ansible-playbook site.yml --skip-tags step2

# Dry-run (check mode; many tasks still call the cluster / shell)
ansible-playbook site.yml --check
```

**Lint** (optional): from `ansible/` with the same venv active:

```bash
cd ansible
source .venv/bin/activate
ANSIBLE_CONFIG=ansible.cfg ansible-lint single_cluster/site.yml multi_cluster/site.yml
```

If you prefer not to use a venv, install the same packages with `pip install --user` (or your distro’s packages) and run `ansible-galaxy collection install -r ansible/collections/requirements.yml` once.

### Available tags

| Tag | Step |
|---|---|
| `preflight` | Only API/kubeconfig checks (`includes/preflight_oc_api.yml`); use `ansible-playbook site.yml --tags preflight` |
| `step1` | Rename cluster context(s) (kubeconfig only; no cluster API required) |
| `step1_console` | Optional OpenShift console notification manifests (`apply_console_notifications` must be `true`; requires VPN/DNS and a reachable API) |
| `step2` | Install `istioctl` |
| `step3` | Install operators (Subscriptions / CSVs in `openshift-operators`) |
| `step4` | Enable user workload monitoring + wait for `prometheus-user-workload` |
| `step5` | Create shared root CA and load into cert-manager |
| `step6` | Install tracing system (MinIO + Tempo); wait until **all pods** are Ready in `tracing-system` |
| `step7` | Install Istio resources (CNI, control plane, gateways) |
| `step8` | Deploy Kiali |
| `step9` | Deploy Bookinfo app and validate |

### Testing `single_cluster` one step at a time

Run from `ansible/single_cluster` with your venv active and `oc login` done first. Each command runs only that tag’s imported tasks:

```bash
ansible-playbook site.yml --tags step1
ansible-playbook site.yml --tags step2
ansible-playbook site.yml --tags step3
# … through step9
```

Steps assume earlier steps have already succeeded on the cluster (for example, **step8** expects the Tempo signing secret from **step6**, and **step9** expects the ingress **Gateway** from **step7**). To re-run a later step after a failure, either run the missing earlier steps again or fix the cluster by hand to match what those steps would have created.

**Step 1 split:** `--tags step1` only updates kubeconfig (rename / `use-context`). The console banner is **`step1_console`** and calls `oc apply`; if you see `no such host` for the API URL, connect VPN (or fix DNS) before that tag, or leave `apply_console_notifications: false` and skip it. A full `ansible-playbook site.yml` (no `--tags`) still runs the banner when the flag is true.

**API preflight:** Before other steps, plays run `oc cluster-info` with retries, tagged **`always`** and **`preflight`**. It runs automatically with `--tags step5`, full playbooks, etc. It is **skipped** only when you pass **exactly** `--tags step1` (kubeconfig-only work). To **only** run preflight: `ansible-playbook site.yml --tags preflight` from `single_cluster/` or `multi_cluster/`. **Single-cluster** preflight uses the **current** kubeconfig context (`oc cluster-info` with no `--context`) so it still works before step 1 renames the context to `ctx_east`. **Multi-cluster** preflight runs **`oc cluster-info`** for **`ctx_east`** and **`ctx_west`** only when each context **already exists** in kubeconfig (so a full playbook run can start from an empty kubeconfig: preflight skips API checks until after step 1 adds both contexts).

### Multi-cluster credentials (step 1)

When `admin-east` or `admin-west` is missing from kubeconfig, the multi-cluster playbook runs `oc login` for that cluster. Set these on the controller (or override the `multi_cluster_*` variables with `-e`):

| Variable | Environment variable | Purpose |
|---|---|---|
| `multi_cluster_east_api` | `OSSM_MULTI_EAST_API` | East API URL (for example `https://api.cluster-east.example.com:6443`) |
| `multi_cluster_east_user` | `OSSM_MULTI_EAST_USER` | East cluster username |
| `multi_cluster_east_password` | `OSSM_MULTI_EAST_PASSWORD` | East cluster password |
| `multi_cluster_west_api` | `OSSM_MULTI_WEST_API` | West API URL |
| `multi_cluster_west_user` | `OSSM_MULTI_WEST_USER` | West cluster username |
| `multi_cluster_west_password` | `OSSM_MULTI_WEST_PASSWORD` | West cluster password |

Optional: self-signed or untrusted API certificates — export `OSSM_MULTI_OC_LOGIN_INSECURE_SKIP_TLS_VERIFY=1` or pass `-e multi_cluster_oc_login_insecure_skip_tls_verify=true` so `oc login` uses `--insecure-skip-tls-verify=true`. Login tasks use `no_log` to avoid printing passwords; avoid extra `-v` on step 1 if you are sensitive to leakage in argv on the controller.

Example:

```bash
export OSSM_MULTI_EAST_API='https://api.east.example.com:6443'
export OSSM_MULTI_EAST_USER='kubeadmin'
export OSSM_MULTI_EAST_PASSWORD='…'
export OSSM_MULTI_WEST_API='https://api.west.example.com:6443'
export OSSM_MULTI_WEST_USER='kubeadmin'
export OSSM_MULTI_WEST_PASSWORD='…'
cd ansible/multi_cluster && ansible-playbook site.yml --tags step1
```

**Useful skips**

- **`--skip-tags step2`** if `istioctl` is already installed (for example in Dev Spaces).

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
| `multi_cluster_east_*` / `multi_cluster_west_*` | *(from env)* | API URL, user, password for `oc login` when the east/west context is missing *(multi_cluster only; see **Multi-cluster credentials**)* |
| `multi_cluster_oc_login_insecure_skip_tls_verify` | `false` *(or env `OSSM_MULTI_OC_LOGIN_INSECURE_SKIP_TLS_VERIFY`)* | Pass `--insecure-skip-tls-verify=true` to `oc login` *(multi_cluster only)* |
| `start_load_generators` | `false` | Auto-start `loadgen-web.sh` and `loadgen-api.sh` |

---

## Design decisions

| Concern | Approach |
|---|---|
| **Kubernetes API** | `kubernetes.core.k8s` / `k8s_info` with kubeconfig context; kustomize via `lookup('kubernetes.core.kustomize', dir=…)` (**`dir=`** is required — positional terms are ignored by the plugin) |
| **Idempotency** | Server-side `apply` via the collection; `creates:` guard for local certificate generation |
| **Waiting** | `k8s_info` with `until` for CSVs, StatefulSets, gateways, etc.; `oc wait --for=condition=Ready pod --all -n tracing-system` after tracing apply; `oc`/`istioctl` where the collection does not fit |
| **API reachability** | `pre_tasks` import `includes/preflight_oc_api.yml` (`oc cluster-info`, retried) before steps other than kubeconfig-only `step1`; single-cluster uses current context, multi-cluster uses `ctx_east` / `ctx_west` |
| **Context rename** | Checks whether the target context name already exists before renaming; **multi-cluster** step 1 runs `oc login` from `OSSM_MULTI_*` (or `-e multi_cluster_*`) when a context is missing, then renames it to `ctx_east` / `ctx_west` |
| **Root CA** | `stat` check skips key and certificate generation if files already exist |
| **Load generators** | Not started automatically — set `start_load_generators: true` in `vars/main.yml` or run the scripts manually |
| **Dev Spaces** | Skip `istioctl` install with `--skip-tags step2`; API checks come from **preflight** |
| **Multi vs. single** | `07_istio_resources.yml` in `multi_cluster` includes sections 7.3–7.5 (east-west gateways, service exposure, cross-cluster endpoint discovery); `single_cluster` omits these entirely |
