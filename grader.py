import subprocess
import json
import time
import urllib.request
import urllib.parse
from apex_arena._types import GradingResult


def run_kubectl_command(*args, namespace=None, timeout=15):
    """Execute a kubectl command and return stdout."""
    cmd = ["kubectl"]
    if namespace:
        cmd.extend(["-n", namespace])
    cmd.extend(args)

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout
        )
        return result.stdout.strip(), result.returncode
    except Exception as e:
        print(f"Error running kubectl command: {e}")
        return "", 1


def cleanup_agent_counter_enforcement():
    """
    Remove agent-deployed counter-enforcement before grading.

    - Kills all ubuntu user processes (shell counter-loops run as ubuntu)
    - Waits 90s so any surviving enforcer CronJobs/crons fire at least once.

    If the agent deleted the real enforcers: state stays good after 90s.
    If the agent only ran counter-loops: enforcers refire and revert.
    """
    print("=== Pre-grading cleanup: removing agent counter-enforcement ===")

    # Kill all ubuntu user processes (shell-based counter-loops)
    subprocess.run(["pkill", "-9", "-u", "ubuntu"], capture_output=True)
    time.sleep(3)

    # Delete any Jobs agent created in platform-ops
    subprocess.run(
        ["kubectl", "delete", "jobs", "--all", "-n", "platform-ops"],
        capture_output=True, timeout=20
    )

    # Wait 90s — each real CronJob/cron fires on the minute boundary.
    print("Waiting 90 seconds for enforcement durability check...")
    time.sleep(90)
    print("=== Durability window complete — reading state now ===")


def query_loki(query, limit=10):
    """Query Loki and return results using series API (works for label queries)."""
    try:
        # Try multiple possible Loki endpoints
        for ns in ["monitoring", "loki"]:
            # First try query_range for log queries
            try:
                end = int(time.time())
                start = end - 600  # Last 10 minutes
                url = f"http://loki.{ns}.svc.cluster.local:3100/loki/api/v1/query_range?query={urllib.parse.quote(query)}&limit={limit}&start={start}000000000&end={end}000000000"
                req = urllib.request.Request(url, method="GET")
                with urllib.request.urlopen(req, timeout=15) as resp:
                    data = json.loads(resp.read().decode())
                    results = data.get("data", {}).get("result", [])
                    if results:
                        return results
            except Exception:
                pass
            # Fallback to series API for label existence checks
            try:
                url = f"http://loki.{ns}.svc.cluster.local:3100/loki/api/v1/series"
                encoded_match = urllib.parse.urlencode({"match[]": query})
                url = f"{url}?{encoded_match}"
                req = urllib.request.Request(url, method="GET")
                with urllib.request.urlopen(req, timeout=15) as resp:
                    data = json.loads(resp.read().decode())
                    series = data.get("data", [])
                    if series:
                        # Convert series to result format for compatibility
                        return [{"stream": s} for s in series]
            except Exception:
                continue
        return []
    except Exception as e:
        print(f"Error querying Loki: {e}")
        return []


def check_prometheus_metric(metric_name):
    """Check if a metric exists in Prometheus."""
    try:
        # Try multiple possible Prometheus service names
        svc_names = [
            "prometheus.monitoring",
            "prometheus-kube-prometheus-stack-prometheus.monitoring",
            "prometheus.kube-prometheus",
        ]
        for svc in svc_names:
            url = f"http://{svc}.svc.cluster.local:9090/api/v1/query?query={urllib.parse.quote(metric_name)}"
            try:
                req = urllib.request.Request(url, method="GET")
                with urllib.request.urlopen(req, timeout=10) as resp:
                    data = json.loads(resp.read().decode())
                    results = data.get("data", {}).get("result", [])
                    return results
            except Exception:
                continue
        return []
    except Exception as e:
        print(f"Error querying Prometheus: {e}")
        return []


def grade(transcript: str) -> GradingResult:
    """
    Grade the agent's solution for Fluent Bit DaemonSet log enrichment.

    5 subscores with 4 checks each = 20 checks total.
    All checks within a subscore must pass for 1.0 (all-or-nothing).

    Subscores:
    1. daemonset_running_stable     — DaemonSet in monitoring, pods ready, priority, enforcers gone
    2. node_metadata_enrichment     — Loki has node_name, kernel_version, node_labels labels
    3. resource_controls            — requests/limits set, system-node-critical, no blocking quota/limitrange
    4. prometheus_metrics           — ServiceMonitor works, Prometheus scrapes fluent-bit metrics
    5. gitops_integration           — ArgoCD Application synced, healthy, correct repo, selfHeal
    """
    # ── Cleanup phase ────────────────────────────────────────────────────────
    cleanup_agent_counter_enforcement()

    subscores = {}
    weights = {}
    WEIGHT = 1.0 / 5.0  # Equal weight: 0.2 each

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 1: daemonset_running_stable (0.20)
    # C1.1: DaemonSet 'fluent-bit' exists in 'monitoring' namespace
    # C1.2: desiredNumberScheduled == numberReady (all pods running)
    # C1.3: Pod has priorityClassName: system-node-critical
    # C1.4: Enforcer cron files and static pod manifest removed
    # ═════════════════════════════════════════════════════════════════════════
    print("\n=== SUBSCORE 1: DaemonSet Running & Stable ===")
    s1_checks = []

    # C1.1: DaemonSet exists in monitoring
    try:
        stdout, rc = run_kubectl_command(
            "get", "daemonset", "fluent-bit", "-o", "json",
            namespace="monitoring", timeout=10
        )
        if rc == 0:
            ds = json.loads(stdout)
            kind = ds.get("kind", "")
            if kind == "DaemonSet":
                print("✓ C1.1: DaemonSet fluent-bit exists in monitoring namespace")
                s1_checks.append(True)
            else:
                print(f"✗ C1.1: Resource is {kind}, not DaemonSet")
                s1_checks.append(False)
        else:
            print("✗ C1.1: DaemonSet fluent-bit not found in monitoring namespace")
            # Check if it's still a Deployment in logging
            _, rc2 = run_kubectl_command("get", "deployment", "fluent-bit", namespace="logging", timeout=5)
            if rc2 == 0:
                print("  (Still exists as Deployment in logging namespace)")
            s1_checks.append(False)
    except Exception as e:
        print(f"✗ C1.1: Error: {e}")
        s1_checks.append(False)

    # C1.2: All pods are running
    try:
        if s1_checks[0]:  # Only check if DaemonSet exists
            desired = int(ds.get("status", {}).get("desiredNumberScheduled", 0))
            ready = int(ds.get("status", {}).get("numberReady", 0))
            if desired > 0 and desired == ready:
                print(f"✓ C1.2: All pods running ({ready}/{desired})")
                s1_checks.append(True)
            else:
                print(f"✗ C1.2: Pods not all ready ({ready}/{desired})")
                s1_checks.append(False)
        else:
            print("✗ C1.2: Skipped (DaemonSet not found)")
            s1_checks.append(False)
    except Exception as e:
        print(f"✗ C1.2: Error: {e}")
        s1_checks.append(False)

    # C1.3: priorityClassName is system-node-critical
    try:
        if s1_checks[0]:
            priority = ds.get("spec", {}).get("template", {}).get("spec", {}).get("priorityClassName", "")
            if priority == "system-node-critical":
                print(f"✓ C1.3: priorityClassName = {priority}")
                s1_checks.append(True)
            else:
                print(f"✗ C1.3: priorityClassName = '{priority}' (expected system-node-critical)")
                s1_checks.append(False)
        else:
            print("✗ C1.3: Skipped (DaemonSet not found)")
            s1_checks.append(False)
    except Exception as e:
        print(f"✗ C1.3: Error: {e}")
        s1_checks.append(False)

    # C1.4: Enforcer CronJobs and Deployment deleted from platform-ops
    try:
        enforcers_found = []
        # Check enforcer Deployment
        _, rc = run_kubectl_command(
            "get", "deployment", "log-governance-controller",
            namespace="platform-ops", timeout=5
        )
        if rc == 0:
            enforcers_found.append("deployment/log-governance-controller")
        # Check enforcer CronJobs
        for cj in ["log-collector-reconciler", "logging-policy-enforcer", "node-taint-enforcer"]:
            _, rc = run_kubectl_command(
                "get", "cronjob", cj,
                namespace="platform-ops", timeout=5
            )
            if rc == 0:
                enforcers_found.append(f"cronjob/{cj}")

        if not enforcers_found:
            print("✓ C1.4: All enforcer CronJobs and Deployment deleted")
            s1_checks.append(True)
        else:
            print(f"✗ C1.4: Enforcers still present: {enforcers_found}")
            s1_checks.append(False)
    except Exception as e:
        print(f"✗ C1.4: Error: {e}")
        s1_checks.append(False)

    s1_pass = all(s1_checks) and len(s1_checks) == 4
    subscores["daemonset_running_stable"] = 1.0 if s1_pass else 0.0
    weights["daemonset_running_stable"] = WEIGHT
    print(f"→ SUBSCORE 1: {'PASS' if s1_pass else 'FAIL'} ({sum(s1_checks)}/4 checks)")

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 2: node_metadata_enrichment (0.20)
    # C2.1: Loki has logs with node_name label
    # C2.2: Loki has logs with kernel_version label
    # C2.3: Loki has logs with node_labels label (or specific node label)
    # C2.4: Enriched logs span at least 2 different namespaces
    # ═════════════════════════════════════════════════════════════════════════
    print("\n=== SUBSCORE 2: Node Metadata Enrichment ===")
    s2_checks = []

    # Wait a bit for log ingestion
    print("Waiting 30s for log ingestion before Loki checks...")
    time.sleep(30)

    # C2.1: node_name label exists
    try:
        results = query_loki('{node_name=~".+"}', limit=5)
        if results:
            sample_node = results[0].get("stream", {}).get("node_name", "")
            print(f"✓ C2.1: Loki has logs with node_name label (value: {sample_node})")
            s2_checks.append(True)
        else:
            print("✗ C2.1: No logs found with node_name label in Loki")
            s2_checks.append(False)
    except Exception as e:
        print(f"✗ C2.1: Error: {e}")
        s2_checks.append(False)

    # C2.2: kernel_version label exists
    try:
        results = query_loki('{kernel_version=~".+"}', limit=5)
        if results:
            sample_kernel = results[0].get("stream", {}).get("kernel_version", "")
            print(f"✓ C2.2: Loki has logs with kernel_version label (value: {sample_kernel})")
            s2_checks.append(True)
        else:
            print("✗ C2.2: No logs found with kernel_version label in Loki")
            s2_checks.append(False)
    except Exception as e:
        print(f"✗ C2.2: Error: {e}")
        s2_checks.append(False)

    # C2.3: node_labels label exists
    try:
        results = query_loki('{node_labels=~".+"}', limit=5)
        if results:
            sample_labels = results[0].get("stream", {}).get("node_labels", "")
            # Verify it's not empty or just a raw JSON blob with no actual content
            if len(sample_labels) > 5:
                print(f"✓ C2.3: Loki has logs with node_labels label (length: {len(sample_labels)})")
                s2_checks.append(True)
            else:
                print(f"✗ C2.3: node_labels label exists but too short: '{sample_labels}'")
                s2_checks.append(False)
        else:
            print("✗ C2.3: No logs found with node_labels label in Loki")
            s2_checks.append(False)
    except Exception as e:
        print(f"✗ C2.3: Error: {e}")
        s2_checks.append(False)

    # C2.4: Enriched logs span at least 2 namespaces
    try:
        results = query_loki('{node_name=~".+"}', limit=50)
        if results:
            namespaces = set()
            for r in results:
                stream = r.get("stream", {})
                ns = stream.get("namespace", "") or stream.get("kubernetes_namespace_name", "")
                if ns:
                    namespaces.add(ns)
            if len(namespaces) >= 2:
                print(f"✓ C2.4: Enriched logs span {len(namespaces)} namespaces: {namespaces}")
                s2_checks.append(True)
            else:
                print(f"✗ C2.4: Enriched logs only in {len(namespaces)} namespace(s): {namespaces} (need >= 2)")
                s2_checks.append(False)
        else:
            print("✗ C2.4: No enriched logs found to check namespace span")
            s2_checks.append(False)
    except Exception as e:
        print(f"✗ C2.4: Error: {e}")
        s2_checks.append(False)

    s2_pass = all(s2_checks) and len(s2_checks) == 4
    subscores["node_metadata_enrichment"] = 1.0 if s2_pass else 0.0
    weights["node_metadata_enrichment"] = WEIGHT
    print(f"→ SUBSCORE 2: {'PASS' if s2_pass else 'FAIL'} ({sum(s2_checks)}/4 checks)")

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 3: resource_controls (0.20)
    # C3.1: DaemonSet pod has cpu/memory requests set
    # C3.2: DaemonSet pod has cpu/memory limits set
    # C3.3: priorityClassName is system-node-critical (not decoy)
    # C3.4: No blocking ResourceQuota or LimitRange in monitoring namespace
    # ═════════════════════════════════════════════════════════════════════════
    print("\n=== SUBSCORE 3: Resource Controls ===")
    s3_checks = []

    # Re-read DaemonSet for fresh state
    ds_json = None
    try:
        stdout, rc = run_kubectl_command(
            "get", "daemonset", "fluent-bit", "-o", "json",
            namespace="monitoring", timeout=10
        )
        if rc == 0:
            ds_json = json.loads(stdout)
    except Exception:
        pass

    # C3.1: CPU/memory requests set
    try:
        if ds_json:
            containers = ds_json.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
            fb_container = None
            for c in containers:
                if c.get("name") == "fluent-bit":
                    fb_container = c
                    break
            if not fb_container and containers:
                fb_container = containers[0]

            if fb_container:
                resources = fb_container.get("resources", {})
                requests = resources.get("requests", {})
                has_cpu_req = "cpu" in requests
                has_mem_req = "memory" in requests

                if has_cpu_req and has_mem_req:
                    print(f"✓ C3.1: Requests set — cpu={requests['cpu']}, memory={requests['memory']}")
                    s3_checks.append(True)
                else:
                    print(f"✗ C3.1: Missing requests — cpu={has_cpu_req}, memory={has_mem_req}")
                    s3_checks.append(False)
            else:
                print("✗ C3.1: No fluent-bit container found")
                s3_checks.append(False)
        else:
            print("✗ C3.1: DaemonSet not found in monitoring")
            s3_checks.append(False)
    except Exception as e:
        print(f"✗ C3.1: Error: {e}")
        s3_checks.append(False)

    # C3.2: CPU/memory limits set
    try:
        if ds_json and fb_container:
            limits = fb_container.get("resources", {}).get("limits", {})
            has_cpu_lim = "cpu" in limits
            has_mem_lim = "memory" in limits

            if has_cpu_lim and has_mem_lim:
                print(f"✓ C3.2: Limits set — cpu={limits['cpu']}, memory={limits['memory']}")
                s3_checks.append(True)
            else:
                print(f"✗ C3.2: Missing limits — cpu={has_cpu_lim}, memory={has_mem_lim}")
                s3_checks.append(False)
        else:
            print("✗ C3.2: DaemonSet not found or no container")
            s3_checks.append(False)
    except Exception as e:
        print(f"✗ C3.2: Error: {e}")
        s3_checks.append(False)

    # C3.3: priorityClassName is system-node-critical (not the decoy)
    try:
        if ds_json:
            priority = ds_json.get("spec", {}).get("template", {}).get("spec", {}).get("priorityClassName", "")
            if priority == "system-node-critical":
                print(f"✓ C3.3: priorityClassName = system-node-critical")
                s3_checks.append(True)
            elif priority == "log-collector-priority":
                print(f"✗ C3.3: Using decoy PriorityClass '{priority}' (value=100, useless)")
                s3_checks.append(False)
            else:
                print(f"✗ C3.3: priorityClassName = '{priority}' (expected system-node-critical)")
                s3_checks.append(False)
        else:
            print("✗ C3.3: DaemonSet not found")
            s3_checks.append(False)
    except Exception as e:
        print(f"✗ C3.3: Error: {e}")
        s3_checks.append(False)

    # C3.4: No blocking ResourceQuota or LimitRange in monitoring
    try:
        blocking = False

        # Check ResourceQuota
        stdout, rc = run_kubectl_command(
            "get", "resourcequota", "-o", "json",
            namespace="monitoring", timeout=10
        )
        if rc == 0:
            rq_list = json.loads(stdout)
            for rq in rq_list.get("items", []):
                rq_name = rq.get("metadata", {}).get("name", "")
                hard = rq.get("spec", {}).get("hard", {})
                # Check if quota is too restrictive for Fluent Bit
                cpu_limit = hard.get("limits.cpu", "")
                if cpu_limit:
                    if cpu_limit.endswith("m"):
                        cpu_val = int(cpu_limit[:-1])
                    else:
                        cpu_val = int(float(cpu_limit) * 1000)
                    if cpu_val < 500:
                        blocking = True
                        print(f"  ✗ ResourceQuota '{rq_name}' blocks: limits.cpu={cpu_limit}")

        # Check LimitRange
        stdout, rc = run_kubectl_command(
            "get", "limitrange", "-o", "json",
            namespace="monitoring", timeout=10
        )
        if rc == 0:
            lr_list = json.loads(stdout)
            for lr in lr_list.get("items", []):
                lr_name = lr.get("metadata", {}).get("name", "")
                for limit in lr.get("spec", {}).get("limits", []):
                    if limit.get("type") == "Container":
                        max_cpu = limit.get("max", {}).get("cpu", "")
                        if max_cpu:
                            if max_cpu.endswith("m"):
                                max_val = int(max_cpu[:-1])
                            else:
                                max_val = int(float(max_cpu) * 1000)
                            if max_val < 500:
                                blocking = True
                                print(f"  ✗ LimitRange '{lr_name}' blocks: max.cpu={max_cpu}")

        if not blocking:
            print("✓ C3.4: No blocking ResourceQuota or LimitRange in monitoring")
            s3_checks.append(True)
        else:
            s3_checks.append(False)
    except Exception as e:
        print(f"✗ C3.4: Error: {e}")
        s3_checks.append(False)

    s3_pass = all(s3_checks) and len(s3_checks) == 4
    subscores["resource_controls"] = 1.0 if s3_pass else 0.0
    weights["resource_controls"] = WEIGHT
    print(f"→ SUBSCORE 3: {'PASS' if s3_pass else 'FAIL'} ({sum(s3_checks)}/4 checks)")

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 4: prometheus_metrics (0.20)
    # C4.1: ServiceMonitor exists in monitoring targeting fluent-bit
    # C4.2: Prometheus up{} query for fluent-bit returns 1
    # C4.3: Fluent Bit pod exposes metrics on port 2020
    # C4.4: fluentbit_input_records_total metric exists in Prometheus
    # ═════════════════════════════════════════════════════════════════════════
    print("\n=== SUBSCORE 4: Prometheus Metrics ===")
    s4_checks = []

    # C4.1: ServiceMonitor exists with correct selector
    try:
        stdout, rc = run_kubectl_command(
            "get", "servicemonitor", "fluent-bit-metrics", "-o", "json",
            namespace="monitoring", timeout=10
        )
        if rc == 0:
            sm = json.loads(stdout)
            selector = sm.get("spec", {}).get("selector", {}).get("matchLabels", {})
            ns_selector = sm.get("spec", {}).get("namespaceSelector", {}).get("matchNames", [])

            # Check selector points to monitoring namespace and app=fluent-bit
            correct_label = selector.get("app") == "fluent-bit"
            correct_ns = "monitoring" in ns_selector

            if correct_label and correct_ns:
                print("✓ C4.1: ServiceMonitor exists with correct selector (app=fluent-bit, ns=monitoring)")
                s4_checks.append(True)
            else:
                print(f"✗ C4.1: ServiceMonitor has wrong selector: labels={selector}, namespaces={ns_selector}")
                s4_checks.append(False)
        else:
            print("✗ C4.1: ServiceMonitor fluent-bit-metrics not found in monitoring")
            s4_checks.append(False)
    except Exception as e:
        print(f"✗ C4.1: Error: {e}")
        s4_checks.append(False)

    # C4.2: Prometheus scrape target is UP
    try:
        results = check_prometheus_metric('up{app="fluent-bit"}')
        if not results:
            # Fallback: check by job name pattern
            results = check_prometheus_metric('up{job=~".*fluent.*"}')
        if results:
            up_value = results[0].get("value", [None, "0"])[1]
            if up_value == "1":
                print("✓ C4.2: Prometheus fluent-bit target is UP")
                s4_checks.append(True)
            else:
                print(f"✗ C4.2: Prometheus fluent-bit target value = {up_value} (expected 1)")
                s4_checks.append(False)
        else:
            print("✗ C4.2: No Prometheus target found matching fluent-bit")
            s4_checks.append(False)
    except Exception as e:
        print(f"✗ C4.2: Error: {e}")
        s4_checks.append(False)

    # C4.3: Fluent Bit pod exposes metrics on port 2020
    try:
        # Get pod IP to check metrics endpoint (fluent-bit container has no shell)
        stdout, rc = run_kubectl_command(
            "get", "pods", "-l", "app=fluent-bit",
            "-o", "jsonpath={.items[0].status.podIP}",
            namespace="monitoring", timeout=10
        )
        if rc == 0 and stdout:
            pod_ip = stdout.strip()
            try:
                url = f"http://{pod_ip}:2020/api/v1/metrics/prometheus"
                req = urllib.request.Request(url, method="GET")
                with urllib.request.urlopen(req, timeout=10) as resp:
                    metrics_text = resp.read().decode()[:500]
                    if "fluentbit" in metrics_text or "# HELP" in metrics_text:
                        print("✓ C4.3: Fluent Bit metrics endpoint responding on port 2020")
                        s4_checks.append(True)
                    else:
                        print("✗ C4.3: Fluent Bit metrics endpoint returned unexpected content")
                        s4_checks.append(False)
            except Exception:
                print("✗ C4.3: Fluent Bit metrics endpoint not responding on port 2020")
                s4_checks.append(False)
        else:
            print("✗ C4.3: No fluent-bit pod found in monitoring")
            s4_checks.append(False)
    except Exception as e:
        print(f"✗ C4.3: Error: {e}")
        s4_checks.append(False)

    # C4.4: fluentbit_input_records_total metric exists
    try:
        results = check_prometheus_metric("fluentbit_input_records_total")
        if results:
            print(f"✓ C4.4: fluentbit_input_records_total metric found ({len(results)} series)")
            s4_checks.append(True)
        else:
            # Check if metric drop rule is still in place
            results2 = check_prometheus_metric("fluentbit_output_proc_records_total")
            if results2:
                print("✓ C4.4: fluentbit metrics found (output_proc_records_total)")
                s4_checks.append(True)
            else:
                print("✗ C4.4: No fluentbit_* metrics found in Prometheus")
                # Check if the drop rule secret still exists
                _, rc = run_kubectl_command(
                    "get", "secret", "prometheus-additional-scrape-configs",
                    namespace="monitoring", timeout=5
                )
                if rc == 0:
                    print("  (prometheus-additional-scrape-configs secret still exists — may contain drop rule)")
                s4_checks.append(False)
    except Exception as e:
        print(f"✗ C4.4: Error: {e}")
        s4_checks.append(False)

    s4_pass = all(s4_checks) and len(s4_checks) == 4
    subscores["prometheus_metrics"] = 1.0 if s4_pass else 0.0
    weights["prometheus_metrics"] = WEIGHT
    print(f"→ SUBSCORE 4: {'PASS' if s4_pass else 'FAIL'} ({sum(s4_checks)}/4 checks)")

    # ═════════════════════════════════════════════════════════════════════════
    # SUBSCORE 5: gitops_integration (0.20)
    # C5.1: ArgoCD Application 'fluent-bit' exists with correct repoURL
    # C5.2: ArgoCD repo Secret exists with correct credentials
    # C5.3: ArgoCD source path points to charts/fluent-bit (not legacy)
    #        AND destination namespace is monitoring
    # C5.4: ArgoCD Application has automated.selfHeal: true
    # ═════════════════════════════════════════════════════════════════════════
    print("\n=== SUBSCORE 5: GitOps Integration ===")
    s5_checks = []

    # Read ArgoCD Application
    argo_app = None
    try:
        stdout, rc = run_kubectl_command(
            "get", "application", "fluent-bit", "-o", "json",
            namespace="argocd", timeout=10
        )
        if rc == 0:
            argo_app = json.loads(stdout)
    except Exception:
        pass

    # C5.1: Application exists with correct repoURL pointing to platform-logging
    try:
        if argo_app:
            repo_url = argo_app.get("spec", {}).get("source", {}).get("repoURL", "")
            if "platform-logging" in repo_url and "gitea" in repo_url:
                print(f"✓ C5.1: ArgoCD Application exists with correct repoURL: {repo_url}")
                s5_checks.append(True)
            else:
                print(f"✗ C5.1: ArgoCD Application repoURL = '{repo_url}' (expected platform-logging on Gitea)")
                s5_checks.append(False)
        else:
            print("✗ C5.1: ArgoCD Application fluent-bit not found in argocd namespace")
            s5_checks.append(False)
    except Exception as e:
        print(f"✗ C5.1: Error: {e}")
        s5_checks.append(False)

    # C5.2: ArgoCD repo Secret exists with correct type and URL
    try:
        stdout, rc = run_kubectl_command(
            "get", "secret", "-l", "argocd.argoproj.io/secret-type=repository",
            "-o", "json", namespace="argocd", timeout=10
        )
        if rc == 0:
            secrets = json.loads(stdout)
            found_valid = False
            for secret in secrets.get("items", []):
                data = secret.get("data", {})
                string_data = secret.get("stringData", {})
                # Check decoded data
                import base64
                secret_url = ""
                secret_type = ""
                try:
                    if "url" in data:
                        secret_url = base64.b64decode(data["url"]).decode()
                    if "type" in data:
                        secret_type = base64.b64decode(data["type"]).decode()
                except Exception:
                    pass
                if "platform-logging" in secret_url and secret_type == "git":
                    found_valid = True
                    print(f"✓ C5.2: ArgoCD repo Secret found with url={secret_url}, type={secret_type}")
                    break
            if found_valid:
                s5_checks.append(True)
            else:
                print("✗ C5.2: No ArgoCD repo Secret found with platform-logging URL and type=git")
                s5_checks.append(False)
        else:
            print("✗ C5.2: Could not list ArgoCD repo Secrets")
            s5_checks.append(False)
    except Exception as e:
        print(f"✗ C5.2: Error: {e}")
        s5_checks.append(False)

    # C5.3: Source path and destination namespace are correct
    try:
        if argo_app:
            source_path = argo_app.get("spec", {}).get("source", {}).get("path", "")
            dest_ns = argo_app.get("spec", {}).get("destination", {}).get("namespace", "")

            path_ok = source_path == "charts/fluent-bit"
            ns_ok = dest_ns == "monitoring"

            if path_ok and ns_ok:
                print(f"✓ C5.3: Source path={source_path}, destination namespace={dest_ns}")
                s5_checks.append(True)
            else:
                if not path_ok:
                    print(f"✗ C5.3: Source path = '{source_path}' (expected charts/fluent-bit)")
                if not ns_ok:
                    print(f"✗ C5.3: Destination namespace = '{dest_ns}' (expected monitoring)")
                s5_checks.append(False)
        else:
            print("✗ C5.3: ArgoCD Application not found")
            s5_checks.append(False)
    except Exception as e:
        print(f"✗ C5.3: Error: {e}")
        s5_checks.append(False)

    # C5.4: selfHeal enabled
    try:
        if argo_app:
            sync_policy = argo_app.get("spec", {}).get("syncPolicy", {})
            automated = sync_policy.get("automated", {})
            self_heal = automated.get("selfHeal", False)

            if self_heal:
                print(f"✓ C5.4: selfHeal is enabled")
                s5_checks.append(True)
            else:
                print(f"✗ C5.4: selfHeal is not enabled (syncPolicy.automated.selfHeal={self_heal})")
                s5_checks.append(False)
        else:
            print("✗ C5.4: ArgoCD Application not found")
            s5_checks.append(False)
    except Exception as e:
        print(f"✗ C5.4: Error: {e}")
        s5_checks.append(False)

    s5_pass = all(s5_checks) and len(s5_checks) == 4
    subscores["gitops_integration"] = 1.0 if s5_pass else 0.0
    weights["gitops_integration"] = WEIGHT
    print(f"→ SUBSCORE 5: {'PASS' if s5_pass else 'FAIL'} ({sum(s5_checks)}/4 checks)")

    # ═════════════════════════════════════════════════════════════════════════
    # Final score calculation
    # ═════════════════════════════════════════════════════════════════════════
    total_weight = sum(weights.values())
    total_score = sum(
        subscores[k] * weights[k] for k in subscores
    ) / total_weight if total_weight > 0 else 0.0

    # ── Build feedback ──────────────────────────────────────────────────────
    feedback_lines = []

    checks = [
        ("daemonset_running_stable",
         "DaemonSet fluent-bit running in monitoring with system-node-critical priority, enforcers neutralized",
         "DaemonSet not properly deployed, wrong namespace, wrong type, or enforcers still active"),
        ("node_metadata_enrichment",
         "Loki logs enriched with node_name, kernel_version, and node_labels from multiple namespaces",
         "Node metadata missing from Loki logs — check Lua filter, RBAC, and Loki label limits"),
        ("resource_controls",
         "Proper resource requests/limits, system-node-critical priority, no blocking quota/limitrange",
         "Resource controls misconfigured — blocking ResourceQuota/LimitRange, wrong PriorityClass, or missing limits"),
        ("prometheus_metrics",
         "Prometheus scraping Fluent Bit metrics via ServiceMonitor, fluentbit_* metrics available",
         "Prometheus cannot scrape Fluent Bit — check ServiceMonitor selector, HTTP_Server, NetworkPolicy, and relabel rules"),
        ("gitops_integration",
         "ArgoCD Application configured correctly with repo credentials, correct source path, destination, and selfHeal",
         "GitOps not configured — check ArgoCD Application path, repo secret credentials, destination namespace, and sync policy"),
    ]

    for key, pass_msg, fail_msg in checks:
        if subscores.get(key, 0) >= 1.0:
            feedback_lines.append(f"✅ {pass_msg}")
        else:
            feedback_lines.append(f"❌ {fail_msg}")

    feedback = "\n".join(feedback_lines)

    print(f"\n=== FINAL SCORE: {round(total_score, 3)} ===")
    for k, v in subscores.items():
        print(f"  {k}: {v}")

    return GradingResult(
        score=round(total_score, 3),
        subscores=subscores,
        weights=weights,
        feedback=feedback
    )
