# Infrastructure as Code & Kubernetes Orchestration

Provision a cloud network and a Kubernetes node on AWS with **Terraform**, then
deploy a containerized application on **Kubernetes** with replica scaling,
zero-downtime rolling updates, ConfigMaps, Secrets and resource monitoring.

**Terraform · AWS (VPC, EC2, Security Groups) · Kubernetes · Docker · YAML**

[![CI](https://github.com/MedTahaBri2022/iac-kubernetes-orchestration/actions/workflows/ci.yml/badge.svg)](https://github.com/MedTahaBri2022/iac-kubernetes-orchestration/actions/workflows/ci.yml)

```
terraform/                       k8s/
┌──────────────────────────┐     ┌────────────────────────────────────────┐
│ VPC 10.20.0.0/16         │     │ namespace platform-demo                │
│ └ public subnet          │     │                                        │
│   └ EC2 (Ubuntu, k3s) ───┼────▶│ Deployment demo-app (3 replicas)       │
│ Internet gateway, routes │     │   rolling update, probes, limits       │
│ Security group           │     │ Service (NodePort 30080)               │
│   22, 6443  ← admin IP   │     │ ConfigMap (generated) · Secret         │
│   30080     ← public     │     │ PodDisruptionBudget · HPA (3 → 6)      │
└──────────────────────────┘     └────────────────────────────────────────┘
```

## How it was verified

No AWS account was charged to build this repository. Being explicit about what
ran where:

| Part | Verified with | Result |
| --- | --- | --- |
| Terraform code | `terraform fmt`, `validate`, then `apply` + `destroy` against a local AWS emulator ([moto](https://github.com/getmoto/moto)) | 12 resources created and destroyed |
| Kubernetes manifests | a local single-node k3s cluster (the same distribution the EC2 node installs) | every scenario below was run; outputs are in [docs/runbook.md](docs/runbook.md) |
| `user_data` (k3s install on EC2) | **not executed**: an emulator does not boot instances | to be confirmed on a real account |

CI repeats the first two on every push: Terraform against moto, and the
manifests on a throwaway `kind` cluster including a rolling update under load.

## Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars    # set admin_cidr and ssh_public_key
terraform init
terraform plan
terraform apply
```

| File | Content |
| --- | --- |
| `network.tf` | VPC, public subnet, internet gateway, route table |
| `security.tf` | Security group, one resource per rule |
| `compute.tf` | Ubuntu 24.04 AMI lookup, key pair, EC2 instance |
| `templates/user_data.sh.tftpl` | First-boot script: installs k3s |
| `variables.tf` | Inputs with validation |
| `outputs.tf` | Public IP, application URL, SSH and kubeconfig commands |

Choices worth noting:

- **Admin access is never open to the world.** `admin_cidr` has no default and
  a validation rule rejects `0.0.0.0/0`; SSH and the Kubernetes API are only
  reachable from that CIDR.
- **IMDSv2 required** with a hop limit of 1, so a pod cannot read the
  instance's credentials; root volume encrypted.
- **Inputs are validated** (CIDR syntax, environment name, NodePort range): a
  typo fails at `plan`, not halfway through `apply`.
- **`default_tags`** on the provider: every resource is tagged with project,
  environment and `ManagedBy = terraform`.
- **No secrets and no state in git**: `*.tfvars` and `*.tfstate` are ignored;
  a remote S3 backend with locking is sketched in `versions.tf`.
- **Provider versions are pinned** (`.terraform.lock.hcl` is committed).

Applying to real AWS creates billable resources (one `t3.small` instance by
default). Run `terraform destroy` when done.

### Try it without an AWS account

```bash
docker run -d --name moto -p 5000:5000 motoserver/moto:5.1.4
export AWS_ACCESS_KEY_ID=testing AWS_SECRET_ACCESS_KEY=testing
terraform apply \
  -var emulator_endpoint=http://localhost:5000 \
  -var admin_cidr=203.0.113.7/32 \
  -var ami_id=<an AMI id listed by the emulator>
```

A second `plan` against moto shows one in-place change on the instance
(`metadata_options`): the emulator does not return that block. It is a gap of
the emulator, not drift in the configuration.

## Kubernetes

```bash
# 1. Build the application image (two versions, to have something to roll out)
docker build --build-arg APP_VERSION=1.0.0 -t platform-demo-app:1.0.0 app
docker build --build-arg APP_VERSION=1.1.0 -t platform-demo-app:1.1.0 app

# 2. Namespace and Secret (never committed, see k8s/secret.example.yaml)
kubectl apply -f k8s/base/namespace.yaml
kubectl -n platform-demo create secret generic demo-app-secrets \
  --from-literal=API_TOKEN="$(openssl rand -hex 24)"

# 3. Everything else
kubectl apply -k k8s/base
kubectl -n platform-demo rollout status deploy/demo-app
curl http://<node-ip>:30080/
```

The image has to be available to the cluster: push it to a registry, or load
it into a local cluster (`kind load docker-image`, `k3s ctr images import`).

| Topic | Where | What to look at |
| --- | --- | --- |
| Pods, Deployments, Services | `k8s/base/deployment.yaml`, `service.yaml` | 3 replicas behind a NodePort Service |
| Replica scaling | `kubectl scale`, `k8s/overlays/autoscaling` | manual scaling, and an HPA (3 to 6 replicas at 60% CPU) |
| Rolling updates | `strategy` in the Deployment | `maxSurge: 1`, `maxUnavailable: 0`, readiness gate, graceful shutdown |
| Rollback | `kubectl rollout undo` | previous ReplicaSets are kept (`revisionHistoryLimit`) |
| ConfigMaps | `configMapGenerator` in `kustomization.yaml` | a changed value creates a new ConfigMap and rolls the pods |
| Secrets | `secretKeyRef` in the Deployment | created out-of-band; the app only reports whether it is set |
| Monitoring | probes, requests/limits, `kubectl top`, `/metrics` | metrics-server feeds `kubectl top` and the HPA |
| Hardening | `securityContext` | non-root, read-only filesystem, no capabilities, seccomp |
| Availability | `pdb.yaml` | a node drain removes at most one pod at a time |

### Zero-downtime rolling update, measured

`scripts/watch-rollout.sh` calls the Service ten times per second while the
image is replaced:

```
$ kubectl -n platform-demo set image deploy/demo-app app=platform-demo-app:1.1.0
$ scripts/watch-rollout.sh http://localhost:30080 55
requests ok: 155, failed: 0
  version 1.1.0 answered 80 times
  version 1.0.0 answered 75 times
```

Both versions answered during the transition and no request failed. Three
things make that true, and removing any of them produces errors:

1. `maxUnavailable: 0` – an old pod is only removed once a new one is ready;
2. the readiness probe – a new pod receives traffic only when it can serve;
3. graceful shutdown – on `SIGTERM` the app fails its readiness check and keeps
   serving for a few seconds, so it leaves the Service's endpoints before it
   stops ([`app/server.js`](app/server.js)).

The full session (scale, rollout, rollback, autoscaling, monitoring) is in
[docs/runbook.md](docs/runbook.md).

## The application

[`app/`](app) is a dependency-free Node.js service whose only purpose is to
make the platform observable: `/` returns the pod name and version, `/healthz`
and `/readyz` back the probes, `/metrics` exposes counters, `/work?ms=` burns
CPU to trigger the autoscaler.

```bash
cd app && npm test
```

## Limits

- Single node: the control plane and the workloads share one EC2 instance, so
  this demonstrates orchestration, not high availability. A production setup
  would use a managed control plane (EKS) and several nodes across zones.
- The Service is a NodePort; there is no ingress controller or TLS.
- Terraform state is local by default.
- Monitoring is the built-in level (metrics-server, probes, events); no
  Prometheus/Grafana stack.

## License

MIT
