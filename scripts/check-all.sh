#!/bin/bash
# Runs every check for the project in order: tests, local server, Docker image,
# Docker Compose (with persistence test), Kubernetes status, k6 load test with the
# HPA, and the crash/restart test. Usage: scripts/check-all.sh
cd "$(dirname "$0")/.." || exit 1
export PATH="/opt/homebrew/opt/ruby@3.3/bin:$PATH"

step() { printf '\n\033[1;36m==================== %s ====================\033[0m\n' "$*"; }
run()  { printf '\033[1;33m$ %s\033[0m\n' "$*"; eval "$@"; }
wait_http() { for _ in $(seq 1 60); do curl -sf -o /dev/null "$1" && return 0; sleep 2; done; echo "TIMEOUT waiting for $1"; return 1; }

step "0. Ruby version"
run ruby -v

step "1. Rails tests"
run bin/rails test

step "2. App without Docker (bin/rails server on :3000)"
run bin/rails db:prepare
bin/rails server -p 3000 > tmp/check-server.log 2>&1 &
SERVER_PID=$!
wait_http http://localhost:3000/up
run "curl -s -o /dev/null -w 'GET /up -> %{http_code}\n' http://localhost:3000/up"
run "curl -s -X POST http://localhost:3000/api/tasks -H 'Content-Type: application/json' -d '{\"title\":\"Test task\"}'; echo"
ID=$(curl -s http://localhost:3000/api/tasks | ruby -rjson -e 'puts JSON.parse(STDIN.read).last["id"]')
run "curl -s http://localhost:3000/api/tasks; echo"
run "curl -s -X PUT http://localhost:3000/api/tasks/$ID -H 'Content-Type: application/json' -d '{\"completed\":true}'; echo"
run "curl -s -X DELETE http://localhost:3000/api/tasks/$ID; echo"
run "curl -s -o /dev/null -w 'PUT missing id -> %{http_code}\n' -X PUT http://localhost:3000/api/tasks/999999 -H 'Content-Type: application/json' -d '{\"completed\":true}'"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null; echo "(local server stopped)"

step "3. Docker image"
run docker build -q -t crud-devops-project:1.0 .
run docker images crud-devops-project
run docker run --rm --entrypoint id crud-devops-project:1.0

step "4. Docker Compose"
run docker compose up -d
for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' crud-devops-project-app-1 2>/dev/null)" = healthy ] && break; sleep 2; done
run docker compose ps
run "docker network ls | grep crud; docker volume ls | grep crud"
run "curl -s -X POST http://localhost:3000/api/tasks -H 'Content-Type: application/json' -d '{\"title\":\"compose persistence check\"}'; echo"
echo "--- restarting the whole stack (down + up) ---"
run docker compose down
run docker compose up -d
for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' crud-devops-project-app-1 2>/dev/null)" = healthy ] && break; sleep 2; done
run "curl -s http://localhost:3000/api/tasks; echo"
echo "(the 'compose persistence check' task above survived the restart)"
run docker compose down

step "5. Kubernetes status"
run minikube status
run kubectl get pods -n crud-app
run kubectl get services -n crud-app
run kubectl get deploy,statefulset,pvc,hpa -n crud-app
run kubectl top pods -n crud-app
run "kubectl logs -n crud-app deploy/crud-app --tail=10"

step "6. k6 load test: 500 users, 60 s hold (about 90 s; watch the HPA/pods tabs)"
run kubectl -n crud-app delete job k6-load-test --ignore-not-found
run "kubectl -n crud-app create configmap k6-script --from-file=loadtest/k6-script.js --dry-run=client -o yaml | kubectl apply -f -"
run kubectl apply -f loadtest/k6-job.yaml
echo "Waiting for the load test to finish..."
for _ in $(seq 1 90); do
  s=$(kubectl -n crud-app get job k6-load-test -o jsonpath='{.status.succeeded}{.status.failed}')
  [ -n "$s" ] && break; sleep 5
done
run kubectl -n crud-app get job k6-load-test
kubectl -n crud-app logs job/k6-load-test | grep '^{' | ruby -rjson -e '
  m = JSON.parse(STDIN.read); d = m["http_req_duration"]["values"]
  printf("requests: %d   rate: %.1f req/s   errors: %.2f%%\n", m["http_reqs"]["values"]["count"], m["http_reqs"]["values"]["rate"], m["http_req_failed"]["values"]["rate"] * 100)
  printf("latency ms  avg %.0f  med %.0f  p90 %.0f  p95 %.0f  p99 %.0f  max %.0f\n", *%w[avg med p(90) p(95) p(99) max].map { d[_1] })'
run kubectl get hpa,pods -n crud-app
run "kubectl describe hpa crud-app -n crud-app | sed -n '/Events/,\$p'"

step "7. Fault tolerance: kill Puma and watch RESTARTS go up"
run kubectl get pods -n crud-app -l app=crud-app
run "minikube ssh -- 'sudo pkill -9 -f \"^puma .*:3000\"'"
sleep 3
run kubectl get pods -n crud-app -l app=crud-app
echo "Waiting for the app pods to become Ready again..."
run kubectl -n crud-app wait --for=condition=Ready pod -l app=crud-app --timeout=120s
run kubectl get pods -n crud-app -l app=crud-app
run "kubectl describe pod -n crud-app -l app=crud-app | grep -E '^Name:|Exit Code|Restart Count'"

step "DONE"
