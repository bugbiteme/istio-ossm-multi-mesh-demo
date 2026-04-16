## Oops... I forgot to install cluster-manager before applying the TLSPolicy

No fret. Delete the TLS Policy, install cluster-manager, and delete the pod

```bash
oc delete pod -n openshift-operators kuadrant-operator-controller-manager-XXXXXXXXXX
```

Re apply the TLSPolicy and try again.