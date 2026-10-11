# Verification Evidence

หลักฐานการทดสอบตาม Runbook ใน [blueprint.md](../blueprint.md) หัวข้อ 7 (ทดสอบบน cluster `cks-cp` + `cks-worker01/02`, 2026-10-11)

## Runbook Step 1: Pod Security Standards (PSS)

สร้าง pod แบบ privileged ใน `app-workload` แล้วถูก API server ปฏิเสธด้วย `violates PodSecurity "restricted:latest"`

![PSS restricted admission blocked](01-pss-restricted-admission-blocked.png)

## Runbook Step 2: Network Isolation (Default-Deny)

pod ใน namespace `default` เรียก `go-telemetry-api` ไม่ได้ (`curl: (28) Connection timed out`)

![NetworkPolicy isolation blocked](03-networkpolicy-isolation-blocked.png)

## Runbook Step 3: Falco Runtime Detection

Falco DaemonSet พร้อมใช้งาน (`2/2 Running` ทุก node):

![Falco DaemonSet ready](02-falco-daemonset-pods.png)

Alert `Shell Spawned Inside Hardened Workload` จาก `malicious-exec-pod` หลังรัน `make simulate-attack`:

![Falco shell detection alert](04-falco-shell-detection-alert.png)

## Runbook Step 4: Prometheus & Grafana

Prometheus target `go-telemetry-api` เป็น **UP (2/2)**:

![Prometheus target health](06-prometheus-target-health.png)

Metric `falcosecurity_falcosidekick_inputs_total` แสดงว่า Falcosidekick รับ event และถูก scrape:

![Falcosidekick Prometheus metrics](05-falcosidekick-prometheus-metrics.png)

Grafana dashboard *Application Golden Signals & Threat Monitoring*:

![Grafana golden signals](07-grafana-golden-signals.png)

ดูขั้นตอนตอบสนองเหตุการณ์ใน [incident-runbook.md](incident-runbook.md) และการติดตั้ง cluster ใน [cluster-install.md](cluster-install.md)
