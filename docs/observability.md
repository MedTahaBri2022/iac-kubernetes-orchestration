# Observability

Prometheus collects metrics, Alertmanager routes alerts, Grafana displays a
dashboard. Everything is declared in `k8s/monitoring/` and versioned: scrape
configuration, alert rules, their unit tests, the data source and the
dashboard.

```
demo-app pods ──/metrics──┐
                          ├──► Prometheus ──rules──► Alertmanager
kubelet cAdvisor ─────────┘        │
(CPU, memory per container)        └──► Grafana (provisioned dashboard)
```

## Deploy

```bash
kubectl apply -f k8s/monitoring/namespace.yaml
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=password="$(openssl rand -hex 16)"
kubectl apply -k k8s/monitoring
```

The three UIs are `ClusterIP` services on purpose: they are not exposed by the
node's security group. Reach them through the API server:

```bash
kubectl -n monitoring port-forward svc/grafana 3000:3000        # admin / the secret above
kubectl -n monitoring port-forward svc/prometheus 9090:9090
kubectl -n monitoring port-forward svc/alertmanager 9093:9093
```

## What is measured

The application exposes, without any dependency, the metrics a service needs
to be operated (the "RED" method: rate, errors, duration):

| Metric | Type | Use |
| --- | --- | --- |
| `http_requests_total{route,status}` | counter | traffic and error ratio |
| `http_request_duration_seconds` | histogram | latency percentiles |
| `app_info{version}` | gauge | which build runs where, during a rollout |
| `app_memory_rss_bytes`, `app_uptime_seconds` | gauge | process health |

Only known routes become label values (`route="other"` for the rest), so
random URLs cannot create an unbounded number of time series. Probes and
scrapes are counted but excluded from the latency histogram and from the error
ratio, otherwise thousands of fast `/healthz` calls would hide real failures.

Resource usage (`container_cpu_usage_seconds_total`,
`container_memory_working_set_bytes`, CFS throttling) comes from the kubelet's
cAdvisor endpoint, scraped through the API server.

Pods opt in with annotations; Prometheus discovers them through the Kubernetes
API with a read-only ServiceAccount:

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8080"
  prometheus.io/path: /metrics
```

## Verified on the local cluster

```
targets      kubernetes-pods: 3 up · kubernetes-cadvisor: 1 up · prometheus: 1 up
rules        6 loaded
dashboard    "Demo app: traffic, errors, latency, resources" (provisioned)
```

Alerts were then triggered on purpose:

| Action | Result |
| --- | --- |
| One request in three sent to `/fail` for 3 minutes | `DemoAppHighErrorRate` firing: "30.94% of demo-app requests returned a 5xx" |
| `kubectl scale --replicas=2` | `DemoAppReplicasLow` firing: "Only 2 demo-app pod(s) are being scraped successfully" |
| `kubectl scale --replicas=0` | `DemoAppDown` firing after one minute |

Both reached Alertmanager (`/api/v2/alerts`). No notification channel is
configured in this repository; the place to add Slack or e-mail is marked in
`config/alertmanager.yml`.

## Alerts

Symptom alerts page; cause alerts warn. Each has a `for:` duration so that a
pod restart or a single slow request does not wake anyone up.

### DemoAppDown

*critical* – no pod can be scraped for 1 minute.

```bash
kubectl -n platform-demo get pods,events
kubectl -n platform-demo describe deploy demo-app
kubectl -n platform-demo rollout undo deploy/demo-app     # if a release caused it
```

### DemoAppHighErrorRate

*critical* – more than 5% of real requests return a 5xx over 2 minutes, for
1 minute.

```bash
kubectl -n platform-demo logs deploy/demo-app --tail=100
kubectl -n platform-demo rollout history deploy/demo-app  # did it start with a release?
```

In Grafana, *Requests by pod* shows whether one pod or all of them fail, and
*Running version* whether it coincides with a rollout.

### DemoAppHighLatency

*warning* – 95th percentile above 500 ms for 2 minutes. Check *CPU by pod* and
`DemoAppCpuThrottled`: with a 250m limit, a saturated pod slows down before
the autoscaler adds replicas.

### DemoAppReplicasLow

*warning* – fewer than 3 healthy pods for 2 minutes.

```bash
kubectl -n platform-demo get pods -o wide
kubectl -n platform-demo describe pod <pod>     # probe failures, OOMKilled, image pull
```

### DemoAppMemoryNearLimit

*warning* – a pod above 85% of its 128Mi limit for 5 minutes: it will be
OOM-killed if it keeps growing. Look for a leak before raising the limit.

### DemoAppCpuThrottled

*warning* – a pod throttled more than 25% of the time for 5 minutes. Raise the
CPU limit or let the HPA scale earlier (lower the target utilization).

## Tested like code

`config/alerts.test.yml` contains unit tests of the rules, run by
`promtool test rules` in CI without any cluster. Among them:

- 30% of failing requests fires the error-rate alert with the expected text;
- 100 health-check requests per interval do **not** dilute the error ratio;
- two healthy pods out of three is *pending* after one minute and *firing*
  after three;
- healthy traffic fires nothing.

CI also validates the Prometheus and Alertmanager configuration files and, in
the delivery workflow, deploys the whole stack on a throwaway cluster and
checks that Prometheus really scrapes the three pods.

## Limits

- Prometheus keeps its data in an `emptyDir` (two days, lost on reschedule).
- One Prometheus, one Alertmanager: no high availability.
- No kube-state-metrics: desired versus available replicas, restarts and
  OOM kills are inferred from `up` and cAdvisor rather than read from the
  Kubernetes object state.
- No logs or traces, only metrics.
- The inhibition rule (an outage silences its secondary alerts) is configured
  but was not observed in the test above, because those alerts had no data
  left once every pod was gone.
