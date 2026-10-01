# Runbook

Day-to-day operations on the deployment, with the output of a real session on a
single-node k3s cluster (the distribution installed by `terraform/`).

All commands use the namespace `platform-demo`:

```bash
alias k='kubectl -n platform-demo'
```

## Deploy

```
$ kubectl apply -k k8s/base
configmap/demo-app-config-5fbt8b8t5d created
service/demo-app created
deployment.apps/demo-app created
poddisruptionbudget.policy/demo-app created

$ k rollout status deploy/demo-app
deployment "demo-app" successfully rolled out

$ k get deploy,pods,svc,pdb
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/demo-app   3/3     3            3           8s

NAME                            READY   STATUS    RESTARTS   AGE
pod/demo-app-5589757795-8kdzg   1/1     Running   0          8s
pod/demo-app-5589757795-rd4sw   1/1     Running   0          8s
pod/demo-app-5589757795-vtxkf   1/1     Running   0          8s

NAME               TYPE       CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
service/demo-app   NodePort   10.43.30.132   <none>        80:30080/TCP   8s

NAME                                  MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
poddisruptionbudget.policy/demo-app   N/A             1                 1                     8s

$ curl -s localhost:30080/
{"message":"Hello from demo-app-5589757795-vtxkf","version":"1.0.0","environment":"dev","pod":"demo-app-5589757795-vtxkf","secretConfigured":true}
```

`secretConfigured: true` shows the Secret reached the container; its value is
never returned.

## Scale

```
$ k scale deploy/demo-app --replicas=5
deployment.apps/demo-app scaled

$ k get deploy demo-app
NAME       READY   UP-TO-DATE   AVAILABLE   AGE
demo-app   5/5     5            5           71s
```

The Service load-balances over every ready pod: repeat `curl` and the `pod`
field changes.

## Rolling update

In one terminal, watch the Service; in another, change the image.

```
$ k set image deploy/demo-app app=platform-demo-app:1.1.0
deployment.apps/demo-app image updated

$ k rollout status deploy/demo-app
Waiting for deployment "demo-app" rollout to finish: 1 old replicas are pending termination...
deployment "demo-app" successfully rolled out

$ scripts/watch-rollout.sh http://localhost:30080 55
requests ok: 155, failed: 0
  version 1.1.0 answered 80 times
  version 1.0.0 answered 75 times
```

## Roll back

```
$ k rollout history deploy/demo-app
REVISION  CHANGE-CAUSE
1         <none>
2         <none>

$ k rollout undo deploy/demo-app
deployment.apps/demo-app rolled back

$ curl -s localhost:30080/
{"message":"Hello from demo-app-5589757795-xkmgv","version":"1.0.0", ...}

$ k get rs
NAME                  DESIRED   CURRENT   READY   AGE
demo-app-5589757795   5         5         5       3m20s
demo-app-784c688f6d   0         0         0       2m5s
```

The ReplicaSet of version 1.1.0 is kept at zero replicas: that is what makes
the next `undo` (or a roll forward) immediate.

## Change configuration

Edit a literal in `k8s/base/kustomization.yaml` (`GREETING=Bonjour`) and apply.

```
$ kubectl apply -k k8s/base
configmap/demo-app-config-7f7bf6k286 created
deployment.apps/demo-app configured

$ k rollout status deploy/demo-app
deployment "demo-app" successfully rolled out

$ curl -s localhost:30080/
{"message":"Bonjour from demo-app-7654cdc855-5rhxh","version":"1.0.0", ...}

$ k get cm
demo-app-config-5fbt8b8t5d   3     35s
demo-app-config-7f7bf6k286   3     25s
```

A new ConfigMap was created (different hash suffix) and the Deployment was
rolled to use it. The previous one still exists, so rolling back the
Deployment also rolls back its configuration.

## Rotate the Secret

```bash
k create secret generic demo-app-secrets \
  --from-literal=API_TOKEN="$(openssl rand -hex 24)" \
  --dry-run=client -o yaml | kubectl apply -f -
k rollout restart deploy/demo-app      # environment variables are read at start
```

## Monitor resources

```
$ k top pods
NAME                        CPU(cores)   MEMORY(bytes)
demo-app-5589757795-8kdzg   2m           11Mi
demo-app-5589757795-rd4sw   2m           11Mi
demo-app-5589757795-vtxkf   13m          11Mi
```

Other first-line commands:

```bash
k get events --sort-by=.lastTimestamp      # probe failures, scaling, scheduling
k describe pod <pod>                       # restarts, last state, limits
k logs deploy/demo-app --tail=50
curl -s localhost:30080/metrics            # request counter, memory, uptime
kubectl top node
```

## Autoscaling

```
$ kubectl apply -k k8s/overlays/autoscaling
horizontalpodautoscaler.autoscaling/demo-app created

$ k get hpa
NAME       REFERENCE             TARGETS       MINPODS   MAXPODS   REPLICAS
demo-app   Deployment/demo-app   cpu: 5%/60%   3         6         3
```

Three clients calling `/work?ms=40` in a loop:

```
$ k get hpa        # every 25 s
demo-app   Deployment/demo-app   cpu: 64%/60%    3     6     3
demo-app   Deployment/demo-app   cpu: 282%/60%   3     6     6
demo-app   Deployment/demo-app   cpu: 225%/60%   3     6     6
demo-app   Deployment/demo-app   cpu: 153%/60%   3     6     6

$ k top pods
demo-app-958b688b6-ghlfp   85m   14Mi
demo-app-958b688b6-jd24f   77m   14Mi
...

$ k describe hpa demo-app
Normal  SuccessfulRescale  New size: 6; reason: cpu resource utilization (percentage of request) above target
```

Utilization is relative to the CPU *request* (50m), which is why it can exceed
100%. When the load stops, the HPA waits for its 60 s stabilization window and
scales back to 3.

### Two things learned while testing this

**Probes and CPU saturation.** A first, heavier load test (six clients,
`ms=400`) did not scale at all: the pods were so busy that their probes timed
out after one second, they were marked unready, and the HPA ignores unready
pods:

```
Warning  Unhealthy                pod/demo-app-...   Readiness probe failed: context deadline exceeded
Warning  FailedGetResourceMetric  horizontalpodautoscaler/demo-app   did not receive metrics for targeted pods (pods might be unready)
```

The probes now have a 2 s timeout and readiness tolerates one miss. The
underlying cause is the app itself: `/work` blocks Node's event loop, so a
saturated pod cannot answer its own health check.

**Adopting the HPA resets replicas once.** The autoscaling overlay removes
`spec.replicas` from the Deployment. On the first apply the count falls back
to the default (1) for a few seconds, until the HPA enforces its minimum:

```
Normal  SuccessfulRescale  New size: 3; reason: Current number of replicas below Spec.MinReplicas
```

With `maxUnavailable: 0` this does not interrupt service, but it is a capacity
dip: on a loaded system, apply the HPA first and remove `replicas` afterwards.
