"""Generate docs/architecture.png.

Usage:
    sudo apt install graphviz
    pip install diagrams
    python docs/architecture.py
"""
from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.k8s.compute import DaemonSet, Deployment, Pod
from diagrams.k8s.infra import Master, Node
from diagrams.k8s.network import Netpol, SVC
from diagrams.onprem.monitoring import Grafana, Prometheus

OUT = str(Path(__file__).resolve().parent / "architecture")

graph_attr = {
    "fontsize": "20",
    "pad": "0.5",
    "splines": "ortho",
    "nodesep": "0.8",
    "ranksep": "1.2",
}

with Diagram(
    "Ephemeral Observability & Runtime Security Platform",
    filename=OUT,
    outformat="png",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    with Cluster("kubeadm cluster (Calico CNI)"):
        cp = Master("cks-cp\n(control plane)")
        workers = [Node("cks-worker01"), Node("cks-worker02")]

        with Cluster(
            "ns: app-workload\n(PSS restricted, default-deny)",
            graph_attr={"labeljust": "r"},
        ):
            netpol = Netpol("NetworkPolicy")
            svc = SVC("go-telemetry-api\n:8080")
            api = Deployment("go-telemetry-api\n(2 replicas)")
            traffic = Pod("traffic-generator\n(test)")
            attacker = Pod("malicious-exec-pod\n(drill: shell spawn)")

        with Cluster("ns: security"):
            falco = DaemonSet("Falco\n(modern eBPF)")
            sidekick = Deployment("Falcosidekick")

        with Cluster("ns: monitoring"):
            prom = Prometheus("Prometheus")
            grafana = Grafana("Grafana\nGolden Signals")

        cp >> Edge(style="dotted", label="schedules") >> workers

    traffic >> Edge(label="HTTP") >> netpol >> svc >> api
    attacker >> Edge(color="red", style="dashed") >> falco
    falco >> Edge(label="events") >> sidekick
    sidekick >> Edge(label="/metrics") >> prom
    # constraint=false: draw the scrape edge without pulling Prometheus away from Falcosidekick
    prom >> Edge(xlabel="scrape (ServiceMonitor)", constraint="false") >> api
    prom >> Edge(label="queries") >> grafana
