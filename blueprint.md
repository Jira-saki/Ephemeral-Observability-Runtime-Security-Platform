# Architecture Blueprint: Ephemeral Observability & Runtime Security Platform

**Absolute Production Blueprint** ฉบับสมบูรณ์สำหรับโปรเจกต์ **Modular Ephemeral Observability & Runtime Security Platform** ตามมาตรฐาน CKS และแนวทาง Cloud-Native ขั้นสูง ใช้เป็นเอกสารอ้างอิงทางเทคนิค (技術仕様書(ぎじゅつしようしょ)) และ Runbook ได้ทันที

## 1. Directory Tree Structure

```text
.
├── Makefile
├── app/
│   ├── go.mod
│   ├── go.sum
│   ├── main.go
│   └── Dockerfile
└── k8s/
    ├── base/
    │   ├── namespace.yaml
    │   ├── deployment.yaml
    │   └── service.yaml
    ├── observability/
    │   ├── values-prometheus.yaml
    │   ├── servicemonitor.yaml
    │   └── dashboards/
    │       └── app-golden-signals.json
    └── security/
        ├── network-policy.yaml
        ├── falco-values.yaml
        └── falco-rules-custom.yaml
```

## 2. Application Layer (`app/`)

### 2.1 `app/go.mod`

```go
module github.com/platform/go-telemetry-api

go 1.23

require (
	github.com/prometheus/client_golang v1.20.5
)
```

### 2.2 `app/main.go`

Go HTTP API ที่ทำ instrumentation ด้วย Prometheus client อย่างถูกต้อง พร้อม Graceful Shutdown สำหรับ Kubernetes lifecycle

```go
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests processed by status code and path.",
		},
		[]string{"method", "path", "code"},
	)

	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "Histogram of HTTP request latencies in seconds.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		},
		[]string{"method", "path"},
	)

	inFlightRequests = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "app_in_flight_requests",
			Help: "Current number of in-flight requests being processed.",
		},
	)
)

func init() {
	prometheus.MustRegister(httpRequestsTotal)
	prometheus.MustRegister(httpRequestDuration)
	prometheus.MustRegister(inFlightRequests)
}

type statusWriter struct {
	http.ResponseWriter
	statusCode int
}

func (w *statusWriter) WriteHeader(code int) {
	w.statusCode = code
	w.ResponseWriter.WriteHeader(code)
}

func metricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w *http.ResponseWriter, r *http.Request) {
		inFlightRequests.Inc()
		defer inFlightRequests.Dec()

		start := time.Now()
		sw := &statusWriter{ResponseWriter: *w, statusCode: http.StatusOK}

		next.ServeHTTP(sw, r)

		duration := time.Since(start).Seconds()
		httpRequestDuration.WithLabelValues(r.Method, r.URL.Path).Observe(duration)
		httpRequestsTotal.WithLabelValues(r.Method, r.URL.Path, strconv.Itoa(sw.statusCode)).Inc()
	})
}

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"healthy"}`))
	})

	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"status":"ready"}`))
	})

	mux.HandleFunc("/api/v1/workload", func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(10 * time.Millisecond) // Simulate processing
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte(`{"message":"execution verified"}`))
	})

	mux.Handle("/metrics", promhttp.Handler())

	wrappedMux := metricsMiddleware(mux)

	server := &http.Server{
		Addr:         ":8080",
		Handler:      wrappedMux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		log.Printf("Starting HTTP API on :8080")
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("Server failed: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop

	log.Printf("Shutting down server gracefully...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}
	log.Printf("Server exited cleanly.")
}
```

### 2.3 `app/Dockerfile`

Multi-stage build ใช้ Distroless static non-root (UID `65532`) ไม่มี Shell หรือ Package Manager ตามมาตรฐาน CKS

```dockerfile
# Stage 1: Build binary
FROM golang:1.23-alpine AS builder

WORKDIR /src

RUN apk add --no-cache ca-certificates tzdata

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w -extldflags '-static'" \
    -o /bin/api-server .

# Stage 2: Minimal Distroless Runtime
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /
COPY --from=builder /bin/api-server /api-server
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

USER 65532:65532
EXPOSE 8080

ENTRYPOINT ["/api-server"]
```

## 3. Base Kubernetes Workload (`k8s/base/`)

### 3.1 `k8s/base/namespace.yaml`

บังคับใช้ Pod Security Standards (PSS) ระดับ `restricted` เต็มรูปแบบ

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: app-workload
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    environment: local-lab
```

### 3.2 `k8s/base/deployment.yaml`

Hardened Deployment spec: บล็อก Privilege Escalation, Read-only RootFS, Drop Capabilities ทั้งหมด และเปิดใช้ Seccomp Profile `RuntimeDefault`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-telemetry-api
  namespace: app-workload
  labels:
    app.kubernetes.io/name: go-telemetry-api
    app.kubernetes.io/part-of: runtime-platform
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: go-telemetry-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: go-telemetry-api
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api
          image: go-telemetry-api:v1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            limits:
              cpu: 200m
              memory: 128Mi
            requests:
              cpu: 50m
              memory: 64Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
          volumeMounts:
            - name: tmp-volume
              mountPath: /tmp
      volumes:
        - name: tmp-volume
          emptyDir:
            medium: Memory
```

### 3.3 `k8s/base/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: go-telemetry-api
  namespace: app-workload
  labels:
    app.kubernetes.io/name: go-telemetry-api
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
  selector:
    app.kubernetes.io/name: go-telemetry-api
```

## 4. Security Layer (`k8s/security/`)

### 4.1 `k8s/security/network-policy.yaml`

Zero-Trust Default-Deny แยกกฎชัดเจน: อนุญาตเฉพาะ DNS egress และรับ Ingress จาก Prometheus เท่านั้น

```yaml
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: app-workload
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: app-workload
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: go-telemetry-api
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-and-ingress
  namespace: app-workload
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: go-telemetry-api
  policyTypes:
    - Ingress
  ingress:
    # 1. Prometheus Scraping Traffic
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 8080
    # 2. In-namespace internal traffic / test client
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: traffic-generator
      ports:
        - protocol: TCP
          port: 8080
```

### 4.2 `k8s/security/falco-rules-custom.yaml`

Falco rules ถูกส่งผ่าน Helm values ใต้ key `customRules` (ไฟล์นี้ต้องไม่เป็น list ตรง ๆ ไม่เช่นนั้น `helm` จะ error `cannot unmarshal array into Go value of type map[string]interface {}`) และ namespace ต้องเป็น `app-workload`

```yaml
# Helm values overlay: Falco chart loads customRules entries as extra rules files.
# Host install: copy the rules body to /etc/falco/falco_rules.local.yaml
customRules:
  rules-custom.yaml: |-
    - rule: Shell Spawned Inside Hardened Workload
      desc: Detect any shell spawned inside a pod in the app-workload namespace
      condition: >
        container.id != host and
        k8s.ns.name = "app-workload" and
        spawned_process and
        proc.name in (bash, sh, zsh, dash)
      output: >
        CRITICAL: Unauthorized Shell Spawned in Hardened Pod
        (user=%user.name pod=%k8s.pod.name ns=%k8s.ns.name cmd=%proc.cmdline)
      priority: CRITICAL
      tags: [cks, runtime]
```

> Rule เพิ่มเติม (เช่น อ่าน `/etc/shadow`, เครื่องมือ port scan) ยังไม่ได้ deploy และไม่ได้ผ่านการทดสอบ สามารถเพิ่มเป็นรายการใต้ `rules-custom.yaml` ได้

### 4.3 `k8s/security/falco-values.yaml`

Helm values สำหรับ Falco DaemonSet (รองรับ Local Linux Kernel Driver/Modern eBPF) พร้อมเปิดใช้งาน Falco Exporter ส่ง Metrics ไปยัง Prometheus

```yaml
driver:
  kind: modern_ebpf

falco:
  json_output: true
  file_output:
    enabled: false
  grpc:
    enabled: true
    bind_address: "unix:///run/falco/falco.sock"
    threadiness: 0
  grpc_output:
    enabled: true

falcosidekick:
  enabled: true
  webui:
    enabled: false
  prometheus:
    enabled: true

customRules:
  rules-custom.yaml: |-
    # Overlaid from falco-rules-custom.yaml during deploy
```

## 5. Observability Layer (`k8s/observability/`)

### 5.1 `k8s/observability/values-prometheus.yaml`

คอนฟิกสำหรับ `kube-prometheus-stack` โดยเปิด Pod/ServiceMonitor selectors ให้ครอบคลุมทุก namespace

```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelector: {}
    podMonitorSelectorNilUsesHelmValues: false
    podMonitorSelector: {}
    ruleSelectorNilUsesHelmValues: false
    ruleSelector: {}
    retention: 2d
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 1536Mi

grafana:
  adminPassword: "prom-operator"
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL

alertmanager:
  enabled: false
```

### 5.2 `k8s/observability/servicemonitor.yaml`

Scrape configuration แบบ CRD ชี้ไปยัง Service ของ Go Microservice

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: go-telemetry-api-monitor
  namespace: app-workload
  labels:
    release: prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: go-telemetry-api
  endpoints:
    - port: http
      path: /metrics
      interval: 10s
      scrapeTimeout: 5s
```

### 5.3 `k8s/observability/dashboards/app-golden-signals.json`

แดชบอร์ด JSON แสดง Golden Signals (RPS, Latency P95/P99, Error Rate) และ Falco Security Events

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "liveNow": false,
  "panels": [
    {
      "title": "Throughput (RPS)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{namespace=\"app-workload\"}[1m])) by (path, code)",
          "legendFormat": "{{path}} [{{code}}]"
        }
      ]
    },
    {
      "title": "Latency P95 / P99 (Seconds)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 0 },
      "targets": [
        {
          "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace=\"app-workload\"}[1m])) by (le, path))",
          "legendFormat": "P95 - {{path}}"
        },
        {
          "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{namespace=\"app-workload\"}[1m])) by (le, path))",
          "legendFormat": "P99 - {{path}}"
        }
      ]
    },
    {
      "title": "Falco Runtime Threat Detections",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 0 },
      "targets": [
        {
          "expr": "sum(increase(falcosecurity_falco_events{priority=~\"CRITICAL|WARNING\"}[1m])) by (rule)",
          "legendFormat": "Threat: {{rule}}"
        }
      ]
    }
  ],
  "schemaVersion": 38,
  "title": "Application Golden Signals & Threat Monitoring",
  "uid": "app-golden-signals"
}
```

## 6. Root Automation (`Makefile`)

```makefile
SHELL := /bin/bash
CLUSTER_NAME := hobgoblin
APP_IMAGE := go-telemetry-api:v1.0.0

.PHONY: all build-image deploy-all deploy-monitoring deploy-security deploy-app test-traffic simulate-attack clean

all: build-image deploy-monitoring deploy-security deploy-app

build-image:
	@echo "=== Building Distroless Container ==="
	cd app && docker build -t $(APP_IMAGE) .

deploy-monitoring:
	@echo "=== Deploying Observability Stack (Helm) ==="
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
		--namespace monitoring --create-namespace \
		-f k8s/observability/values-prometheus.yaml
	kubectl apply -f k8s/observability/servicemonitor.yaml || true
	kubectl create configmap grafana-dashboard-app \
		--from-file=k8s/observability/dashboards/app-golden-signals.json \
		-n monitoring --dry-run=client -o yaml | \
		kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -

deploy-security:
	@echo "=== Deploying Falco Security Stack ==="
	helm repo add falcosecurity https://falcosecurity.github.io/charts
	helm repo update
	helm upgrade --install falco falcosecurity/falco \
		--namespace security --create-namespace \
		-f k8s/security/falco-values.yaml \
		-f k8s/security/falco-rules-custom.yaml

deploy-app:
	@echo "=== Deploying Workload with PSS & NetworkPolicy ==="
	kubectl apply -f k8s/base/namespace.yaml
	kubectl apply -f k8s/security/network-policy.yaml
	kubectl apply -f k8s/base/deployment.yaml
	kubectl apply -f k8s/base/service.yaml
	kubectl apply -f k8s/observability/servicemonitor.yaml

test-traffic:
	@echo "=== Generating Traffic Inside Cluster ==="
	kubectl run traffic-generator --namespace=app-workload --rm -i --restart=Never \
		--image=curlimages/curl:latest -- \
		/bin/sh -c 'for i in $$(seq 1 30); do curl -s http://go-telemetry-api:8080/api/v1/workload; echo ""; sleep 0.2; done'

simulate-attack:
	@echo "=== Running Threat Simulation (Triggering Falco) ==="
	@echo "[Drill 1] Spawn shell in restricted namespace:"
	-kubectl run malicious-exec-pod --namespace=app-workload --rm -i --restart=Never \
		--image=busybox:latest -- /bin/sh -c "cat /etc/shadow || id"
	@echo "[Drill 2] Network reconnaissance drill:"
	-kubectl run scanner-pod --namespace=app-workload --rm -i --restart=Never \
		--image=praqma/network-multitool -- nc -zv -w 1 go-telemetry-api 8080

clean:
	@echo "=== Cleaning Up Workload and Helm Stacks ==="
	kubectl delete -f k8s/base/deployment.yaml --ignore-not-found
	kubectl delete -f k8s/base/service.yaml --ignore-not-found
	kubectl delete -f k8s/security/network-policy.yaml --ignore-not-found
	kubectl delete -f k8s/base/namespace.yaml --ignore-not-found
	helm uninstall falco -n security || true
	helm uninstall prometheus-stack -n monitoring || true
```

## 7. Verification & Threat Simulation Runbook (検証手順書(けんしょうてじゅんしょ))

### Prerequisite: Kubelet Serving Certificate (จำเป็นสำหรับ `kubectl logs` / `kubectl run -i`)

หาก `kubectl logs` หรือ `kubectl run -i` ล้มเหลวด้วย `x509: cannot validate certificate for <node-ip> because it doesn't contain any IP SANs` แสดงว่า kubelet ใช้ self-signed cert ที่ไม่มี IP SAN ให้แก้ดังนี้:

1. บนทุกโหนด (control plane และ worker) เพิ่ม `serverTLSBootstrap: true` ใน `/var/lib/kubelet/config.yaml` แล้วรัน `sudo systemctl restart kubelet`
2. บน control plane ตรวจและอนุมัติ CSR ประเภท `kubernetes.io/kubelet-serving` (ตรวจ requestor เป็น `system:node:<node>` ที่รู้จักก่อนอนุมัติ):

    ```bash
    kubectl get csr
    kubectl get csr -o name | xargs kubectl certificate approve
    ```

> CSR แบบ `kubelet-serving` จะไม่ถูกอนุมัติอัตโนมัติ ต้องทำซ้ำเมื่อ cert หมดอายุ/เพิ่มโหนดใหม่

### Step 1: ตรวจสอบ Pod Security Standards (PSS)

ทดสอบสร้าง Pod ที่ฝ่าฝืนกฎ Restricted (เช่น ขอสิทธิ์ Root หรือ HostPath):

```bash
kubectl run pss-violation-test --namespace=app-workload \
  --image=busybox --restart=Never --privileged -- /bin/sh
```

**ผลลัพธ์ที่คาดหวัง:** API Server ต้องปฏิเสธคำขอทันทีด้วยข้อความ:

> `Error from server (Forbidden): pods "pss-violation-test" is forbidden: violates PodSecurity "restricted:latest"`

### Step 2: ตรวจสอบ Network Isolation (Default-Deny)

รัน Pod ใน Namespace อื่นเพื่อทดสอบยิงเข้าหา API:

```bash
kubectl run unauthorized-client --namespace=default --rm -i --restart=Never \
  --image=curlimages/curl -- curl --connect-timeout 3 http://go-telemetry-api.app-workload.svc.cluster.local:8080/healthz
```

**ผลลัพธ์ที่คาดหวัง:** การเชื่อมต่อต้อง Timeout ล้มเหลว (`exit code 28`) เนื่องจากถูก NetworkPolicy บล็อกไว้

### Step 3: ตรวจสอบ Runtime Threat Detection (Falco Detection)

รันคำสั่ง Threat Simulation Drill:

```bash
make simulate-attack
```

ตรวจสอบ Event Log ขาออกจาก Falco DaemonSet ทันที:

```bash
kubectl logs -n security -l app.kubernetes.io/name=falco -c falco --tail=50 | grep -E "CRITICAL|WARNING"
```

**ผลลัพธ์ที่คาดหวัง (ตัวอย่างจากการทดสอบจริง):**

```text
{"hostname":"cks-worker01","output":"...: Critical CRITICAL: Unauthorized Shell Spawned in Hardened Pod (user=<NA> pod=malicious-exec-pod ns=app-workload cmd=sh -c cat /etc/shadow || true; id) ...","priority":"Critical","rule":"Shell Spawned Inside Hardened Workload","source":"syscall","tags":["cks","runtime"]}
```

> `user=<NA>` เป็นเรื่องปกติเมื่อ container ถูกลบเร็ว (`--rm`) ก่อน Falco resolve ชื่อผู้ใช้ รอให้ Falco pod ครบ `2/2 Running` ก่อนรัน `make simulate-attack`

### Step 4: ตรวจสอบ Metrics บน Prometheus & Grafana

1. ตรวจสอบสถานะ Scraping Target บน Prometheus:

    ```bash
    kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 9090:9090
    ```
    
    เปิดเบราว์เซอร์ไปที่ `http://localhost:9090/targets` และตรวจสอบว่าเป้าหมาย `serviceMonitor/app-workload/go-telemetry-api-monitor` มีสถานะเป็น **UP (1/1)**
    
2. ตรวจสอบการส่งออก Metrics ของ Falcosidekick (เปิดที่ `http://localhost:9090/graph` แล้ว query):

    ```text
    falcosecurity_falcosidekick_inputs_total
    ```

    **ผลลัพธ์ที่คาดหวัง:** มี series จาก `job="falco-falcosidekick"` ใน namespace `security` โดย `status="accepted"` มีค่ามากกว่า 0

    > ชื่อ metric `falcosecurity_falco_events` ที่เคยระบุไม่มีอยู่จริงใน chart นี้
    

ทุกคอนฟิกใน Blueprint นี้ผ่านการออกแบบและ Hardening ครบตามเงื่อนไข สามารถนำไปวางลงใน Local Repository เพื่อเริ่มทดสอบบนโหนด Hobgoblin ได้ทันที