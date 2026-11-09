// k6 load test for the task manager.
// 500 concurrent virtual users held for 60 s (plus ramp up/down).
// Each user lists tasks and occasionally creates + deletes one, with think time.
//
// Run in-cluster:  see loadtest/README.md   (BASE_URL defaults to the k8s Service)
// Run locally:     k6 run -e BASE_URL=http://localhost:3000 loadtest/k6-script.js
import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://crud-app.crud-app.svc.cluster.local";

export const options = {
  scenarios: {
    users: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "15s", target: 500 }, // ramp up
        { duration: "60s", target: 500 }, // hold 500 concurrent users
        { duration: "10s", target: 0 },   // ramp down
      ],
      gracefulRampDown: "10s",
    },
  },
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<1000"],
  },
};

const JSON_HEADERS = { headers: { "Content-Type": "application/json" } };

export default function () {
  const list = http.get(`${BASE_URL}/api/tasks`, { tags: { name: "GET /api/tasks" } });
  check(list, { "list 200": (r) => r.status === 200 });

  if (Math.random() < 0.1) {
    const created = http.post(
      `${BASE_URL}/api/tasks`,
      JSON.stringify({ title: `k6 task ${__VU}-${__ITER}` }),
      Object.assign({ tags: { name: "POST /api/tasks" } }, JSON_HEADERS),
    );
    check(created, { "create 201": (r) => r.status === 201 });
    if (created.status === 201) {
      const id = created.json("id");
      const del = http.del(`${BASE_URL}/api/tasks/${id}`, null, { tags: { name: "DELETE /api/tasks/:id" } });
      check(del, { "delete 200": (r) => r.status === 200 });
    }
  }

  sleep(0.5 + Math.random()); // 0.5-1.5 s think time
}

export function handleSummary(data) {
  return {
    stdout: JSON.stringify(data.metrics, null, 0) + "\n",
  };
}
