"""Kratos signup load test.

Drives the browser registration flow the way the Chapter-Website and the hurl
scenarios do: ``GET /self-service/registration/browser`` with
``Accept: application/json`` to obtain a flow and its CSRF cookie, then
``POST /self-service/registration?flow=<id>`` with ``method: password``.

Two arrival models, chosen through environment variables:

``LOAD_MODE=closed``
    Every user signs up back-to-back. The user count (``-u``) is the fixed
    concurrency, which by Little's law is also the number of in-flight
    argon2 hashes inside Kratos.

``LOAD_MODE=open``
    Users sleep an exponential gap between signups so the aggregate arrival
    process is Poisson at ``LOAD_RATE`` signups per second. The user count
    only caps how far in-flight work can pile up when Kratos falls behind.

Example, against a port-forwarded Kratos public service::

    LOAD_MODE=open LOAD_RATE=2 uvx locust -f tests/load/locustfile.py \\
        --headless -u 20 -r 20 -t 60s -H http://127.0.0.1:4433 --csv out

Read the peak with ``mise run k8s:measure`` afterwards. See README.md here for
what the numbers mean and infra-plans/KRATOS_MEMORY_LOAD_STUDY.md for the
study that produced them.
"""

from __future__ import annotations

import os
import random
import uuid

import gevent
from locust import HttpUser, constant, task

MODE = os.environ.get("LOAD_MODE", "closed")
RATE = float(os.environ.get("LOAD_RATE", "1"))
SEED = int(os.environ.get("LOAD_SEED", "1"))
DOMAIN = os.environ.get("LOAD_EMAIL_DOMAIN", "ucmerced.edu")
CA_BUNDLE = os.environ.get("LOAD_CA_BUNDLE", "")

_rng = random.Random(SEED)  # noqa: S311 - load pacing, not security


def exp_wait(user: HttpUser) -> float:
    """Exponential gap so that, summed over all users, arrivals are Poisson(RATE)."""
    users = max(int(user.environment.parsed_options.num_users or 1), 1)
    return _rng.expovariate(RATE / users)


class Signup(HttpUser):
    """One browser registering one fresh identity per task."""

    wait_time = exp_wait if MODE == "open" else constant(0)

    def on_start(self) -> None:
        """Trust the given CA, then stagger the first signup; Poisson has no burst at t=0."""
        if CA_BUNDLE:
            # Locust's session ignores REQUESTS_CA_BUNDLE (trust_env is off), so set it here.
            self.client.verify = CA_BUNDLE
        if MODE == "open":
            gevent.sleep(exp_wait(self))

    @task
    def register(self) -> None:
        """Init a registration flow, then submit a password signup."""
        self.client.cookies.clear()
        with self.client.get(
            "/self-service/registration/browser",
            headers={"Accept": "application/json"},
            name="init flow",
            catch_response=True,
        ) as init:
            if init.status_code != 200:
                init.failure(f"init {init.status_code}")
                return
            flow = init.json()

        csrf = next(
            node["attributes"]["value"]
            for node in flow["ui"]["nodes"]
            if node["attributes"].get("name") == "csrf_token"
        )
        uid = uuid.uuid4().hex
        body = {
            "method": "password",
            "csrf_token": csrf,
            "password": f"Correct-Horse-{uid[:10]}-Battery",
            "traits": {
                "email": f"load-{uid}@{DOMAIN}",
                "name": "Load Test",
                "display_name": "load",
            },
        }
        with self.client.post(
            f"/self-service/registration?flow={flow['id']}",
            json=body,
            headers={"Accept": "application/json"},
            name="submit password",
            catch_response=True,
        ) as submit:
            if submit.status_code != 200 or "session" not in submit.text:
                submit.failure(f"submit {submit.status_code} {submit.text[:120]}")
