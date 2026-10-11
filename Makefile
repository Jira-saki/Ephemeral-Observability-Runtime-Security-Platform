APP_IMAGE ?= go-telemetry-api:v1.0.0
WORKER_NODES ?= cks-worker01 cks-worker02
NS ?= app-workload
SEC_CTX ?= {"runAsNonRoot":true,"runAsUser":65532,"readOnlyRootFilesystem":true,"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}}

.PHONY: all build-image load-image distribute-image deploy-monitoring deploy-security deploy-app test-traffic simulate-attack clean

all: build-image load-image deploy-monitoring deploy-security deploy-app

build-image:
	@echo "=== Building Distroless Container ==="
	cd app && docker build -t $(APP_IMAGE) .

load-image distribute-image:
	@echo "=== Distributing $(APP_IMAGE) to worker nodes ==="
	@docker save $(APP_IMAGE) > /tmp/app-image.tar
	@for node in $(WORKER_NODES); do \
		echo "--> Transferring & Importing to $$node..."; \
		scp -q /tmp/app-image.tar $$node:/tmp/app-image.tar; \
		ssh $$node "sudo ctr -n k8s.io images import /tmp/app-image.tar && rm -f /tmp/app-image.tar"; \
	done
	@rm -f /tmp/app-image.tar
	@echo "--> Distribution complete."

deploy-monitoring:
	@echo "=== Deploying Observability Stack (Helm) ==="
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update prometheus-community
	helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
		--namespace monitoring --create-namespace \
		-f k8s/observability/values-prometheus.yaml
	@echo "--> Injecting Grafana Dashboard..."
	kubectl create configmap grafana-dashboard-app \
		--from-file=k8s/observability/dashboards/app-golden-signals.json \
		-n monitoring --dry-run=client -o yaml | \
		kubectl label --local -f - grafana_dashboard="1" -o yaml | kubectl apply -f -

deploy-security:
	@echo "=== Deploying Falco Security Stack ==="
	helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
	helm repo update falcosecurity
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
	@echo "--> Waiting for Workload to be ready..."
	kubectl rollout status deployment/go-telemetry-api -n $(NS) --timeout=60s

test-traffic:
	@echo "=== Generating Traffic Inside Cluster ==="
	kubectl run traffic-generator --namespace=$(NS) --rm -i --restart=Never \
		--labels=app.kubernetes.io/name=traffic-generator \
		--image=curlimages/curl:latest \
		--image-pull-policy=IfNotPresent \
		--overrides='{"spec":{"containers":[{"name":"traffic-generator","image":"curlimages/curl:latest","stdin":true,"command":["/bin/sh","-c","for i in $$(seq 1 30); do curl -s http://go-telemetry-api:8080/api/v1/workload; echo; sleep 0.2; done"],"securityContext":$(SEC_CTX)}]}}'

simulate-attack:
	@echo "=== Running Threat Simulation (Triggering Falco) ==="
	@echo "[Drill 1] Spawn shell + read sensitive file attempt:"
	-kubectl run malicious-exec-pod --namespace=$(NS) --rm -i --restart=Never \
		--image=busybox:latest \
		--image-pull-policy=IfNotPresent \
		--overrides='{"spec":{"containers":[{"name":"malicious-exec-pod","image":"busybox:latest","stdin":true,"command":["/bin/sh","-c","cat /etc/shadow || true; id"],"securityContext":$(SEC_CTX)}]}}'
	@echo "[Drill 2] Network reconnaissance drill:"
	-kubectl run scanner-pod --namespace=$(NS) --rm -i --restart=Never \
		--image=busybox:latest \
		--image-pull-policy=IfNotPresent \
		--overrides='{"spec":{"containers":[{"name":"scanner-pod","image":"busybox:latest","stdin":true,"command":["nc","-zv","-w","1","go-telemetry-api","8080"],"securityContext":$(SEC_CTX)}]}}'

clean:
	@echo "=== Cleaning Up Workload and Helm Stacks ==="
	kubectl delete -f k8s/observability/servicemonitor.yaml --ignore-not-found
	kubectl delete -f k8s/base/deployment.yaml --ignore-not-found
	kubectl delete -f k8s/base/service.yaml --ignore-not-found
	kubectl delete -f k8s/security/network-policy.yaml --ignore-not-found
	kubectl delete -f k8s/base/namespace.yaml --ignore-not-found
	kubectl delete configmap grafana-dashboard-app -n monitoring --ignore-not-found
	helm uninstall falco -n security --ignore-not-found || true
	helm uninstall prometheus-stack -n monitoring --ignore-not-found || true
