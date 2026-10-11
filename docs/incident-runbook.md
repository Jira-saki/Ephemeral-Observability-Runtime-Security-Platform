# Incident Runbook: Falco & Anomaly Simulation

Drills for validating detection and alerting. Run only against the lab cluster.
KServe is deferred to phase 3; these drills use `sec-workload/hardened-app` and the Go app in `app-workload`.

## Setup

```bash
kubectl apply -f manifests/workload/namespace.yaml
kubectl apply -f manifests/workload/hardened-app.yaml
kubectl apply -f manifests/workload/isolation-policy.yaml
kubectl apply -f manifests/monitoring/anomaly-rules.yaml
```

## 1. PSA restricted

`hardened-app` is admitted. A privileged pod must be rejected:

```bash
kubectl run pss-violation-test --namespace=sec-workload --image=busybox --restart=Never --privileged -- sleep 60
```

Expected: `Forbidden: violates PodSecurity "restricted:latest"`.

## 2. Falco: shell spawned in a pod

**Hardened workload** (rule in `manifests/falco/falco_rules.local.yaml`):

```bash
kubectl exec -it deploy/hardened-app -n sec-workload -- sh
kubectl logs -n security -l app.kubernetes.io/name=falco -c falco --tail=50 | grep -E "CRITICAL|WARNING"
```

Expected: `CRITICAL: Unauthorized Shell Spawned in Hardened Pod`.

**Platform workload** (`app-workload`, rules in `k8s/security/falco-rules-custom.yaml`):

```bash
make simulate-attack
```

## 3. Network isolation

Default-deny blocks egress other than DNS:

```bash
kubectl exec -n sec-workload deploy/hardened-app -- wget -T 3 -qO- http://go-telemetry-api.app-workload.svc.cluster.local:8080/healthz
```

Expected: timeout. And cross-namespace access to the API:

```bash
kubectl run unauthorized-client --namespace=default --rm -i --restart=Never \
  --image=curlimages/curl -- curl --connect-timeout 3 http://go-telemetry-api.app-workload.svc.cluster.local:8080/healthz
```

Expected: timeout (exit code 28).

## 4. Anomaly alerts (Go app)

`AppRequestSpike` and `AppLatencySpikeP99` in `manifests/monitoring/anomaly-rules.yaml`.

1. Establish a baseline with `make test-traffic`, then send a much larger burst.
2. Open Prometheus `/alerts` (`kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090`).
3. Expected: `AppRequestSpike` goes `Pending` then `Firing` after the `for: 30s` window.

## 5. Reset

If the cluster is broken (for example after etcd or kube-apiserver experiments):

```bash
scripts/00-cleanup-vms.sh && scripts/01-provision-vms.sh
```
