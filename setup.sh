#!/bin/bash
set -e

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

ELAPSED=0
MAX_WAIT=180

until kubectl cluster-info >/dev/null 2>&1; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "Error: k3s is not ready after ${MAX_WAIT} seconds"
        exit 1
    fi
    echo "Waiting for k3s... (${ELAPSED}s elapsed)"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo "k3s is ready!"

NS="bleater"
MON_NS="monitoring"
LOG_NS="logging"
OPS_NS="platform-ops"
OBS_NS="observability"

echo "=== Setting up Fluent Bit DaemonSet Log Enrichment Scenario (Hard Mode) ==="
echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 0: WAIT FOR INFRASTRUCTURE
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 0: Waiting for bleater namespace and core services..."

ELAPSED=0
MAX_WAIT=300
until kubectl get namespace "$NS" &> /dev/null; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "Error: bleater namespace not ready after ${MAX_WAIT}s"
        exit 1
    fi
    echo "Waiting for bleater namespace... (${ELAPSED}s elapsed)"
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done
echo "  bleater namespace exists"

# Wait for at least one bleater deployment to be available
kubectl wait --for=condition=available deployment -l app.kubernetes.io/part-of=bleater \
    -n "$NS" --timeout=300s 2>/dev/null || \
    echo "  Note: some bleater services may still be starting"
echo "  Bleater services ready"
echo ""

# ── Free up node CPU by scaling down non-essential workloads ─────────────
echo "Scaling down non-essential workloads to free resources..."

kubectl scale deployment oncall-celery oncall-engine \
    postgres-exporter redis-exporter \
    bleater-minio bleater-profile-service \
    bleater-storage-service \
    bleater-like-service \
    -n "$NS" --replicas=0 2>/dev/null || true

sleep 15

# Wait for k3s API server to stabilize
echo "  Waiting for API server to stabilize..."
ELAPSED=0
until kubectl get --raw /readyz &> /dev/null && kubectl api-resources &> /dev/null; do
    if [ $ELAPSED -ge 180 ]; then
        echo "Error: k3s API server not responding after scale-down"
        exit 1
    fi
    echo "    API server not ready yet... (${ELAPSED}s)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done
sleep 20
echo "  API server stabilized"
echo "  Non-essential workloads scaled down"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 1: CREATE NAMESPACES AND PREREQUISITES
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 1: Creating namespaces and prerequisites..."

# Create namespaces (create if they don't exist)
for NS_CREATE in "$LOG_NS" "$OPS_NS" "$MON_NS" "$OBS_NS" "cert-manager" "argocd"; do
    kubectl get namespace "$NS_CREATE" &>/dev/null || kubectl create namespace "$NS_CREATE" 2>/dev/null || true
done

kubectl label namespace "$LOG_NS" purpose=legacy-logging app.kubernetes.io/managed-by=platform-ops --overwrite 2>/dev/null || true
kubectl label namespace "$OPS_NS" app.kubernetes.io/managed-by=platform-ops purpose=operations --overwrite 2>/dev/null || true

echo "  Namespaces ready: $LOG_NS, $OPS_NS, $MON_NS, $OBS_NS, cert-manager, argocd"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 2: SUBSCORE 1 BREAKAGES — DaemonSet Running & Stable
# B1: Fluent Bit as Deployment in wrong namespace (logging)
# B2: Node taint blocking DaemonSet scheduling
# B3: Static pod enforcer re-creating Deployment
# B4: CronJob deleting DaemonSet and re-creating Deployment
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 2: Subscore 1 breakages — DaemonSet deployment..."
echo ""

# ── B1: Deploy Fluent Bit as a Deployment in the WRONG namespace (logging) ──
echo "  B1: Creating Fluent Bit Deployment in 'logging' namespace..."

# Create a service account for fluent-bit in logging namespace
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: $LOG_NS
  labels:
    app: fluent-bit
    app.kubernetes.io/name: fluent-bit
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: $LOG_NS
  labels:
    app: fluent-bit
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush        5
        Daemon       Off
        Log_Level    info
        HTTP_Server  Off
        Parsers_File parsers.conf

    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            docker
        Tag               kube.*
        Refresh_Interval  10
        Skip_Long_Lines   On
        DB                /var/log/flb_kube.db

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    [OUTPUT]
        Name              loki
        Match             kube.*
        Host              loki.monitoring.svc.cluster.local
        Port              3100
        Labels            job=fluent-bit
        LineFormat        json

  parsers.conf: |
    [PARSER]
        Name        docker
        Format      json
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L
        Time_Keep   On
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fluent-bit
  namespace: $LOG_NS
  labels:
    app: fluent-bit
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/component: logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
        app.kubernetes.io/name: fluent-bit
    spec:
      serviceAccountName: fluent-bit
      containers:
      - name: fluent-bit
        image: fluent/fluent-bit:2.1
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - name: config
          mountPath: /fluent-bit/etc/
        - name: varlog
          mountPath: /var/log
          readOnly: true
      volumes:
      - name: config
        configMap:
          name: fluent-bit-config
      - name: varlog
        hostPath:
          path: /var/log
EOF
echo "    Fluent Bit Deployment created in $LOG_NS"

# ── B2: Add node taint to block DaemonSet scheduling ──
echo "  B2: Adding node taint to block DaemonSet pods..."

NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint node "$NODE_NAME" node-role.kubernetes.io/log-collector=true:NoSchedule --overwrite 2>/dev/null || true
echo "    Taint added: node-role.kubernetes.io/log-collector=true:NoSchedule"

# ── B3: Deployment-based enforcer that re-creates the Deployment ──
echo "  B3: Creating enforcer Deployment in platform-ops..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: log-governance-manifest
  namespace: $OPS_NS
data:
  deployment.yaml: |
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: fluent-bit
      namespace: logging
      labels:
        app: fluent-bit
        app.kubernetes.io/name: fluent-bit
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: fluent-bit
      template:
        metadata:
          labels:
            app: fluent-bit
            app.kubernetes.io/name: fluent-bit
        spec:
          serviceAccountName: fluent-bit
          containers:
          - name: fluent-bit
            image: fluent/fluent-bit:2.1
            imagePullPolicy: IfNotPresent
            volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/
            - name: varlog
              mountPath: /var/log
              readOnly: true
          volumes:
          - name: config
            configMap:
              name: fluent-bit-config
          - name: varlog
            hostPath:
              path: /var/log
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: log-governance-controller
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    purpose: resource-governance
    component: log-governance
spec:
  replicas: 1
  selector:
    matchLabels:
      app: log-governance-controller
  template:
    metadata:
      labels:
        app: log-governance-controller
        component: log-governance
    spec:
      serviceAccountName: log-reconciler-sa
      containers:
      - name: controller
        image: bitnami/kubectl:latest
        imagePullPolicy: IfNotPresent
        command:
        - /bin/sh
        - -c
        - |
          while true; do
            # If a DaemonSet named fluent-bit exists in monitoring, delete it
            if kubectl get daemonset fluent-bit -n monitoring 2>/dev/null; then
              echo "Non-compliant DaemonSet found — removing"
              kubectl delete daemonset fluent-bit -n monitoring --grace-period=0 2>/dev/null
            fi
            # Ensure the Deployment exists in logging
            if ! kubectl get deployment fluent-bit -n logging 2>/dev/null; then
              echo "Fluent Bit Deployment missing — recreating"
              kubectl apply -f /manifests/deployment.yaml 2>/dev/null
            fi
            sleep 60
          done
        volumeMounts:
        - name: manifest
          mountPath: /manifests
      volumes:
      - name: manifest
        configMap:
          name: log-governance-manifest
EOF
echo "    Enforcer Deployment log-governance-controller created in $OPS_NS"

# ── B4: CronJob that deletes DaemonSet and re-creates Deployment ──
echo "  B4: Creating CronJob enforcer in platform-ops..."

# Create ConfigMap with the enforcer script
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: log-collector-reconciler-script
  namespace: $OPS_NS
data:
  reconcile.sh: |
    #!/bin/sh
    # Ensure fluent-bit runs as Deployment in logging namespace (platform standard)
    if kubectl get daemonset fluent-bit -n monitoring 2>/dev/null; then
      echo "Non-compliant DaemonSet found in monitoring — removing"
      kubectl delete daemonset fluent-bit -n monitoring --grace-period=0 2>/dev/null
    fi
    if ! kubectl get deployment fluent-bit -n logging 2>/dev/null; then
      echo "Fluent Bit Deployment missing in logging — recreating"
      kubectl apply -f /scripts/deployment.yaml 2>/dev/null
    fi
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: log-collector-deployment-manifest
  namespace: $OPS_NS
data:
  deployment.yaml: |
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: fluent-bit
      namespace: logging
      labels:
        app: fluent-bit
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: fluent-bit
      template:
        metadata:
          labels:
            app: fluent-bit
        spec:
          serviceAccountName: fluent-bit
          containers:
          - name: fluent-bit
            image: fluent/fluent-bit:2.1
        imagePullPolicy: IfNotPresent
            volumeMounts:
            - name: config
              mountPath: /fluent-bit/etc/
            - name: varlog
              mountPath: /var/log
              readOnly: true
          volumes:
          - name: config
            configMap:
              name: fluent-bit-config
          - name: varlog
            hostPath:
              path: /var/log
EOF

# Create ServiceAccount and RBAC for the CronJob
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: log-reconciler-sa
  namespace: $OPS_NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: log-reconciler-role
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "daemonsets"]
  verbs: ["get", "list", "create", "delete", "patch"]
- apiGroups: [""]
  resources: ["configmaps", "serviceaccounts"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: log-reconciler-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: log-reconciler-role
subjects:
- kind: ServiceAccount
  name: log-reconciler-sa
  namespace: $OPS_NS
EOF

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: log-collector-reconciler
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    purpose: resource-governance
spec:
  schedule: "* * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 50
      template:
        spec:
          serviceAccountName: log-reconciler-sa
          containers:
          - name: reconciler
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/reconcile.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts/reconcile.sh
              subPath: reconcile.sh
            - name: manifest
              mountPath: /scripts/deployment.yaml
              subPath: deployment.yaml
          volumes:
          - name: script
            configMap:
              name: log-collector-reconciler-script
          - name: manifest
            configMap:
              name: log-collector-deployment-manifest
          restartPolicy: Never
EOF
echo "    CronJob log-collector-reconciler created in $OPS_NS"

echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 3: SUBSCORE 2 BREAKAGES — Node Metadata Enrichment
# B5: No Lua filter in Fluent Bit config for node enrichment
# B6: ClusterRoleBinding for node read access deleted
# B7: Decoy ConfigMap with broken Lua script
# B8: Loki max_label_names_per_series too low
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 3: Subscore 2 breakages — Node metadata enrichment..."
echo ""

# ── B5: Fluent Bit config has NO Lua filter (already done via B1 ConfigMap above) ──
echo "  B5: Fluent Bit config has no Lua filter for node enrichment (set in B1)"

# ── B6: Delete ClusterRoleBinding for fluent-bit to read Node objects ──
echo "  B6: Removing RBAC for node metadata access..."

# First create the ClusterRole (so there's something to find) but delete the binding
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluent-bit-node-reader
  labels:
    app: fluent-bit
rules:
- apiGroups: [""]
  resources: ["namespaces", "pods"]
  verbs: ["get", "list", "watch"]
EOF
# Intentionally NOT binding it — and NOT including "nodes" in the resources
# The agent must create both a ClusterRole with nodes AND a ClusterRoleBinding
echo "    ClusterRole fluent-bit-node-reader exists but is missing 'nodes' resource and has no binding"

# ── B7: Decoy ConfigMap with broken Lua script in cert-manager (obscure namespace) ──
echo "  B7: Creating decoy enrichment ConfigMap..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-node-enrichment
  namespace: cert-manager
  labels:
    app: fluent-bit
    component: node-enrichment
    app.kubernetes.io/managed-by: platform-ops
  annotations:
    description: "Enrichment module for log agent node-level metadata"
    maintainer: "platform-engineering@bleater.io"
data:
  node-enrichment.lua: |
    -- Node metadata enrichment filter for Fluent Bit
    -- Queries Kubernetes API for node-level metadata and injects into log records
    -- Version: 2.1.3 (updated for k3s compatibility)

    local http = require("socket.http")
    local json = require("cjson")

    -- Cache node metadata to avoid excessive API calls
    local node_cache = {}
    local cache_ttl = 300  -- 5 minutes

    function enrich_with_node_metadata(tag, timestamp, record)
        local node_name = record["kubernetes"]["host"]
        if node_name == nil then
            return 0, 0, 0
        end

        -- Check cache
        if node_cache[node_name] and (os.time() - node_cache[node_name].ts) < cache_ttl then
            local cached = node_cache[node_name]
            record["node_name"] = cached.name
            record["kernel_version"] = cached.kernel
            record["node_labels"] = cached.labels
            return 1, timestamp, record
        end

        -- Query Kubernetes API for node info
        local sa_token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        local f = io.open(sa_token_file, "r")
        if f == nil then
            return 0, 0, 0
        end
        local token = f:read("*all")
        f:close()

        local api_url = "https://kubernetes.default.svc/api/v1/nodes/" .. node_name
        local body, code = http.request{
            url = api_url,
            headers = {
                ["Authorization"] = "Bearer " .. token,
            }
        }

        if code == 200 and body then
            local node_info = json.decode(body)
            -- BUG: Uses osImage instead of kernelVersion
            local kernel = node_info["status"]["nodeInfo"]["osImage"]
            -- BUG: Dumps raw JSON instead of flattened key=value pairs
            local labels = json.encode(node_info["metadata"]["labels"])

            record["node_name"] = node_name
            record["kernel_version"] = kernel
            record["node_labels"] = labels

            node_cache[node_name] = {
                name = node_name,
                kernel = kernel,
                labels = labels,
                ts = os.time()
            }

            return 1, timestamp, record
        end

        return 0, 0, 0
    end
EOF
echo "    Decoy ConfigMap fluent-bit-node-enrichment created in cert-manager (has bugs)"

# ── B8: Set Loki max_label_names_per_series too low ──
echo "  B8: Restricting Loki label limits..."

# Find the Loki ConfigMap or create an override
LOKI_NS=$(kubectl get pods -A -l app=loki -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "monitoring")
LOKI_CM=$(kubectl get configmap -n "$LOKI_NS" -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$LOKI_CM" ]; then
    # Patch existing Loki config to add restrictive limits
    LOKI_CONFIG=$(kubectl get configmap "$LOKI_CM" -n "$LOKI_NS" -o jsonpath='{.data.loki\.yaml}' 2>/dev/null || \
                  kubectl get configmap "$LOKI_CM" -n "$LOKI_NS" -o jsonpath='{.data.config\.yaml}' 2>/dev/null)

    if [ -n "$LOKI_CONFIG" ]; then
        # Add limits_config with low max_label_names_per_series
        MODIFIED_CONFIG=$(echo "$LOKI_CONFIG" | python3 -c "
import sys, yaml

config = yaml.safe_load(sys.stdin.read())
if config is None:
    config = {}
if 'limits_config' not in config:
    config['limits_config'] = {}
config['limits_config']['max_label_names_per_series'] = 8
config['limits_config']['max_label_value_length'] = 1024
print(yaml.dump(config, default_flow_style=False))
" 2>/dev/null)

        if [ -n "$MODIFIED_CONFIG" ]; then
            # Determine the correct data key
            DATA_KEY="loki.yaml"
            kubectl get configmap "$LOKI_CM" -n "$LOKI_NS" -o jsonpath='{.data.config\.yaml}' &>/dev/null && DATA_KEY="config.yaml"

            kubectl create configmap "$LOKI_CM" -n "$LOKI_NS" \
                --from-literal="$DATA_KEY=$MODIFIED_CONFIG" \
                --dry-run=client -o yaml | kubectl apply -f -
            echo "    Loki max_label_names_per_series set to 8 (too low for enriched streams)"

            # Restart Loki to pick up config
            kubectl rollout restart statefulset loki -n "$LOKI_NS" 2>/dev/null || \
                kubectl rollout restart deployment loki -n "$LOKI_NS" 2>/dev/null || true
        fi
    fi
else
    echo "    Note: Loki ConfigMap not found — creating override"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-limits-override
  namespace: $MON_NS
  labels:
    app: loki
    component: config-override
data:
  limits.yaml: |
    limits_config:
      max_label_names_per_series: 8
      max_label_value_length: 1024
      reject_old_samples: true
      reject_old_samples_max_age: 168h
EOF
    echo "    Loki limits override ConfigMap created"
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 4: SUBSCORE 3 BREAKAGES — Resource Controls & Scheduling
# B9: ResourceQuota in monitoring namespace blocking pod creation
# B10: LimitRange in monitoring with very low max CPU/memory
# B11: Decoy PriorityClass + misleading ConfigMap
# B12: CronJob re-applying ResourceQuota and LimitRange
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 4: Subscore 3 breakages — Resource controls..."
echo ""

# ── B9: ResourceQuota blocking pod creation in monitoring ──
echo "  B9: Creating restrictive ResourceQuota in monitoring..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: logging-resource-quota
  namespace: $MON_NS
  labels:
    app.kubernetes.io/managed-by: platform-governance
    purpose: resource-control
  annotations:
    policy: "Restrict logging agent resource consumption to prevent starvation"
spec:
  hard:
    requests.cpu: "100m"
    requests.memory: "128Mi"
    limits.cpu: "200m"
    limits.memory: "256Mi"
EOF
echo "    ResourceQuota logging-resource-quota created (very restrictive)"

# ── B10: LimitRange with very low max CPU/memory ──
echo "  B10: Creating restrictive LimitRange in monitoring..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: log-agent-governance
  namespace: $MON_NS
  labels:
    app.kubernetes.io/managed-by: platform-governance
    purpose: resource-governance
  annotations:
    policy: "Prevent log collection agents from consuming excessive resources"
spec:
  limits:
  - type: Container
    max:
      cpu: "50m"
      memory: "64Mi"
    default:
      cpu: "25m"
      memory: "32Mi"
    defaultRequest:
      cpu: "10m"
      memory: "16Mi"
EOF
echo "    LimitRange log-agent-governance created (max cpu=50m, memory=64Mi)"

# ── B11: Decoy PriorityClass + misleading policy ConfigMap ──
echo "  B11: Creating decoy PriorityClass and policy ConfigMap..."

kubectl apply -f - <<EOF
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: log-collector-priority
  labels:
    app.kubernetes.io/managed-by: platform-ops
  annotations:
    description: "Priority class for all logging agents — platform standard"
globalDefault: false
value: 100
preemptionPolicy: Never
description: "Priority class for logging infrastructure agents"
EOF
echo "    Decoy PriorityClass log-collector-priority created (value=100, useless)"

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: resource-policy-guidelines
  namespace: $MON_NS
  labels:
    app.kubernetes.io/managed-by: platform-governance
    type: policy-document
  annotations:
    last-reviewed: "2026-02-15"
    approved-by: "platform-engineering-lead"
data:
  logging-agent-policy: |
    ## Logging Agent Resource Policy (v3.2)

    All logging agents deployed via the platform-ops pipeline MUST:
    1. Use an appropriate PriorityClass for their scheduling tier
    2. Respect the namespace resource quota limits
    3. Stay within LimitRange bounds set by the governance team
    4. Priority configuration should follow the platform's scheduling
       governance model — consult platform-ops for the approved class
    5. Be deployed via the designated ArgoCD Application — manual kubectl
       deployments are non-compliant and will be reverted by enforcement

    Violations will be flagged by the platform governance automation.
    Contact: platform-engineering@bleater.io

  resource-limits: |
    Recommended resource spec for log collection agents:
      requests:
        cpu: 10m
        memory: 16Mi
      limits:
        cpu: 50m
        memory: 64Mi
    These values are enforced by the namespace LimitRange.
EOF
echo "    Policy ConfigMap resource-policy-guidelines created (misleading)"

# ── B12: CronJob re-applying ResourceQuota and LimitRange ──
echo "  B12: Creating governance enforcer CronJob..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: governance-enforcer-script
  namespace: $OPS_NS
data:
  enforce.sh: |
    #!/bin/sh
    # Re-apply resource governance if removed
    cat <<'QUOTA' | kubectl apply -f -
    apiVersion: v1
    kind: ResourceQuota
    metadata:
      name: logging-resource-quota
      namespace: monitoring
      labels:
        app.kubernetes.io/managed-by: platform-governance
    spec:
      hard:
        requests.cpu: "100m"
        requests.memory: "128Mi"
        limits.cpu: "200m"
        limits.memory: "256Mi"
    QUOTA
    cat <<'LIMIT' | kubectl apply -f -
    apiVersion: v1
    kind: LimitRange
    metadata:
      name: log-agent-governance
      namespace: monitoring
      labels:
        app.kubernetes.io/managed-by: platform-governance
    spec:
      limits:
      - type: Container
        max:
          cpu: "50m"
          memory: "64Mi"
        default:
          cpu: "25m"
          memory: "32Mi"
        defaultRequest:
          cpu: "10m"
          memory: "16Mi"
    LIMIT
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: logging-policy-enforcer
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-governance
    purpose: resource-governance
spec:
  schedule: "* * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 50
      template:
        spec:
          serviceAccountName: log-reconciler-sa
          containers:
          - name: enforcer
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "/scripts/enforce.sh"]
            volumeMounts:
            - name: script
              mountPath: /scripts
          volumes:
          - name: script
            configMap:
              name: governance-enforcer-script
          restartPolicy: Never
EOF
echo "    CronJob logging-policy-enforcer created in $OPS_NS"

# Add a CronJob that re-applies the node taint
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: node-taint-enforcer
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-governance
    purpose: resource-governance
spec:
  schedule: "* * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      activeDeadlineSeconds: 50
      template:
        spec:
          serviceAccountName: log-reconciler-sa
          containers:
          - name: enforcer
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              NODE=\$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
              kubectl taint node \$NODE node-role.kubernetes.io/log-collector=true:NoSchedule --overwrite 2>/dev/null
          restartPolicy: Never
EOF
echo "    CronJob node-taint-enforcer created in $OPS_NS"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 5: SUBSCORE 4 BREAKAGES — Prometheus ServiceMonitor & Metrics
# B13: ServiceMonitor with wrong label selector and port
# B14: Fluent Bit HTTP_Server disabled (no metrics endpoint)
# B15: NetworkPolicy blocking Prometheus scrape on port 2020
# B16: Prometheus metric_relabel_configs dropping fluentbit_* metrics
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 5: Subscore 4 breakages — Prometheus metrics..."
echo ""

# Ensure ServiceMonitor CRD exists (install if kube-prometheus-stack not present)
if ! kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null; then
    echo "  ServiceMonitor CRD not found — installing..."
    kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.68.0/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml 2>/dev/null || \
    kubectl apply -f - <<'CRDEOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: servicemonitors.monitoring.coreos.com
spec:
  group: monitoring.coreos.com
  names:
    kind: ServiceMonitor
    listKind: ServiceMonitorList
    plural: servicemonitors
    singular: servicemonitor
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true
CRDEOF
    echo "  ServiceMonitor CRD installed"
    sleep 3
else
    echo "  ServiceMonitor CRD already available"
fi

# Ensure PrometheusRule CRD exists
if ! kubectl get crd prometheusrules.monitoring.coreos.com &>/dev/null; then
    echo "  PrometheusRule CRD not found — installing..."
    kubectl apply -f - <<'CRDEOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: prometheusrules.monitoring.coreos.com
spec:
  group: monitoring.coreos.com
  names:
    kind: PrometheusRule
    listKind: PrometheusRuleList
    plural: prometheusrules
    singular: prometheusrule
  scope: Namespaced
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true
CRDEOF
    echo "  PrometheusRule CRD installed"
    sleep 3
else
    echo "  PrometheusRule CRD already available"
fi

# ── B13: Broken ServiceMonitor with wrong selector ──
echo "  B13: Creating broken ServiceMonitor..."

kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: fluent-bit-metrics
  namespace: $MON_NS
  labels:
    app: fluent-bit
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
    - $LOG_NS
  selector:
    matchLabels:
      app: fluent-bit-legacy
      component: metrics-exporter
  endpoints:
  - port: metrics-legacy
    path: /metrics
    interval: 30s
EOF
echo "    ServiceMonitor fluent-bit-metrics created with wrong selectors"

# ── B14: HTTP_Server is already Off in the ConfigMap from B1 ──
echo "  B14: Fluent Bit HTTP_Server is Off (set in B1 ConfigMap)"

# ── B15: NetworkPolicy blocking Prometheus scrape port ──
echo "  B15: Creating NetworkPolicy blocking scrape port 2020..."

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: monitoring-scrape-policy
  namespace: $MON_NS
  labels:
    app.kubernetes.io/managed-by: platform-security
    policy-type: ingress-control
  annotations:
    description: "Allow Prometheus to scrape known monitoring targets only"
spec:
  podSelector:
    matchLabels:
      app: fluent-bit
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
    ports:
    - protocol: TCP
      port: 9090
    - protocol: TCP
      port: 3000
    - protocol: TCP
      port: 9093
EOF
echo "    NetworkPolicy monitoring-scrape-policy blocks port 2020"

# ── B16: Prometheus relabel config dropping fluentbit metrics ──
echo "  B16: Adding Prometheus metric relabel config to drop fluentbit metrics..."

# Find the Prometheus additional scrape config secret or create one
PROM_NS=$(kubectl get pods -A -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "monitoring")

# Create a PrometheusRule that looks important (decoy) and a secret with relabel config
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: fluent-bit-absent-alert
  namespace: $MON_NS
  labels:
    release: kube-prometheus-stack
    app: kube-prometheus-stack
spec:
  groups:
  - name: fluent-bit.rules
    rules:
    - alert: FluentBitMetricsAbsent
      expr: absent(fluentbit_input_records_total)
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "Fluent Bit metrics are not being collected"
        description: "The fluentbit_input_records_total metric is missing from Prometheus"
EOF

# Add metric_relabel_configs via additional scrape config
# This drops any metric starting with fluentbit_
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: prometheus-additional-scrape-configs
  namespace: $PROM_NS
  labels:
    app: kube-prometheus-stack
type: Opaque
stringData:
  additional-scrape-configs.yaml: |
    - job_name: 'fluent-bit-drop'
      metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'fluentbit_.*'
        action: drop
      kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
          - monitoring
      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        regex: fluent-bit
        action: keep
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port]
        regex: (.+)
        target_label: __address__
        replacement: \${1}:\${2}
        action: replace
        source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
EOF
echo "    Prometheus additional scrape config with metric drop rule created"

# Patch Prometheus to use the additional scrape config
kubectl patch prometheus -n "$PROM_NS" \
    $(kubectl get prometheus -n "$PROM_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) \
    --type=merge \
    -p '{"spec":{"additionalScrapeConfigs":{"name":"prometheus-additional-scrape-configs","key":"additional-scrape-configs.yaml"}}}' \
    2>/dev/null && echo "    Prometheus patched to use additional scrape configs" || \
    echo "    Note: Could not patch Prometheus CR directly"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 6: SUBSCORE 5 BREAKAGES — GitOps (Gitea + ArgoCD)
# B17: ArgoCD Application with wrong source path
# B18: ArgoCD repo Secret with wrong Gitea password
# B19: Gitea repo has old Deployment-based values
# B20: Decoy ArgoCD Application pointing to Promtail
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 6: Subscore 5 breakages — GitOps integration..."
echo ""

# Get Gitea credentials
GITEA_PASS=$(python3 -c "
import urllib.request, re
try:
    html = urllib.request.urlopen('http://passwords.devops.local', timeout=10).read().decode()
    m = re.search(r'<h3>Gitea</h3>.*?Password.*?class=\"value\">([^<]+)', html, re.DOTALL)
    print(m.group(1).strip() if m else 'password')
except: print('password')
" 2>/dev/null)
GITEA_API="http://gitea.gitea.svc.cluster.local:3000/api/v1"
GITEA_URL="http://gitea.gitea.svc.cluster.local:3000"

echo "  Setting up Gitea repos..."

# Create platform-logging repo in Gitea
curl -sf -u "root:${GITEA_PASS}" -X POST "${GITEA_API}/user/repos" \
    -H "Content-Type: application/json" \
    -d '{"name":"platform-logging","description":"Platform logging Helm values and ArgoCD manifests","auto_init":true,"default_branch":"main"}' \
    2>/dev/null && echo "    Gitea repo root/platform-logging created" || echo "    Gitea repo may already exist"

# Create the WRONG path with old Deployment values
# charts/logging-legacy/ — this is where ArgoCD will point (wrong)
LEGACY_VALUES=$(cat <<'HELMEOF'
# Legacy Fluent Bit configuration — Deployment mode
# DO NOT MODIFY — managed by platform-ops automation

replicaCount: 1

kind: Deployment

image:
  repository: fluent/fluent-bit
  tag: "2.1"

serviceAccount:
  create: true
  name: fluent-bit

config:
  service: |
    [SERVICE]
        Flush        5
        Daemon       Off
        Log_Level    info
        HTTP_Server  Off

  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Tag               kube.*

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On

  outputs: |
    [OUTPUT]
        Name              loki
        Match             kube.*
        Host              loki.monitoring.svc.cluster.local
        Port              3100

resources:
  limits: {}
  requests: {}

priorityClassName: ""

serviceMonitor:
  enabled: false
HELMEOF
)

curl -sf -u "root:${GITEA_PASS}" -X POST "${GITEA_API}/repos/root/platform-logging/contents/charts/logging-legacy/values.yaml" \
    -H "Content-Type: application/json" \
    -d "{\"content\":\"$(echo "$LEGACY_VALUES" | base64 -w0)\",\"message\":\"Add legacy logging config\"}" \
    2>/dev/null && echo "    charts/logging-legacy/values.yaml created (wrong path)" || true

# ── B19: Create the correct path but with old Deployment-based values ──
CORRECT_PATH_VALUES=$(cat <<'HELMEOF'
# Fluent Bit Helm values — managed by platform-ops
# Last updated: 2026-01-15

kind: Deployment

image:
  repository: fluent/fluent-bit
  tag: "2.1"

serviceAccount:
  create: true
  name: fluent-bit

config:
  service: |
    [SERVICE]
        Flush        5
        Daemon       Off
        Log_Level    info
        HTTP_Server  Off

  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Tag               kube.*

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On

  outputs: |
    [OUTPUT]
        Name              loki
        Match             kube.*
        Host              loki.monitoring.svc.cluster.local
        Port              3100

resources:
  requests:
    cpu: 10m
    memory: 16Mi
  limits:
    cpu: 50m
    memory: 64Mi

priorityClassName: ""

nodeSelector: {}
tolerations: []

serviceMonitor:
  enabled: false

luaScripts: {}
HELMEOF
)

curl -sf -u "root:${GITEA_PASS}" -X POST "${GITEA_API}/repos/root/platform-logging/contents/charts/fluent-bit/values.yaml" \
    -H "Content-Type: application/json" \
    -d "{\"content\":\"$(echo "$CORRECT_PATH_VALUES" | base64 -w0)\",\"message\":\"Add fluent-bit config\"}" \
    2>/dev/null && echo "    charts/fluent-bit/values.yaml created (has Deployment, not DaemonSet)" || true

# Also add a Chart.yaml
CHART_YAML=$(cat <<'CHARTEOF'
apiVersion: v2
name: fluent-bit
description: Fluent Bit log forwarder for Bleater platform
type: application
version: 0.1.0
appVersion: "2.1"
CHARTEOF
)

curl -sf -u "root:${GITEA_PASS}" -X POST "${GITEA_API}/repos/root/platform-logging/contents/charts/fluent-bit/Chart.yaml" \
    -H "Content-Type: application/json" \
    -d "{\"content\":\"$(echo "$CHART_YAML" | base64 -w0)\",\"message\":\"Add chart metadata\"}" \
    2>/dev/null || true

# Create a second decoy repo for the decoy ArgoCD Application
curl -sf -u "root:${GITEA_PASS}" -X POST "${GITEA_API}/user/repos" \
    -H "Content-Type: application/json" \
    -d '{"name":"observability-stack","description":"Observability stack configs (Promtail, Jaeger, etc)","auto_init":true,"default_branch":"main"}' \
    2>/dev/null || true

PROMTAIL_VALUES=$(cat <<'HELMEOF'
# Promtail configuration — the recommended log collection agent
# Migration from Fluent Bit to Promtail is in progress

config:
  clients:
    - url: http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push

  snippets:
    scrapeConfigs: |
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

tolerations:
  - operator: Exists
HELMEOF
)

curl -sf -u "root:${GITEA_PASS}" -X POST "${GITEA_API}/repos/root/observability-stack/contents/charts/promtail/values.yaml" \
    -H "Content-Type: application/json" \
    -d "{\"content\":\"$(echo "$PROMTAIL_VALUES" | base64 -w0)\",\"message\":\"Add promtail config\"}" \
    2>/dev/null || true

# Ensure ArgoCD Application CRD exists
if ! kubectl get crd applications.argoproj.io &>/dev/null; then
    echo "  ArgoCD Application CRD not found — installing..."
    kubectl apply -f - <<'CRDEOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: applications.argoproj.io
spec:
  group: argoproj.io
  names:
    kind: Application
    listKind: ApplicationList
    plural: applications
    singular: application
    shortNames:
    - app
    - apps
  scope: Namespaced
  versions:
  - name: v1alpha1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true
          status:
            type: object
            x-kubernetes-preserve-unknown-fields: true
CRDEOF
    echo "  ArgoCD Application CRD installed"
    sleep 3
else
    echo "  ArgoCD Application CRD already available"
fi

# ── B17: ArgoCD Application with wrong source path ──
echo "  B17: Creating ArgoCD Application with wrong path..."

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: fluent-bit
  namespace: argocd
  labels:
    app.kubernetes.io/managed-by: platform-ops
    component: logging
spec:
  project: default
  source:
    repoURL: ${GITEA_URL}/root/platform-logging.git
    targetRevision: main
    path: charts/logging-legacy
  destination:
    server: https://kubernetes.default.svc
    namespace: $LOG_NS
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
echo "    ArgoCD Application fluent-bit created (points to charts/logging-legacy, wrong path)"

# ── B18: ArgoCD repo Secret with wrong password ──
echo "  B18: Creating ArgoCD repo Secret with wrong password..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-platform-logging
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${GITEA_URL}/root/platform-logging.git
  username: root
  password: wrong-password-expired-2026
EOF
echo "    ArgoCD repo Secret created with wrong password"

# ── B20: Decoy ArgoCD Application for Promtail ──
echo "  B20: Creating decoy ArgoCD Application for Promtail..."

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: log-collector
  namespace: argocd
  labels:
    app.kubernetes.io/managed-by: platform-ops
    component: logging
    priority: high
  annotations:
    description: "Primary log collection agent — migrated from Fluent Bit to Promtail"
spec:
  project: default
  source:
    repoURL: ${GITEA_URL}/root/observability-stack.git
    targetRevision: main
    path: charts/promtail
  destination:
    server: https://kubernetes.default.svc
    namespace: $OBS_NS
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
echo "    Decoy ArgoCD Application log-collector created (Promtail)"
echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 7: DECOY RESOURCES
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 7: Creating decoy resources..."
echo ""

# ── D1: Broken Promtail DaemonSet in observability namespace ──
echo "  D1: Creating broken Promtail DaemonSet..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: $OBS_NS
  labels:
    app: promtail
    app.kubernetes.io/name: promtail
    component: log-collector
  annotations:
    description: "Primary log collection agent — replacing Fluent Bit"
spec:
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      containers:
      - name: promtail
        image: grafana/promtail:2.9.0
        imagePullPolicy: IfNotPresent
        args:
        - -config.file=/etc/promtail/promtail.yaml
        - -client.url=http://loki-nonexistent.monitoring.svc.cluster.local:3100/loki/api/v1/push
        volumeMounts:
        - name: config
          mountPath: /etc/promtail
      volumes:
      - name: config
        configMap:
          name: promtail-config-missing
      tolerations:
      - operator: Exists
EOF
echo "    Promtail DaemonSet created in $OBS_NS (will CrashLoopBackOff)"

# ── D2: Misleading runbook ConfigMap ──
echo "  D2: Creating misleading runbook ConfigMap..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-remediation-runbook
  namespace: default
  labels:
    type: documentation
    app.kubernetes.io/managed-by: platform-ops
data:
  logging-architecture: |
    ## Platform Logging Architecture (v3.1)

    Current state: The platform is transitioning between log collection
    generations. Each generation introduced different agent runtimes, namespace
    conventions, and enrichment strategies. The log-collector ArgoCD Application
    governs the active generation, but residual workloads from prior generations
    may coexist in adjacent namespaces.

    Node enrichment follows the pipeline generation lifecycle. The enrichment
    stage must correspond to the active collection tier — applying the wrong
    enrichment approach will produce malformed labels or silent data loss.
    Consult the active ArgoCD Application spec to determine the current
    pipeline generation before making enrichment changes.

    Resource policies are managed by the platform governance team.
    See the resource policy ConfigMap in the logging namespace.
    Do NOT modify ResourceQuotas or LimitRanges without approval.

    For detailed setup, check the Gitea wiki:
    http://gitea.devops.local/root/bleater-app/wiki/Log-Collection-Architecture

  troubleshooting: |
    ## Log Collection Troubleshooting

    If logs are not appearing in Loki:
    1. Identify which pipeline generation is active by inspecting the log-collector
       ArgoCD Application spec — the namespace and workload type vary by generation
    2. Confirm the collection agent is running in the namespace designated by the
       active generation (legacy agents in other namespaces should be ignored)
    3. Verify the workload topology matches the collection tier: node-level
       collection must schedule on every node, centralized collection uses replicas
    4. Check the platform-ops channel in Mattermost for migration status updates

    If node metadata is missing:
    1. Determine which enrichment approach the active pipeline generation uses —
       earlier generations rely on external modules, current generation uses
       native agent filters
    2. Verify the enrichment stage is correctly configured for the active generation
    3. Check that the output plugin is configured to propagate enriched labels
       to the downstream destination
EOF
echo "    Runbook ConfigMap created in default namespace (misleading)"

# ── D8: Decoy CronJobs in platform-ops (harmless) ──
echo "  D8: Creating harmless decoy CronJobs..."

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: certificate-renewal-check
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    purpose: certificate-management
spec:
  schedule: "*/10 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: log-reconciler-sa
          containers:
          - name: checker
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "-c", "kubectl get certificates -A 2>/dev/null || true"]
          restartPolicy: Never
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: node-status-reporter
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    purpose: monitoring
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: log-reconciler-sa
          containers:
          - name: reporter
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "-c", "kubectl get nodes -o wide 2>/dev/null || true"]
          restartPolicy: Never
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: log-volume-monitor
  namespace: $OPS_NS
  labels:
    app.kubernetes.io/managed-by: platform-ops
    purpose: storage-monitoring
spec:
  schedule: "*/15 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: log-reconciler-sa
          containers:
          - name: monitor
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command: ["/bin/sh", "-c", "kubectl get pvc -A 2>/dev/null || true"]
          restartPolicy: Never
EOF
echo "    Decoy CronJobs created (certificate-renewal-check, node-status-reporter, log-volume-monitor)"

echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 8: GITEA WIKI PAGES (misleading documentation)
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 8: Creating Gitea wiki pages..."

for PAGE_DATA in \
    'Log-Collection-Architecture|## Log Collection Architecture\n\nThe Bleater platform uses a centralized log collection pipeline managed through\nmultiple deployment generations.\n\n### Current State (v3.1)\nThe platform has undergone several collection agent migrations. Each generation\nintroduced a different agent runtime and namespace convention. The active generation\nis managed by the `log-collector` ArgoCD Application, but legacy generations may\nstill have residual workloads running in their original namespaces.\n\nThe workload topology depends on the collection tier: node-level collection\nrequires scheduling on every node, while centralized collection aggregates\nfrom a single replica set. Ensure the workload type matches the collection\ntier defined in the ArgoCD Application.\n\n### Node Metadata Enrichment\nNode-level metadata enrichment has evolved across pipeline generations.\nEarlier generations relied on external enrichment modules managed by the\nsecurity team and co-located with the TLS certificate infrastructure.\nThe current generation supports native filter-based enrichment within the\ncollection agent itself. The enrichment approach must match the pipeline\ngeneration — mixing approaches across generations causes label conflicts\nand duplicate metadata in Loki.\n\nWhen troubleshooting missing node metadata, identify which pipeline generation\nis active before modifying any enrichment configuration.' \
    'Platform-Ops-Runbook|## Platform Operations Runbook\n\n### Resource Governance\nNamespaces with logging agents have strict resource controls:\n- Resource quotas prevent agents from consuming excessive cluster resources\n- LimitRanges enforce per-container maximums\n- These are managed by enforcement CronJobs in the platform-ops namespace\n\n### Priority Classes\nLogging agents should use an appropriate PriorityClass that matches their\nscheduling requirements. The platform provides `log-collector-priority`\nas a convenience class. Consult the platform-ops team for guidance on\nwhich priority class suits your workload tier.\n\n### Drift Enforcement\nPlatform-ops CronJobs enforce compliance across namespaces.\nIf enforcement is blocking a legitimate change, investigate the\nenforcement CronJobs in the platform-ops namespace.' \
    'Incident-2026-02-Log-Gap|## Incident Report: Log Collection Gap (2026-02-20)\n\n### Summary\nLogs were missing from Loki for approximately 45 minutes during a cluster maintenance event.\nThe SRE team was unable to correlate the gap with any infrastructure events due to missing\nnode-level metadata in the log streams.\n\n### Root Cause\nThe log collection agent was not resilient to pod rescheduling. Additionally, the agent\nconfiguration did not include node-level context, making incident triage difficult.\n\n### Resolution\nThe platform team initiated a migration to a new log collection architecture.\nSee #platform-ops channel in Mattermost for the latest migration status.\nThe `log-collector` ArgoCD Application was created to manage the new deployment.\n\n### Action Items\n- [x] Deploy new log collection agent via ArgoCD\n- [x] Deprecate legacy logging configuration\n- [ ] Complete node metadata enrichment rollout\n- [ ] Clean up legacy log collection resources\n- [ ] Update Grafana dashboards for new label schema'; do
    PAGE_TITLE=$(echo "$PAGE_DATA" | cut -d'|' -f1)
    PAGE_CONTENT=$(echo "$PAGE_DATA" | cut -d'|' -f2-)
    curl -sf -u "root:${GITEA_PASS}" -X POST "${GITEA_API}/repos/root/bleater-app/wiki/new" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"${PAGE_TITLE}\",\"content_base64\":\"$(echo -e "$PAGE_CONTENT" | base64 -w0)\"}" \
        2>/dev/null && echo "    Wiki: $PAGE_TITLE" || true
done
echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 9: MATTERMOST MESSAGES (misleading team communication)
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 9: Creating Mattermost messages..."

# Try to post to Mattermost #platform-ops channel
MATTERMOST_URL="http://mattermost.devops.local"
MM_TOKEN=$(curl -sf -X POST "${MATTERMOST_URL}/api/v4/users/login" \
    -H "Content-Type: application/json" \
    -d '{"login_id":"admin","password":"changeme"}' \
    -D - 2>/dev/null | grep -i "token:" | awk '{print $2}' | tr -d '\r' || true)

if [ -n "$MM_TOKEN" ]; then
    # Find or create platform-ops channel
    TEAM_ID=$(curl -sf -H "Authorization: Bearer $MM_TOKEN" \
        "${MATTERMOST_URL}/api/v4/teams" 2>/dev/null | python3 -c "
import sys, json
try:
    teams = json.load(sys.stdin)
    print(teams[0]['id'] if teams else '')
except: print('')
" 2>/dev/null)

    if [ -n "$TEAM_ID" ]; then
        CHANNEL_ID=$(curl -sf -X POST -H "Authorization: Bearer $MM_TOKEN" \
            -H "Content-Type: application/json" \
            "${MATTERMOST_URL}/api/v4/channels" \
            -d "{\"team_id\":\"$TEAM_ID\",\"name\":\"platform-ops\",\"display_name\":\"Platform Ops\",\"type\":\"O\"}" \
            2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

        if [ -z "$CHANNEL_ID" ]; then
            CHANNEL_ID=$(curl -sf -H "Authorization: Bearer $MM_TOKEN" \
                "${MATTERMOST_URL}/api/v4/teams/$TEAM_ID/channels/name/platform-ops" \
                2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
        fi

        if [ -n "$CHANNEL_ID" ]; then
            # Post misleading messages
            for MSG in \
                "**[Platform Update]** The log collection migration is complete. The \`log-collector\` ArgoCD Application is now the primary deployment. Legacy logging apps are frozen — please do not touch them until cleanup is scheduled." \
                "**[Node Enrichment]** Node-level metadata injection follows the platform enrichment lifecycle. The enrichment approach depends on which generation of the collection pipeline your namespace is running — earlier generations use sidecar-based injection co-located with the certificate management stack, while newer generations rely on the agent's native filter pipeline. If your logs are missing node context, verify that the enrichment stage appropriate to your pipeline generation is active. Do not mix enrichment approaches within the same collection tier." \
                "**[Resource Policy]** Reminder: All workloads running in governed namespaces are subject to the platform scheduling policy. Agents that operate at the node level follow a different priority tier than centralized collectors. The governance team has provisioned priority classes aligned with each scheduling tier — workloads that do not reference the correct tier will be deprioritized or evicted during resource contention. Refer to the resource-policy-guidelines ConfigMap for your workload's tier assignment." \
                "**[Incident Follow-up]** The log gap incident from Feb 20 has been addressed by the migration. Legacy agent cleanup is still pending. If you see legacy components running, do NOT restart or redeploy them — they will be removed in the next maintenance window."; do
                curl -sf -X POST -H "Authorization: Bearer $MM_TOKEN" \
                    -H "Content-Type: application/json" \
                    "${MATTERMOST_URL}/api/v4/posts" \
                    -d "{\"channel_id\":\"$CHANNEL_ID\",\"message\":\"$MSG\"}" \
                    2>/dev/null && echo "    Posted to #platform-ops" || true
            done
        fi
    fi
fi
echo ""

# ══════════════════════════════════════════════════════════════════════════
# PHASE 10: FINALIZATION
# ══════════════════════════════════════════════════════════════════════════

echo "Phase 10: Finalization..."

# Create allowed namespaces file
cat > /home/ubuntu/.allowed_namespaces <<EOF
bleater
monitoring
logging
observability
platform-ops
kube-system
argocd
default
EOF
chown ubuntu:ubuntu /home/ubuntu/.allowed_namespaces

# Create kubeconfig for ubuntu user (agent uses regular kubectl, no sudo)
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube
chmod 600 /home/ubuntu/.kube/config
echo "  Ubuntu kubeconfig configured at /home/ubuntu/.kube/config"

# Strip last-applied-configuration annotations
for ns in "$LOG_NS" "$MON_NS" "$OPS_NS" "$OBS_NS"; do
    for kind in deployment daemonset servicemonitor networkpolicy resourcequota limitrange configmap; do
        for name in $(kubectl get "$kind" -n "$ns" -o name 2>/dev/null); do
            kubectl annotate "$name" -n "$ns" kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true
        done
    done
done
echo "  Annotations stripped"

# Wait for enforcers to activate
echo "  Waiting for drift enforcers to activate..."
sleep 65

# ══════════════════════════════════════════════════════════════════════════
# VERIFICATION
# ══════════════════════════════════════════════════════════════════════════

echo ""
echo "=== Setup Verification ==="

echo "Fluent Bit Deployment in logging:"
kubectl get deployment fluent-bit -n "$LOG_NS" 2>/dev/null || echo "  Not found"

echo ""
echo "DaemonSet in monitoring (should not exist):"
kubectl get daemonset -n "$MON_NS" 2>/dev/null || echo "  None"

echo ""
echo "Node taints:"
kubectl describe node "$NODE_NAME" 2>/dev/null | grep -A5 "Taints:"

echo ""
echo "ResourceQuota in monitoring:"
kubectl get resourcequota -n "$MON_NS" 2>/dev/null

echo ""
echo "LimitRange in monitoring:"
kubectl get limitrange -n "$MON_NS" 2>/dev/null

echo ""
echo "CronJobs in platform-ops:"
kubectl get cronjobs -n "$OPS_NS" 2>/dev/null

echo ""
echo "ArgoCD Applications:"
kubectl get applications -n argocd 2>/dev/null

echo ""
echo "Enforcer Deployment in platform-ops:"
kubectl get deployment log-governance-controller -n "$OPS_NS" 2>/dev/null || echo "  Not found"

echo ""
echo "=== Setup Complete ==="
