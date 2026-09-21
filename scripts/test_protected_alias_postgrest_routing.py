#!/usr/bin/env python3
"""Real PostgREST transport proof for Database #677 (Foundry #60, workspace #1432).

The protected Time-alias v2 lifecycle is delivered over PostgREST, but the SQL
suites drive the functions through a direct connection. Two deployed transport
facts therefore have to be proven over real HTTP against the loopback stack:

1. Transport capability. The official CLI OAuth identity carries a JWT with a
   `client_id` claim, so `api.oauth_client_pre_request()` decides every RPC
   route before the function runs. The deployed official class initially lacks
   CLI-ALIAS-02, so the protected read route is refused with SQLSTATE 42501 /
   "OAuth client is not authorized for this API route" (the hosted RED). After
   the additive repair the same request reaches the application's own
   null-request refusal with zero writes.

2. Routing profile. The one-shot admission callback posts to
   `/rest/v1/rpc/cmd_dataset_alias_execution_execute_v2`. With no
   `Content-Profile` header PostgREST resolves the first schema of the deployed
   profile list (`public`) and answers 404 / PGRST202 after the single attempt
   has been consumed. With `Content-Profile: api` the exact same request shape
   (service key, nonce-bound body) reaches the intended service-only routine.

The probe refuses to run outside the loopback stack, creates only its own
synthetic registry clients through the service facade, disables them again
before exit, and never touches business data or any remote environment.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]

OFFICIAL_CLIENT_ID = "issue-677-postgrest-official-cli"
PRIOR_OFFICIAL_CLASS = [
    "CLI-RPC-01",
    "DB-CORE-READ-01",
    "DB-CORE-WRITE-01",
    "EDGE-BUNDLE-01",
    "NX-CORE-02",
]
REPAIRED_OFFICIAL_CLASS = sorted([*PRIOR_OFFICIAL_CLASS, "CLI-ALIAS-02"])
ACTOR_ID = "56600000-0000-4000-8000-000000000677"
LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "[::1]"}
READ_ROUTE = "cmd_dataset_alias_execution_read_v2"
EXECUTE_ROUTE = "cmd_dataset_alias_execution_execute_v2"


class ProbeFailure(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProbeFailure(message)


def b64url(payload: bytes) -> str:
    return base64.urlsafe_b64encode(payload).rstrip(b"=").decode("ascii")


def sign_jwt(secret: str, claims: dict) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    signing_input = ".".join(
        [
            b64url(json.dumps(header, separators=(",", ":")).encode("utf-8")),
            b64url(json.dumps(claims, separators=(",", ":")).encode("utf-8")),
        ]
    )
    signature = hmac.new(
        secret.encode("utf-8"), signing_input.encode("ascii"), hashlib.sha256
    ).digest()
    return signing_input + "." + b64url(signature)


def resolve_local_stack() -> dict:
    output = subprocess.run(
        ["supabase", "status", "--output", "env"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    values: dict[str, str] = {}
    for line in output.splitlines():
        match = re.fullmatch(r'([A-Z0-9_]+)="(.*)"', line.strip())
        if match:
            values[match.group(1)] = match.group(2)
    return values


def post_json(
    api_url: str,
    route: str,
    headers: dict[str, str],
    body: dict | None,
) -> tuple[int, dict]:
    request = urllib.request.Request(
        f"{api_url}/rest/v1/rpc/{route}",
        data=json.dumps(body).encode("utf-8") if body is not None else b"{}",
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8")
        try:
            return error.code, json.loads(raw)
        except json.JSONDecodeError:
            raise ProbeFailure(
                f"route {route} returned a non-JSON {error.code} response"
            ) from error


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api-url", default=None)
    parser.add_argument("--service-key", default=None)
    parser.add_argument("--anon-key", default=None)
    parser.add_argument("--jwt-secret", default=None)
    args = parser.parse_args()

    stack = resolve_local_stack()
    api_url = args.api_url or stack.get("API_URL", "")
    service_key = args.service_key or stack.get("SERVICE_ROLE_KEY", "")
    anon_key = args.anon_key or stack.get("ANON_KEY", "")
    jwt_secret = args.jwt_secret or stack.get("JWT_SECRET", "")

    require(api_url.startswith("http://"), f"API_URL must be http: {api_url!r}")
    require(
        api_url.removeprefix("http://").split(":")[0].split("/")[0] in LOOPBACK_HOSTS,
        f"refusing to probe a non-loopback stack: {api_url!r}",
    )
    require(service_key and anon_key and jwt_secret, "local stack keys are incomplete")

    service_headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
        "Content-Profile": "api",
    }
    actor_token = sign_jwt(
        jwt_secret,
        {
            "iss": "supabase-demo",
            "role": "authenticated",
            "sub": ACTOR_ID,
            "client_id": OFFICIAL_CLIENT_ID,
            "exp": 4102444800,
        },
    )
    actor_headers = {
        "apikey": anon_key,
        "Authorization": f"Bearer {actor_token}",
        "Content-Type": "application/json",
        "Content-Profile": "api",
    }

    def configure_client(capabilities: list[str]) -> None:
        status, body = post_json(
            api_url,
            "svc_oauth_client_configure",
            service_headers,
            {
                "p_client_id": OFFICIAL_CLIENT_ID,
                "p_client_kind": "cli",
                "p_enabled": True,
                "p_capability_ids": capabilities,
            },
        )
        require(status == 200, f"service facade provisioning failed: {status} {body}")
        require(body.get("ok") is True, f"service facade refused provisioning: {body}")

    try:
        # 1. The deployed prior official class is refused on real HTTP exactly as
        #    the hosted official OAuth session was.
        configure_client(PRIOR_OFFICIAL_CLASS)
        status, body = post_json(api_url, READ_ROUTE, actor_headers, {"p_request_id": None})
        require(
            status in (401, 403),
            f"prior official class was not refused by the transport: {status} {body}",
        )
        require(
            body.get("code") == "42501"
            and body.get("message") == "OAuth client is not authorized for this API route",
            f"prior official class was refused with an unexpected payload: {body}",
        )

        # 2. The additive CLI-ALIAS-02 repair turns the same HTTP request green and
        #    the admitted null read reaches the application's own refusal.
        configure_client(REPAIRED_OFFICIAL_CLASS)
        status, body = post_json(api_url, READ_ROUTE, actor_headers, {"p_request_id": None})
        require(status == 200, f"repaired official class did not route: {status} {body}")
        require(
            body.get("code") == "ALIAS_EXECUTION_READ_INVALID_REQUEST"
            and body.get("status") == 400,
            f"repaired official class did not reach the application refusal: {body}",
        )

        # 3. The service-only executor callback stays unreachable over HTTP even
        #    for the repaired official OAuth actor.
        status, body = post_json(
            api_url,
            EXECUTE_ROUTE,
            actor_headers,
            {"p_request_id": str(uuid.uuid4()), "p_nonce": "0" * 64},
        )
        require(
            status in (401, 403) and body.get("code") == "42501",
            f"service-only callback was reachable to the OAuth actor: {status} {body}",
        )

        # 4. The default profile is `public`: the queued callback shape without an
        #    explicit content profile dies as 404 / PGRST202 before the api routine.
        default_headers = {
            "apikey": service_key,
            "Authorization": f"Bearer {service_key}",
            "Content-Type": "application/json",
        }
        status, body = post_json(
            api_url,
            EXECUTE_ROUTE,
            default_headers,
            {"p_request_id": str(uuid.uuid4()), "p_nonce": "0" * 64},
        )
        require(
            status == 404 and body.get("code") == "PGRST202",
            f"default profile did not resolve to public: {status} {body}",
        )

        # 5. The explicit api content profile routes the same request shape to the
        #    intended service-only routine, which refuses it as an application
        #    contract violation rather than a router lookup failure.
        status, body = post_json(
            api_url,
            EXECUTE_ROUTE,
            service_headers,
            {"p_request_id": str(uuid.uuid4()), "p_nonce": "0" * 64},
        )
        require(status == 200, f"api profile callback did not route: {status} {body}")
        require(
            body.get("code") == "ALIAS_EXECUTION_REQUEST_NOT_FOUND",
            f"api profile callback did not reach the executor contract: {body}",
        )

        # 6. An ordinary actor session cannot execute the service-only callback
        #    over HTTP either.
        anon_headers = {
            "apikey": anon_key,
            "Authorization": f"Bearer {anon_key}",
            "Content-Type": "application/json",
            "Content-Profile": "api",
        }
        status, body = post_json(
            api_url,
            EXECUTE_ROUTE,
            anon_headers,
            {"p_request_id": str(uuid.uuid4()), "p_nonce": "0" * 64},
        )
        require(
            status in (401, 403) and body.get("code") == "42501",
            f"actor session reached the service-only callback: {status} {body}",
        )
    finally:
        # Disable the synthetic registry client through the audited service facade;
        # the disposable loopback database keeps only its append-only audit history.
        try:
            status, body = post_json(
                api_url,
                "svc_oauth_client_configure",
                service_headers,
                {
                    "p_client_id": OFFICIAL_CLIENT_ID,
                    "p_client_kind": "cli",
                    "p_enabled": False,
                    "p_capability_ids": REPAIRED_OFFICIAL_CLASS,
                },
            )
            if status != 200 or body.get("ok") is not True:
                print(
                    f"warning: synthetic client cleanup failed: {status} {body}",
                    file=sys.stderr,
                )
        except Exception as error:  # noqa: BLE001 - cleanup must not mask the probe
            print(f"warning: synthetic client cleanup failed: {error}", file=sys.stderr)

    print(
        "PASS: real PostgREST transport refuses the prior official class, admits the "
        "CLI-ALIAS-02 repair into the application null-request refusal, keeps the "
        "service-only callback unreachable to actors, and routes the explicit api "
        "content profile to the intended executor routine while the default public "
        "profile still fails as PGRST202"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProbeFailure as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        raise SystemExit(1) from failure
