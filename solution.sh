#!/bin/bash
# Solution: Fluent Bit DaemonSet Log Enrichment (Hard Mode)
# Fixes all 20 breakages across 5 subscores
set -e

# Ubuntu user needs sudo for kubectl (cluster-scoped operations)
# Create wrapper so all kubectl calls go through sudo
mkdir -p /tmp/bin
cat > /tmp/bin/kubectl <<'WRAPPER'
#!/bin/bash
exec sudo /usr/local/bin/kubectl "$@"
WRAPPER
chmod +x /tmp/bin/kubectl
export PATH="/tmp/bin:$PATH"

NS="bleater"
MON_NS="monitoring"
LOG_NS="logging"
OPS_NS="platform-ops"
OBS_NS="observability"

echo "=== Fluent Bit DaemonSet Log Enrichment — Solution ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: NEUTRALIZE ALL DRIFT ENFORCERS FIRST
# Must be done before any resource changes, otherwise fixes get reverted.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 1: Neutralizing drift enforcers..."

# 1a: Remove the static pod enforcer manifest (B3)
echo "  Removing static pod enforcer..."
sudo rm -f /var/lib/rancher/k3s/agent/pod-manifests/log-collector-enforcer.yaml
sudo rm -rf /etc/fluent-bit-enforcer
echo "    ✓ Static pod enforcer removed"

# Wait for kubelet to clean up the static pod
sleep 10

# 1b: Remove ALL host-level cron enforcers (B4, B12)
echo "  Removing host cron enforcers..."
sudo rm -f /etc/cron.d/log-collector-reconciler
sudo rm -f /etc/cron.d/logging-policy-enforcer
sudo rm -f /etc/cron.d/node-taint-enforcer
# Keep harmless decoy crons — they don't need removal
sudo rm -rf /etc/logging-governance
echo "    ✓ Host cron enforcers removed"

# 1c: Delete CronJob enforcers in platform-ops (B4, B12)
echo "  Deleting CronJob enforcers in platform-ops..."
kubectl delete cronjob log-collector-reconciler -n "$OPS_NS" 2>/dev/null && echo "    ✓ log-collector-reconciler deleted" || true
kubectl delete cronjob logging-policy-enforcer -n "$OPS_NS" 2>/dev/null && echo "    ✓ logging-policy-enforcer deleted" || true
kubectl delete jobs --all -n "$OPS_NS" 2>/dev/null || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: REMOVE BLOCKING RESOURCES (B2, B9, B10)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 2: Removing blocking resources..."

# 2a: Remove node taint (B2)
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint node "$NODE_NAME" node-role.kubernetes.io/log-collector- 2>/dev/null && \
    echo "  ✓ Node taint removed" || echo "  Node taint already absent"

# 2b: Delete ResourceQuota (B9)
kubectl delete resourcequota logging-resource-quota -n "$MON_NS" 2>/dev/null && \
    echo "  ✓ ResourceQuota logging-resource-quota deleted" || true

# 2c: Delete LimitRange (B10)
kubectl delete limitrange log-agent-governance -n "$MON_NS" 2>/dev/null && \
    echo "  ✓ LimitRange log-agent-governance deleted" || true

# 2d: Delete NetworkPolicy blocking scrape port (B15)
kubectl delete networkpolicy monitoring-scrape-policy -n "$MON_NS" 2>/dev/null && \
    echo "  ✓ NetworkPolicy monitoring-scrape-policy deleted" || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: DELETE THE OLD FLUENT BIT DEPLOYMENT (B1)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 3: Removing old Fluent Bit Deployment from logging namespace..."

kubectl delete deployment fluent-bit -n "$LOG_NS" 2>/dev/null && \
    echo "  ✓ Fluent Bit Deployment deleted from logging" || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: FIX RBAC FOR NODE METADATA ACCESS (B6)
# The ClusterRole exists but is missing 'nodes' resource and has no binding.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 4: Fixing RBAC for node metadata access..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluent-bit
  namespace: $MON_NS
  labels:
    app: fluent-bit
    app.kubernetes.io/name: fluent-bit
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluent-bit-node-reader
  labels:
    app: fluent-bit
rules:
- apiGroups: [""]
  resources: ["namespaces", "pods", "nodes"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluent-bit-node-reader-binding
  labels:
    app: fluent-bit
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluent-bit-node-reader
subjects:
- kind: ServiceAccount
  name: fluent-bit
  namespace: $MON_NS
EOF
echo "  ✓ ClusterRole updated with 'nodes' resource and ClusterRoleBinding created"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: CREATE FLUENT BIT CONFIGMAP WITH NODE ENRICHMENT (B5, B7, B14)
# - Adds proper Lua filter for node_name, kernel_version, node_labels
# - Enables HTTP_Server for Prometheus metrics
# - Uses downward API + Lua for node enrichment (not the buggy decoy script)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 5: Creating Fluent Bit ConfigMap with node enrichment and metrics..."

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: fluent-bit-config
  namespace: $MON_NS
  labels:
    app: fluent-bit
    app.kubernetes.io/name: fluent-bit
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush        5
        Daemon       Off
        Log_Level    info
        HTTP_Server  On
        HTTP_Listen  0.0.0.0
        HTTP_Port    2020
        Parsers_File parsers.conf

    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            docker
        Tag               kube.*
        Refresh_Interval  5
        Skip_Long_Lines   On
        DB                /var/log/flb_kube.db
        Mem_Buf_Limit     5MB

    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    [FILTER]
        Name    lua
        Match   kube.*
        script  /fluent-bit/scripts/node-enrichment.lua
        call    enrich_with_node_metadata

    [OUTPUT]
        Name              loki
        Match             kube.*
        Host              loki.${MON_NS}.svc.cluster.local
        Port              3100
        Labels            job=fluent-bit
        label_keys         \$node_name,\$kernel_version,\$node_labels
        auto_kubernetes_labels on
        line_format       json

  parsers.conf: |
    [PARSER]
        Name        docker
        Format      json
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L
        Time_Keep   On

  node-enrichment.lua: |
    -- Node metadata enrichment for Fluent Bit
    -- Reads node info from downward API environment variables

    function enrich_with_node_metadata(tag, timestamp, record)
        -- NODE_NAME is injected via downward API fieldRef
        local node_name = os.getenv("NODE_NAME")
        if node_name ~= nil and node_name ~= "" then
            record["node_name"] = node_name
        end

        -- KERNEL_VERSION is injected via downward API (read from /etc/node-info)
        local kv_file = io.open("/etc/node-info/kernel_version", "r")
        if kv_file ~= nil then
            local kv = kv_file:read("*all")
            kv_file:close()
            if kv ~= nil then
                record["kernel_version"] = kv:gsub("%s+$", "")
            end
        end

        -- NODE_LABELS is injected via downward API
        local nl_file = io.open("/etc/node-info/node_labels", "r")
        if nl_file ~= nil then
            local nl = nl_file:read("*all")
            nl_file:close()
            if nl ~= nil then
                record["node_labels"] = nl:gsub("%s+$", "")
            end
        end

        return 1, timestamp, record
    end
EOF
echo "  ✓ Fluent Bit ConfigMap created with Lua enrichment + HTTP_Server On"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: DEPLOY FLUENT BIT DAEMONSET IN MONITORING NAMESPACE (B1, B2, B3, B11)
# - DaemonSet (not Deployment)
# - In monitoring namespace (not logging)
# - With tolerations for the node taint
# - With system-node-critical priorityClassName
# - With proper resource requests/limits
# - With downward API for node metadata
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 6: Deploying Fluent Bit DaemonSet..."

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluent-bit
  namespace: $MON_NS
  labels:
    app: fluent-bit
    app.kubernetes.io/name: fluent-bit
    app.kubernetes.io/component: logging
spec:
  selector:
    matchLabels:
      app: fluent-bit
  template:
    metadata:
      labels:
        app: fluent-bit
        app.kubernetes.io/name: fluent-bit
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "2020"
        prometheus.io/path: "/api/v1/metrics/prometheus"
    spec:
      serviceAccountName: fluent-bit
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
      containers:
      - name: fluent-bit
        image: fluent/fluent-bit:2.1
        imagePullPolicy: IfNotPresent
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        ports:
        - name: metrics
          containerPort: 2020
          protocol: TCP
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
        volumeMounts:
        - name: config
          mountPath: /fluent-bit/etc/
        - name: lua-scripts
          mountPath: /fluent-bit/scripts/
        - name: varlog
          mountPath: /var/log
        - name: node-info
          mountPath: /etc/node-info
          readOnly: true
      initContainers:
      - name: node-info-collector
        image: bitnami/kubectl:latest
        imagePullPolicy: IfNotPresent
        command:
        - /bin/sh
        - -c
        - |
          # Collect node metadata and write to shared volume
          NODE=\$(cat /etc/hostname 2>/dev/null || echo "\$NODE_NAME")
          # Get kernel version from node object
          KERNEL=\$(kubectl get node \$NODE_NAME -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null || uname -r)
          echo -n "\$KERNEL" > /node-info/kernel_version
          # Get node labels using go-template (no python3 needed)
          kubectl get node \$NODE_NAME -o go-template='{{range \$k, \$v := .metadata.labels}}{{printf "%s=%s," \$k \$v}}{{end}}' 2>/dev/null | sed 's/,$//' > /node-info/node_labels
          echo "Node info collected: kernel=\$KERNEL"
        env:
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        volumeMounts:
        - name: node-info
          mountPath: /node-info
      volumes:
      - name: config
        configMap:
          name: fluent-bit-config
      - name: lua-scripts
        configMap:
          name: fluent-bit-config
          items:
          - key: node-enrichment.lua
            path: node-enrichment.lua
      - name: varlog
        hostPath:
          path: /var/log
      - name: node-info
        emptyDir: {}
EOF
echo "  ✓ Fluent Bit DaemonSet deployed in monitoring"

# Create a Service for the DaemonSet (needed by ServiceMonitor)
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: fluent-bit
  namespace: $MON_NS
  labels:
    app: fluent-bit
    app.kubernetes.io/name: fluent-bit
spec:
  selector:
    app: fluent-bit
  ports:
  - name: metrics
    port: 2020
    targetPort: 2020
    protocol: TCP
  clusterIP: None
EOF
echo "  ✓ Fluent Bit headless Service created"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: FIX LOKI LABEL LIMITS (B8)
# max_label_names_per_series was set to 8 — too low for enriched streams.
# Increase to 30 to accommodate node metadata labels.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 7: Fixing Loki label limits..."

LOKI_NS=$(kubectl get pods -A -l app=loki -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "monitoring")
LOKI_CM=$(kubectl get configmap -n "$LOKI_NS" -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$LOKI_CM" ]; then
    LOKI_CONFIG=$(kubectl get configmap "$LOKI_CM" -n "$LOKI_NS" -o jsonpath='{.data.loki\.yaml}' 2>/dev/null || \
                  kubectl get configmap "$LOKI_CM" -n "$LOKI_NS" -o jsonpath='{.data.config\.yaml}' 2>/dev/null)

    if [ -n "$LOKI_CONFIG" ]; then
        MODIFIED_CONFIG=$(echo "$LOKI_CONFIG" | python3 -c "
import sys, yaml

config = yaml.safe_load(sys.stdin.read())
if config is None:
    config = {}
if 'limits_config' not in config:
    config['limits_config'] = {}
config['limits_config']['max_label_names_per_series'] = 30
config['limits_config']['max_label_value_length'] = 4096
print(yaml.dump(config, default_flow_style=False))
" 2>/dev/null)

        if [ -n "$MODIFIED_CONFIG" ]; then
            DATA_KEY="loki.yaml"
            kubectl get configmap "$LOKI_CM" -n "$LOKI_NS" -o jsonpath='{.data.config\.yaml}' &>/dev/null && DATA_KEY="config.yaml"

            kubectl create configmap "$LOKI_CM" -n "$LOKI_NS" \
                --from-literal="$DATA_KEY=$MODIFIED_CONFIG" \
                --dry-run=client -o yaml | kubectl apply -f -
            echo "  ✓ Loki max_label_names_per_series increased to 30"

            # Restart Loki to pick up config change
            kubectl rollout restart statefulset loki -n "$LOKI_NS" 2>/dev/null || \
                kubectl rollout restart deployment loki -n "$LOKI_NS" 2>/dev/null || true
            echo "  ✓ Loki restarted"
        fi
    fi
else
    # Delete any override ConfigMap
    kubectl delete configmap loki-limits-override -n "$MON_NS" 2>/dev/null || true
    echo "  Note: Loki ConfigMap not found — override removed"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: FIX SERVICEMONITOR (B13)
# Fix label selector and port to match the actual Fluent Bit DaemonSet Service.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 8: Fixing ServiceMonitor..."

kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: fluent-bit-metrics
  namespace: $MON_NS
  labels:
    app: fluent-bit
    release: kube-prometheus-stack
spec:
  namespaceSelector:
    matchNames:
    - $MON_NS
  selector:
    matchLabels:
      app: fluent-bit
  endpoints:
  - port: metrics
    path: /api/v1/metrics/prometheus
    interval: 30s
EOF
echo "  ✓ ServiceMonitor fixed with correct selectors and port"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 9: REMOVE PROMETHEUS METRIC DROP RULE (B16)
# The additional scrape config drops fluentbit_* metrics.
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 9: Removing Prometheus metric drop rule..."

PROM_NS=$(kubectl get pods -A -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "monitoring")

# Delete the additional scrape config secret that drops fluentbit metrics
kubectl delete secret prometheus-additional-scrape-configs -n "$PROM_NS" 2>/dev/null && \
    echo "  ✓ Additional scrape config secret deleted" || true

# Remove the additionalScrapeConfigs from Prometheus CR
PROM_NAME=$(kubectl get prometheus -n "$PROM_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$PROM_NAME" ]; then
    kubectl patch prometheus "$PROM_NAME" -n "$PROM_NS" --type=json \
        -p='[{"op":"remove","path":"/spec/additionalScrapeConfigs"}]' 2>/dev/null && \
        echo "  ✓ Prometheus additionalScrapeConfigs removed" || true
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 10: FIX GITOPS — UPDATE GITEA REPO AND ARGOCD APPLICATION (B17, B18, B19)
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 10: Fixing GitOps integration..."

# 10a: Get correct Gitea password
GITEA_PASS=$(python3 -c "
import urllib.request, re
try:
    html = urllib.request.urlopen('http://passwords.devops.local', timeout=10).read().decode()
    m = re.search(r'<h3>Gitea</h3>.*?Password.*?class=\"value\">([^<]+)', html, re.DOTALL)
    print(m.group(1).strip() if m else 'password')
except: print('password')
" 2>/dev/null)
# Use -u flag for curl auth instead of embedding in URL (avoids @ in password breaking URL parsing)
GITEA_API="http://gitea.gitea.svc.cluster.local:3000/api/v1"
GITEA_URL="http://gitea.gitea.svc.cluster.local:3000"

echo "  10a: Updating Gitea repo with correct DaemonSet values..."

# Update charts/fluent-bit/values.yaml with correct DaemonSet config
CORRECT_VALUES=$(cat <<'HELMEOF'
# Fluent Bit Helm values — DaemonSet with node enrichment
# Managed by ArgoCD — do not edit manually in cluster

kind: DaemonSet

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
        HTTP_Server  On
        HTTP_Listen  0.0.0.0
        HTTP_Port    2020
        Parsers_File parsers.conf

  inputs: |
    [INPUT]
        Name              tail
        Path              /var/log/containers/*.log
        Parser            docker
        Tag               kube.*
        Refresh_Interval  5
        Skip_Long_Lines   On
        DB                /var/log/flb_kube.db
        Mem_Buf_Limit     5MB

  filters: |
    [FILTER]
        Name                kubernetes
        Match               kube.*
        Merge_Log           On
        Keep_Log            Off
        K8S-Logging.Parser  On
        K8S-Logging.Exclude On

    [FILTER]
        Name    lua
        Match   kube.*
        script  /fluent-bit/scripts/node-enrichment.lua
        call    enrich_with_node_metadata

  outputs: |
    [OUTPUT]
        Name              loki
        Match             kube.*
        Host              loki.monitoring.svc.cluster.local
        Port              3100
        Labels            job=fluent-bit
        label_keys         $node_name,$kernel_version,$node_labels
        line_format       json

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

priorityClassName: system-node-critical

tolerations:
  - operator: Exists

serviceMonitor:
  enabled: true
  interval: 30s
  path: /api/v1/metrics/prometheus

luaScripts:
  node-enrichment.lua: |
    function enrich_with_node_metadata(tag, timestamp, record)
        local node_name = os.getenv("NODE_NAME")
        if node_name ~= nil and node_name ~= "" then
            record["node_name"] = node_name
        end
        local kv_file = io.open("/etc/node-info/kernel_version", "r")
        if kv_file ~= nil then
            local kv = kv_file:read("*all")
            kv_file:close()
            if kv ~= nil then
                record["kernel_version"] = kv:gsub("%s+$", "")
            end
        end
        local nl_file = io.open("/etc/node-info/node_labels", "r")
        if nl_file ~= nil then
            local nl = nl_file:read("*all")
            nl_file:close()
            if nl ~= nil then
                record["node_labels"] = nl:gsub("%s+$", "")
            end
        end
        return 1, timestamp, record
    end
HELMEOF
)

# Get the current file SHA (needed for update) — tolerate errors
set +e
FILE_SHA=$(curl -sf -u "root:${GITEA_PASS}" "${GITEA_API}/repos/root/platform-logging/contents/charts/fluent-bit/values.yaml" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null)
set -e

ENCODED_VALUES=$(echo "$CORRECT_VALUES" | base64 -w0 2>/dev/null || echo "$CORRECT_VALUES" | base64 2>/dev/null)

if [ -n "$FILE_SHA" ]; then
    curl -sf -u "root:${GITEA_PASS}" -X PUT "${GITEA_API}/repos/root/platform-logging/contents/charts/fluent-bit/values.yaml" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${ENCODED_VALUES}\",\"message\":\"Update to DaemonSet with node enrichment\",\"sha\":\"$FILE_SHA\"}" \
        2>/dev/null && echo "    ✓ charts/fluent-bit/values.yaml updated with DaemonSet config" || echo "    Note: Could not update values.yaml (may need manual update)"
else
    curl -sf -u "root:${GITEA_PASS}" -X POST "${GITEA_API}/repos/root/platform-logging/contents/charts/fluent-bit/values.yaml" \
        -H "Content-Type: application/json" \
        -d "{\"content\":\"${ENCODED_VALUES}\",\"message\":\"Add DaemonSet config\"}" \
        2>/dev/null && echo "    ✓ charts/fluent-bit/values.yaml created" || echo "    Note: Could not create values.yaml (may need manual update)"
fi

# 10b: Fix ArgoCD repo Secret with correct password (B18)
echo "  10b: Fixing ArgoCD repo Secret..."

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
  password: "${GITEA_PASS}"
EOF
echo "    ✓ ArgoCD repo Secret updated with correct Gitea password"

# 10c: Fix ArgoCD Application source path and destination (B17)
echo "  10c: Fixing ArgoCD Application..."

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
    path: charts/fluent-bit
  destination:
    server: https://kubernetes.default.svc
    namespace: $MON_NS
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF
echo "    ✓ ArgoCD Application fixed: path=charts/fluent-bit, namespace=monitoring"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 11: WAIT FOR DAEMONSET AND LOKI TO STABILIZE
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 11: Waiting for services to stabilize..."

# Wait for DaemonSet to be ready
echo "  Waiting for Fluent Bit DaemonSet..."
ELAPSED=0
MAX_WAIT=300
while true; do
    DESIRED=$(kubectl get daemonset fluent-bit -n "$MON_NS" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    READY=$(kubectl get daemonset fluent-bit -n "$MON_NS" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    if [ "$DESIRED" -gt 0 ] && [ "$DESIRED" = "$READY" ]; then
        echo "    ✓ DaemonSet ready: $READY/$DESIRED"
        break
    fi
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "    ⚠ DaemonSet not fully ready after ${MAX_WAIT}s (desired=$DESIRED, ready=$READY)"
        break
    fi
    echo "    Waiting... ($ELAPSED/${MAX_WAIT}s, desired=$DESIRED, ready=$READY)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

# Wait for Loki to be ready
echo "  Waiting for Loki..."
kubectl rollout status statefulset loki -n "$LOKI_NS" --timeout=180s 2>/dev/null || \
    kubectl rollout status deployment loki -n "$LOKI_NS" --timeout=180s 2>/dev/null || true

# Give Fluent Bit time to collect and ship logs
echo "  Waiting 60s for log ingestion..."
sleep 60
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 12: VERIFY
# ─────────────────────────────────────────────────────────────────────────────
echo "Step 12: Verification..."

echo "  DaemonSet status:"
kubectl get daemonset fluent-bit -n "$MON_NS"
echo ""

echo "  DaemonSet pod:"
kubectl get pods -n "$MON_NS" -l app=fluent-bit
echo ""

echo "  DaemonSet spec (priority, resources, tolerations):"
kubectl get daemonset fluent-bit -n "$MON_NS" -o jsonpath='{.spec.template.spec.priorityClassName}' && echo ""
kubectl get daemonset fluent-bit -n "$MON_NS" -o jsonpath='{.spec.template.spec.containers[0].resources}' && echo ""
echo ""

echo "  ServiceMonitor:"
kubectl get servicemonitor fluent-bit-metrics -n "$MON_NS" 2>/dev/null
echo ""

echo "  ArgoCD Application:"
kubectl get application fluent-bit -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null && echo ""
kubectl get application fluent-bit -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null && echo ""
echo ""

echo "  Node taints:"
kubectl describe node "$NODE_NAME" 2>/dev/null | grep "Taints:"
echo ""

echo "  ResourceQuota/LimitRange in monitoring:"
kubectl get resourcequota -n "$MON_NS" 2>/dev/null || echo "  None"
kubectl get limitrange -n "$MON_NS" 2>/dev/null || echo "  None"
echo ""

echo "  Host cron enforcers (should only be harmless decoys):"
ls /etc/cron.d/ 2>/dev/null
echo ""

echo "  Static pod manifests (should be empty or no enforcer):"
ls /var/lib/rancher/k3s/agent/pod-manifests/ 2>/dev/null
echo ""

echo "  Loki query test (checking for node_name label):"
curl -sf "http://loki.${LOKI_NS}.svc.cluster.local:3100/loki/api/v1/query?query={node_name=~\".%2B\"}&limit=5" 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    print(f'  Found {len(results)} streams with node_name label')
    if results:
        labels = results[0].get('stream', {})
        print(f'  Sample labels: {json.dumps(labels, indent=2)}')
except:
    print('  Could not query Loki')
" 2>/dev/null
echo ""

echo "=== Solution Complete ==="
