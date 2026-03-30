deploy the tracing system (tempo stack)

```bash
oc apply -k manifests/tracing-system/
```
This will install s3 storage (minio), as well as the temo-stack for distributed tracing