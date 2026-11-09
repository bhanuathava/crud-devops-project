# crud-devops-project — Containerisation, Kubernetes, Load and Fault-Tolerance Report

All numbers below were measured on 2026-11-09 on a MacBook (Apple Silicon) with Docker Desktop
(6 CPUs, 3.8 GiB) and minikube (docker driver, 4 CPUs, 3000 MiB, metrics-server enabled).
Raw output for every claim is in [`docs/evidence/`](evidence/).

---

## 1. What the app needs to run

Found by running it without Docker first (`bin/rails test` → 9 runs, 26 assertions, 0 failures;
`bin/rails server` → page at http://localhost:3000, `/up` returns 200).

| Requirement | Value | Where it is used |
|---|---|---|
| Port | `3000` (`PORT`) | `EXPOSE 3000`, Compose `3000:3000`, `containerPort: 3000` |
| Database | MySQL, via `DB_HOST`, `DB_PORT`, `DB_USERNAME`, `DB_PASSWORD`, `DB_NAME` | Compose env, k8s ConfigMap + Secret |
| Secrets | `RAILS_MASTER_KEY` (contents of `config/master.key`, never committed) | `.env` (git-ignored), k8s Secret |
| Schema | `bin/rails db:prepare` (creates DB if missing, runs pending migrations, idempotent) | `bin/docker-entrypoint`, runs on every start |
| Concurrency | `WEB_CONCURRENCY` workers × `RAILS_MAX_THREADS` threads | Compose / ConfigMap: 2 × 5 |
| Health | `GET /up` | Compose healthcheck, k8s probes |

---

## 2. Dockerfile (Deliverable 1)

[`Dockerfile`](../Dockerfile) has two stages:

1. **`ruby:3.3` (build)** — the full image has `gcc`, `make` and the MySQL/MariaDB headers, so
   `bundle install` can compile the native `mysql2` extension. Gems are installed with
   `BUNDLE_DEPLOYMENT=1` and `BUNDLE_WITHOUT=development:test`; `Gemfile`/`Gemfile.lock` are
   copied before the app source so the gem layer stays cached when only code changes.
   Bootsnap's cache is precompiled for faster boots.
2. **`ruby:3.3-slim` (runtime)** — no compilers. It installs only `libmariadb3` (provides the
   `libmysqlclient` shared library the compiled `mysql2` gem links against at runtime) and `curl`
   (for the healthcheck). Gems and app are copied from stage 1 with `COPY --from=build`.

Other points checked against the brief:

- Runs as non-root `rails` (uid/gid 1000) — verified: `id` → `uid=1000(rails)`.
- `EXPOSE 3000`; `CMD ["bundle","exec","puma","-C","config/puma.rb"]` starts Puma.
- `ENTRYPOINT bin/docker-entrypoint` runs `rails db:prepare` and then `exec`s Puma, so Puma is
  PID 1 and receives `SIGTERM` directly from Docker/Kubernetes.
- `.dockerignore` keeps `.git`, `config/*.key`, `.env*`, logs, tests and k8s files out of the image.
- Result: image builds cleanly, **448 MB**, and `require "mysql2"` succeeds in the slim stage.

---

## 3. Docker Compose

[`docker-compose.yaml`](../docker-compose.yaml):

- `db`: official `mysql:8.4`, data on the named volume **`crud-mysql-data`**, healthcheck with
  `mysqladmin ping`.
- `app`: built from the Dockerfile, `depends_on: db: condition: service_healthy`, healthcheck
  `curl -f http://localhost:3000/up`.
- Both on the named network **`crud-app-net`**. Compose runs an embedded DNS server on that
  network, so the app reaches MySQL at **`DB_HOST=db`** — the service name.
- `DB_*` and `RAILS_MASTER_KEY` come from a git-ignored `.env` (template: `.env.example`).
  Compose refuses to start if a required secret is missing (`${VAR:?}`).
- Database is created/migrated at start by the entrypoint (`db:prepare`).

**Persistence test:** `docker compose up -d` → both containers `healthy` → `POST /api/tasks
{"title":"persist me"}` → `docker compose down` (containers and network removed) →
`docker compose up -d` → `GET /api/tasks` still returned `[{"id":1,"title":"persist me",...}]`.

---

## 4. Kubernetes on minikube (Deliverable 2)

Manifests in [`k8s/`](../k8s/), all in namespace `crud-app`:

| File | Contents |
|---|---|
| `namespace.yaml` | Namespace `crud-app` |
| `configmap.yaml` | `DB_HOST=mysql`, `DB_PORT`, `DB_USERNAME`, `DB_NAME`, `RAILS_MAX_THREADS=5`, `WEB_CONCURRENCY=2` |
| `secret.example.yaml` | Template only; the real Secret is created with `kubectl create secret` from `.env` and `config/master.key` |
| `mysql.yaml` | MySQL 8.4 **StatefulSet** with a 1 Gi PVC (`volumeClaimTemplates`) and a headless Service `mysql` |
| `deployment.yaml` | `apps/v1` Deployment `crud-app`, `replicas: 1`, selector `app: crud-app` = template label |
| `service.yaml` | `NodePort` Service, port 80 → container 3000, nodePort 30080 |
| `hpa.yaml` | HorizontalPodAutoscaler, 1–4 replicas |

Deployment details:

- **Resources:** requests `cpu: 250m, memory: 256Mi`; limits `cpu: 1, memory: 512Mi`.
  Requests are what the scheduler reserves and what HPA percentages are measured against; the
  limits cap a runaway pod. Peak memory seen under load was 271 MiB (`memory.peak`), so 512 Mi
  leaves headroom for two Puma workers.
- **Probes** (all `httpGet /up` on port 3000):
  - `startupProbe` — every 5 s, up to 24 failures (2 min) so `db:prepare` + boot is not killed.
  - `readinessProbe` — every 5 s, 3 failures → pod removed from Service endpoints (no traffic).
  - `livenessProbe` — every 10 s, timeout 3 s, 3 failures → container restarted.
- `securityContext.runAsNonRoot: true`, uid 1000; `imagePullPolicy: IfNotPresent` because the
  image is loaded into minikube rather than pulled from a registry.

**Deploying:**

```bash
minikube start --driver=docker --cpus=4 --memory=3000 --addons=metrics-server
minikube image load crud-devops-project:1.0
kubectl apply -f k8s/namespace.yaml
kubectl -n crud-app create secret generic crud-app-secrets \
  --from-literal=DB_ROOT_PASSWORD=... --from-literal=DB_PASSWORD=... \
  --from-file=RAILS_MASTER_KEY=config/master.key
kubectl apply -f k8s/configmap.yaml -f k8s/mysql.yaml
kubectl -n crud-app rollout status statefulset/mysql
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml -f k8s/hpa.yaml
minikube service crud-app -n crud-app --url
```

**Redeploy from scratch (verified).** I deleted the `crud-app` namespace and ran the commands
above in order. All pods were Ready in ~25 s, `db:prepare` created the schema in an empty
database (`SHOW TABLES` → `tasks`, `schema_migrations`, `ar_internal_metadata`) and
`GET /api/tasks` returned `[]` ([`evidence/08-fresh-redeploy.txt`](evidence/08-fresh-redeploy.txt)).

> **minikube gotcha:** the first attempt still showed the old tasks. minikube's hostpath
> provisioner stores data under `/tmp/hostpath-provisioner/<namespace>/<pvc-name>`, and deleting
> the namespace left the old PersistentVolume and its folder behind, so the new claim (same
> namespace + name) mounted the old data. For a truly empty database:
>
> ```bash
> kubectl delete namespace crud-app
> kubectl get pv            # delete any leftover crud-app volume with: kubectl delete pv <name>
> minikube ssh -- 'sudo rm -rf /tmp/hostpath-provisioner/crud-app'
> ```
>
> This is also a useful reminder of why the StatefulSet + PVC matter: data outlives the pods.

`kubectl get pods` / `kubectl get services` output: [`evidence/01-k8s-pods-services.txt`](evidence/01-k8s-pods-services.txt)
(app and `mysql-0` both `1/1 Running`, `crud-app` NodePort `80:30080/TCP`, PVC `Bound`).

**Web page test on Kubernetes.** On the fresh deployment, through `kubectl port-forward
svc/crud-app 8080:80`, every control on the page was exercised and the database checked after
each step ([`evidence/09-ui-click-through.txt`](evidence/09-ui-click-through.txt)): an empty
title is blocked by the browser; Create (button and Enter key); tick and untick the checkbox
(progress bar 0% → 50% → 0%); edit the title + Update; empty title + Update → "Could not update
task" (API 400, data unchanged); Delete. No JavaScript errors.

### Why NodePort

| Type | Reachable from | Fit here |
|---|---|---|
| ClusterIP | Inside the cluster only | Right for MySQL (only the app talks to it), but the app must be reachable from the host browser |
| **NodePort** | `<node-IP>:30080` from outside | **Chosen.** minikube is a single node with no cloud provider; NodePort exposes the app with no extra components, and `minikube service --url` gives a working URL |
| LoadBalancer | External IP from a cloud LB | Needs a cloud controller. On minikube it stays `<pending>` unless `minikube tunnel` is running, so it only emulates what a cloud gives you |

In a real cloud deployment I would switch the app Service to `ClusterIP` behind an Ingress
(one LB, TLS, path routing) or to `LoadBalancer`; NodePort's high ports and per-node exposure
are not what you want facing the internet.

---

## 5. Load test (Deliverable 3)

**Tool:** k6. Script: [`loadtest/k6-script.js`](../loadtest/k6-script.js), run as an in-cluster Job
([`loadtest/k6-job.yaml`](../loadtest/k6-job.yaml)) against `http://crud-app.crud-app.svc.cluster.local`.
Running k6 inside the cluster avoids `kubectl port-forward` / `minikube service` tunnels,
which would themselves become the bottleneck at 500 users.

**Profile:** ramp 0 → **500 VUs** over 15 s, **hold 500 for 60 s**, ramp down 10 s.
Each user: `GET /api/tasks`; 10% of iterations also `POST` a task then `DELETE` it;
then 0.5–1.5 s think time. Thresholds: error rate < 1%, p95 < 1 s.

```bash
kubectl -n crud-app create configmap k6-script --from-file=loadtest/k6-script.js
kubectl apply -f loadtest/k6-job.yaml
kubectl -n crud-app logs -f job/k6-load-test
```

### Results — 1 replica, 2 workers × 5 threads (no HPA)

| Metric | Value |
|---|---|
| Max concurrent users | 500 |
| Total requests | 32,571 |
| Throughput | **377.8 req/s** (315.6 iterations/s) |
| Error rate (`http_req_failed`) | **0.00%** (all 32,571 checks passed) |
| Latency avg / median | 296 ms / 98.5 ms |
| p90 / **p95** / p99 | 710 ms / **1,172 ms** / 3,112 ms |
| Max | 4,151 ms |
| Thresholds | error-rate ✅; **p95 < 1 s ❌** (k6 exited 99, which is why the Job shows `Failed`) |

Pod resources ([`evidence/03-kubectl-top-during-load.txt`](evidence/03-kubectl-top-during-load.txt),
[`evidence/04-cgroup-cpu-throttling.txt`](evidence/04-cgroup-cpu-throttling.txt)):

| | Idle | Under load |
|---|---|---|
| `crud-app` CPU | 42m | **685m** (1-minute average; limit is 1000m) |
| `crud-app` memory | 151 Mi | 236 Mi (cgroup peak 271 Mi; limit 512 Mi) |
| `mysql-0` CPU / memory | 21m / 448 Mi | 138m / 462 Mi |
| CFS throttling of `crud-app` | — | throttled in **538 of 1,407** 100 ms periods (38%), **15.8 s** total |

### Relating this to Puma

- The pod runs **2 workers × 5 threads = 10 requests in flight** at once. 500 users with ~1 s
  think time offer ~385 req/s; the app delivered 378 req/s with no errors, so it kept up on
  throughput — but every request beyond the 10 being processed waits in Puma's/the kernel's
  accept queue. That queueing is the gap between the 98 ms median and the 1.2 s p95 / 3.1 s p99.
- The real ceiling is **CPU, not threads**. Ruby's GVL means each worker runs Ruby code on one
  core at a time; 2 workers could use ~2 cores, but the container limit is 1 core. The 1-minute
  average (685m) hides bursts: the cgroup shows the pod hit its quota and was throttled in 38%
  of periods. Adding threads would not help (they would contend for the same throttled core);
  more CPU per pod, or more pods, would.
- The DB pool is sized per worker (`RAILS_MAX_THREADS=5` connections per worker, 10 total),
  and MySQL stayed at ~14% of a core, so the database was not the bottleneck.
- Memory is comfortable: `ps` on the node showed ~105 MiB RSS per worker (shared pages counted in each);
  the container total peaked at 271 MiB, well under the 512 Mi limit.

**Tuning options**, in order of what I'd try: raise the CPU limit to 2 to match 2 workers (or
drop to 1 worker with the current 1-CPU limit — workers should roughly equal cores); scale
horizontally (below); keep threads at 3–5, since this workload is short DB queries and more
threads mainly add GVL contention.

### Results — same test with the HPA enabled

[`k8s/hpa.yaml`](../k8s/hpa.yaml): `autoscaling/v2`, **min 1 / max 4** replicas,
**target 70% average CPU of the request** (≈175m per pod). Scale-up: no stabilisation window,
at most +2 pods per 15 s, so it reacts within one metrics interval. Scale-down: 120 s
stabilisation and −1 pod per 60 s, so a short lull between bursts doesn't cause flapping.

Timeline ([`evidence/06-hpa-during-load.txt`](evidence/06-hpa-during-load.txt), HPA events):
the HPA went **1 → 2** about 20 s into the ramp-up (CPU 89% of request) and **2 → 4** a minute later
(CPU 377% of request, i.e. ~940m on the original pod).

| Metric | 1 replica, no HPA | HPA (1 → 2 → 4) |
|---|---|---|
| Total requests | 32,571 | 34,043 |
| Throughput | 377.8 req/s | 395.9 req/s |
| Error rate | 0.00% | 0.00% |
| Median | 98.5 ms | 132.5 ms |
| p90 | 710 ms | 730 ms |
| **p95** | **1,172 ms** ❌ | **891 ms** ✅ |
| **p99** | **3,112 ms** | **1,128 ms** |
| Max | 4,151 ms | 1,305 ms |

**Third, clean run on a freshly deployed cluster** (HPA idle at 1 replica beforehand, nothing else
running; [`evidence/10-clean-load-test-hpa.txt`](evidence/10-clean-load-test-hpa.txt),
[`evidence/11-k6-raw-clean.txt`](evidence/11-k6-raw-clean.txt)):

| Metric | Clean run, HPA (1 → 2) |
|---|---|
| Total requests | 40,544 |
| Throughput | **470.8 req/s** |
| Error rate | **0.00%** (40,544/40,544 checks passed) |
| Median / avg | 2.3 ms / 67.5 ms |
| p90 / **p95** / p99 | 203 ms / **456 ms** ✅ / 867 ms |
| Max | 1,341 ms |

Here the HPA only went to 2 replicas, and only ~60 s into the test: minikube's metrics-server
reports CPU about once a minute, so the HPA reacts late to a short spike (the
`FailedGetResourceMetric` warnings in its events are from the first minute after deploy, before
any metrics existed — normal). Run-to-run variance on a laptop is large, because k6, MySQL
and the app all share the same 4 minikube CPUs and Docker Desktop's 3.8 GiB, so the
three runs should be read as a range, not exact numbers. All three had 0% errors.

The HPA mostly fixed the tail: p99 fell by ~64% and max by ~69%, and the p95 < 1 s threshold
passed (k6 Job `Complete`). The median rose slightly because new pods start cold and the
extra pods share the same 4 minikube CPUs with MySQL and k6 itself. The gain is partial
because the extra pods only arrived part-way through a 60-second hold; a longer test (or
`minReplicas: 2`) would show more.

**Why CPU only, not memory.** The first version also had a memory target (80% of 256 Mi).
Puma's idle memory is already ~60–90% of that request, and Ruby processes don't return memory
after a burst, so a memory target scales up on boot-time memory and then never lets
the deployment scale back down. It was removed; memory is protected by the 512 Mi limit instead.

**Thresholds I'd use in production:** `minReplicas: 2` (no single point of failure during
restarts, see §6), `maxReplicas` sized to MySQL's `max_connections` (each pod opens
`WEB_CONCURRENCY × RAILS_MAX_THREADS` = 10 connections), CPU target 60–70% of request so
there is headroom while new pods boot (~10 s here), and CPU limit = number of Puma workers so
pods aren't throttled before the HPA reacts.

---

## 6. Fault tolerance (Deliverable 4)

Evidence: [`evidence/05-fault-tolerance.txt`](evidence/05-fault-tolerance.txt).

**Scenario 1 — crash.** SIGKILL the Puma master from the minikube node
(`minikube ssh -- sudo pkill -9 -f "^puma .*:3000"`). The container exited with code 137, the
kubelet restarted it (`restartPolicy: Always`), and **RESTARTS went 0 → 1**. The pod was
`0/1` (not ready, so the Service sent it no traffic) for ~5 s and then `1/1 Running`; data
was intact because it lives in MySQL's PVC.

**Scenario 2 — hang.** Freeze (SIGSTOP) the Puma master and both workers. The process is
still "running", so only a probe can detect it. Events show
`Liveness probe failed: ... context deadline exceeded` and
`Container crud-app failed liveness probe, will be restarted`; **RESTARTS went 1 → 2**.
Detection took ~30 s (3 failures × 10 s); total ~70 s because a stopped process ignores
SIGTERM and the kubelet waits the 30 s `terminationGracePeriodSeconds` before SIGKILL.

What this shows: the liveness probe catches hangs a crash-only check would miss; the
readiness probe stops traffic going to a pod that is booting or unhealthy; the startup probe
prevents a slow `db:prepare` from being mistaken for a hang. With a single replica there is
still a short outage on every restart — the fix for that is `replicas ≥ 2` (or the HPA's
`minReplicas: 2`) plus a PodDisruptionBudget.
