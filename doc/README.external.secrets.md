1. Install Operator (OperatorHub)
        ↓
2. ExternalSecretsConfig
   - triggers ESO controllers to deploy in external-secrets namespace
   - must be done before ClusterSecretStore otherwise no controller to reconcile it
        ↓
3. secret-store namespace
        ↓
4. ServiceAccount (eso-reader) in secret-store namespace
        ↓
5. Role + RoleBinding in secret-store namespace
   - grants eso-reader permission to read secrets
        ↓
6. The actual Secret in secret-store namespace
   - aws-credentials
        ↓
7. ClusterSecretStore
   - references secret-store namespace, eso-reader SA
   - ESO controller must be running (step 2) before this is applied
        ↓
8. ExternalSecret in each target namespace
   - ingress-gateway, cert-manager, etc.
   - ESO reads from secret-store and syncs into these namespaces

Install External Secrets Operator for Red Hat OpenShift
---
Apply ESO CRs

```bash
oc apply -f external-secret-management  
```

Create secret

```bash
oc create secret generic aws-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=$KUADRANT_AWS_ACCESS_KEY_ID \
  --from-literal=AWS_SECRET_ACCESS_KEY=$KUADRANT_AWS_SECRET_ACCESS_KEY \
  -n secret-store
```

Create ExternalSecret in both ingress-gateway and cert-manager namespaces
```bash
oc apply -f manifests/ingress-gateway/rhcl/external-secret.yaml
oc apply -f manifests/cert-manager/external-secret.yaml 
```