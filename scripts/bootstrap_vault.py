#!/usr/bin/env python3
import argparse
import base64
import json
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse
import urllib.error
import urllib.request


# The TLS contexts are initialized at runtime after Terraform passes the Vault and cluster CAs.
TLS_CONTEXT = None
KUBERNETES_CONTEXT = None


# Emit bootstrap progress in a consistent format for Terraform/local-exec logs.
def log(message):
    print(f"[vault-bootstrap] {message}", flush=True)


# Build an HTTPS context that validates the Vault CA chain while tolerating the
# local port-forward hostname mismatch to 127.0.0.1.
def build_tls_context(vault_ca_cert_b64):
    context = ssl.create_default_context()
    context.load_verify_locations(cadata=base64.b64decode(vault_ca_cert_b64).decode("utf-8"))
    context.check_hostname = False
    return context


# Build an HTTPS context for direct Kubernetes API calls using the cluster CA.
def build_kubernetes_context(kubernetes_ca_b64):
    context = ssl.create_default_context()
    context.load_verify_locations(cadata=base64.b64decode(kubernetes_ca_b64).decode("utf-8"))
    return context


# Run shell commands used by the bootstrap flow and surface stdout/stderr on failure.
def run(command, capture_output=True, check=True):
    result = subprocess.run(
        command,
        text=True,
        capture_output=capture_output,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {' '.join(command)}\n"
            f"stdout: {result.stdout}\n"
            f"stderr: {result.stderr}"
        )
    return result


# Send authenticated requests to the Vault HTTP API and normalize expected responses.
def request(method, url, payload=None, token=None, expected_statuses=None, timeout=10):
    data = None
    headers = {}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    if token:
        headers["X-Vault-Token"] = token

    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=timeout, context=TLS_CONTEXT) as response:
            body = response.read().decode("utf-8")
            return response.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        if expected_statuses and exc.code in expected_statuses:
            return exc.code, json.loads(body) if body else {}
        raise RuntimeError(f"Vault API {method} {url} failed with {exc.code}: {body}") from exc
    except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
        raise RuntimeError(f"Vault API {method} {url} timed out or failed to connect: {exc}") from exc


# Ask AWS for a fresh EKS bearer token whenever the bootstrap needs to call Kubernetes directly.
def get_kubernetes_bearer_token(cluster_name, region):
    result = run(
        [
            "aws",
            "eks",
            "get-token",
            "--cluster-name",
            cluster_name,
            "--region",
            region,
        ]
    )
    payload = json.loads(result.stdout)
    token = payload.get("status", {}).get("token")
    if not token:
        raise RuntimeError("aws eks get-token returned an empty bearer token")
    return token


# Call the Kubernetes API directly so bootstrap is less dependent on local kubectl state.
def kubernetes_request(method, kubernetes_host, path, cluster_name, region, payload=None, expected_statuses=None):
    data = None
    headers = {
        "Authorization": f"Bearer {get_kubernetes_bearer_token(cluster_name, region)}",
        "Accept": "application/json",
    }

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    url = f"{kubernetes_host.rstrip('/')}{path}"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=10, context=KUBERNETES_CONTEXT) as response:
            body = response.read().decode("utf-8")
            return response.status, json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        if expected_statuses and exc.code in expected_statuses:
            return exc.code, json.loads(body) if body else {}
        raise RuntimeError(f"Kubernetes API {method} {url} failed with {exc.code}: {body}") from exc


# Reserve a random localhost port for kubectl port-forward to expose Vault temporarily.
def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


# Wait until the first Vault pod exists and reaches Running so the bootstrap can begin.
def wait_for_pod_running(namespace, pod_name, kubernetes_host, cluster_name, region):
    log(f"Waiting for {pod_name} to reach Running phase")
    deadline = time.time() + 900
    pod_name_escaped = urllib.parse.quote(pod_name, safe="")
    namespace_escaped = urllib.parse.quote(namespace, safe="")
    while time.time() < deadline:
        status_code, payload = kubernetes_request(
            "GET",
            kubernetes_host,
            f"/api/v1/namespaces/{namespace_escaped}/pods/{pod_name_escaped}",
            cluster_name,
            region,
            expected_statuses={200, 404},
        )
        phase = payload.get("status", {}).get("phase") if status_code == 200 else None
        if phase == "Running":
            log(f"{pod_name} is Running")
            return
        time.sleep(5)

    raise RuntimeError(f"{pod_name} did not reach Running phase within 15 minutes")


# Open a local tunnel to Vault so bootstrap uses the Kubernetes API as its transport.
def start_port_forward(namespace, pod_name, local_port):
    log(f"Starting kubectl port-forward from {pod_name} to 127.0.0.1:{local_port}")
    process = subprocess.Popen(
        [
            "kubectl",
            "-n",
            namespace,
            "port-forward",
            f"pod/{pod_name}",
            f"{local_port}:8200",
            "--address",
            "127.0.0.1",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return process


# Poll Vault health until the API becomes reachable through the local port-forward.
def wait_for_vault(base_url):
    deadline = time.time() + 600
    while time.time() < deadline:
        try:
            status, _ = request(
                "GET",
                f"{base_url}/v1/sys/health",
                expected_statuses={200, 429, 472, 473, 501, 503},
            )
            if status in {200, 429, 472, 473, 501, 503}:
                log(f"Vault is reachable with health status {status}")
                return
        except Exception:
            pass
        time.sleep(5)

    raise RuntimeError("Vault did not become reachable within 10 minutes")


# After initialization, wait for Vault to finish auto-unseal and elect a leader.
def wait_for_vault_post_init(base_url):
    deadline = time.time() + 300
    while time.time() < deadline:
        try:
            status, _ = request(
                "GET",
                f"{base_url}/v1/sys/health",
                expected_statuses={200, 429, 472, 473, 501, 503},
                timeout=30,
            )
            if status in {200, 429, 472, 473}:
                log(f"Vault is ready for bootstrap operations with health status {status}")
                return
        except Exception:
            pass
        time.sleep(5)

    raise RuntimeError("Vault did not become ready for bootstrap operations within 5 minutes after initialization")


# Load previously persisted initialization data so reruns can reuse the root token safely.
def load_existing_credentials(output_file):
    if not os.path.exists(output_file):
        return None

    with open(output_file, "r", encoding="utf-8") as handle:
        return json.load(handle)


# Load credentials from S3. Returns None if the object does not exist yet.
def load_existing_credentials_s3(s3_uri):
    result = subprocess.run(
        ["aws", "s3", "cp", s3_uri, "-"],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


# Build the credentials payload shared by both local and S3 persistence paths.
def _build_credentials_payload(init_response):
    return {
        "initialized_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "root_token": init_response["root_token"],
        "recovery_keys_b64": init_response.get("recovery_keys_b64", []),
        "recovery_keys_hex": init_response.get("recovery_keys_hex", []),
    }


# Persist the initialization response produced by Vault for later administrative actions.
def persist_credentials(output_file, init_response):
    parent = os.path.dirname(output_file)
    if parent:
        os.makedirs(parent, exist_ok=True)
    payload = _build_credentials_payload(init_response)
    with open(output_file, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
    log(f"Bootstrap credentials saved to {output_file}")


# Upload credentials directly to S3 with SSE-KMS encryption. No local file is written.
def persist_credentials_s3(s3_uri, init_response):
    payload = _build_credentials_payload(init_response)
    content = json.dumps(payload, indent=2) + "\n"
    result = subprocess.run(
        ["aws", "s3", "cp", "-", s3_uri, "--sse", "aws:kms"],
        input=content,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Failed to upload credentials to S3 ({s3_uri}): {result.stderr.strip()}")
    log(f"Bootstrap credentials saved to {s3_uri}")


# Initialize Vault once and return the root token; on reruns, reuse the stored token.
def ensure_initialized(base_url, output_file, output_s3_uri=None):
    status, payload = request("GET", f"{base_url}/v1/sys/init", timeout=30)
    if status != 200:
        raise RuntimeError(f"Unexpected status from /sys/init: {status}")

    if payload.get("initialized"):
        log("Vault is already initialized")
        existing = None
        if output_s3_uri:
            log(f"Loading existing credentials from {output_s3_uri}")
            existing = load_existing_credentials_s3(output_s3_uri)
        if not existing:
            existing = load_existing_credentials(output_file)
        if not existing or not existing.get("root_token"):
            raise RuntimeError(
                "Vault is already initialized, but no credentials file was found at "
                f"{output_s3_uri or output_file}. Restore that file or re-run with a known root token manually."
            )
        status, _ = request(
            "GET",
            f"{base_url}/v1/auth/token/lookup-self",
            token=existing["root_token"],
            expected_statuses={200, 403},
            timeout=30,
        )
        if status == 403:
            raise RuntimeError(
                "Vault is already initialized, but the root token stored in "
                f"{output_s3_uri or output_file} is invalid for the current Vault cluster. "
                "This usually means the bootstrap file and the Raft data are out of sync."
            )
        return existing["root_token"]

    log("Vault is not initialized yet, running initialization")
    _, init_response = request(
        "PUT",
        f"{base_url}/v1/sys/init",
        payload={
            "recovery_shares": 5,
            "recovery_threshold": 3,
        },
        expected_statuses={200},
        timeout=120,
    )
    if output_s3_uri:
        persist_credentials_s3(output_s3_uri, init_response)
    else:
        persist_credentials(output_file, init_response)
    return init_response["root_token"]


# Ensure the kv-v2 secrets engine exists at kv/ for generic secret storage.
def ensure_kv_v2(base_url, token):
    _, mounts = request("GET", f"{base_url}/v1/sys/mounts", token=token)
    kv_mount = mounts.get("kv/")
    if kv_mount:
        if kv_mount.get("type") != "kv" or kv_mount.get("options", {}).get("version") != "2":
            raise RuntimeError("A mount already exists at kv/ but it is not kv-v2")
        log("kv-v2 is already enabled at kv/")
        return

    log("Enabling kv-v2 at kv/")
    request(
        "POST",
        f"{base_url}/v1/sys/mounts/kv",
        payload={"type": "kv", "options": {"version": "2"}},
        token=token,
        expected_statuses={204},
    )


# Request a short-lived reviewer JWT directly from the Kubernetes TokenRequest API.
def create_service_account_token(namespace, service_account, kubernetes_host, cluster_name, region):
    log("Issuing token for Vault service account")
    namespace_escaped = urllib.parse.quote(namespace, safe="")
    service_account_escaped = urllib.parse.quote(service_account, safe="")
    _, payload = kubernetes_request(
        "POST",
        kubernetes_host,
        f"/api/v1/namespaces/{namespace_escaped}/serviceaccounts/{service_account_escaped}/token",
        cluster_name,
        region,
        payload={
            "apiVersion": "authentication.k8s.io/v1",
            "kind": "TokenRequest",
            "spec": {
                "expirationSeconds": 86400,
            },
        },
        expected_statuses={201},
    )
    reviewer_jwt = payload.get("status", {}).get("token")
    if not reviewer_jwt:
        raise RuntimeError("Kubernetes TokenRequest API returned an empty reviewer JWT")
    return reviewer_jwt


# Enable and configure the Kubernetes auth method so workloads can authenticate to Vault.
def ensure_kubernetes_auth(base_url, token, namespace, service_account, kubernetes_host, kubernetes_ca_b64, cluster_name, region):
    _, auth_methods = request("GET", f"{base_url}/v1/sys/auth", token=token)
    if "kubernetes/" not in auth_methods:
        log("Enabling auth method kubernetes")
        request(
            "POST",
            f"{base_url}/v1/sys/auth/kubernetes",
            payload={"type": "kubernetes"},
            token=token,
            expected_statuses={204},
        )
    else:
        log("Auth method kubernetes is already enabled")

    reviewer_jwt = create_service_account_token(
        namespace,
        service_account,
        kubernetes_host,
        cluster_name,
        region,
    )

    kubernetes_ca_cert = base64.b64decode(kubernetes_ca_b64).decode("utf-8")
    log("Configuring Vault Kubernetes auth backend")
    request(
        "POST",
        f"{base_url}/v1/auth/kubernetes/config",
        payload={
            "token_reviewer_jwt": reviewer_jwt,
            "kubernetes_host": kubernetes_host,
            "kubernetes_ca_cert": kubernetes_ca_cert,
        },
        token=token,
        expected_statuses={204},
    )


# Enable the file audit device and send structured audit entries to stdout.
def ensure_audit_stdout(base_url, token):
    _, audit_devices = request("GET", f"{base_url}/v1/sys/audit", token=token)
    existing = audit_devices.get("file/")
    if existing:
        if existing.get("type") != "file":
            raise RuntimeError("An audit device already exists at file/ but it is not of type file")
        log("stdout file audit device is already enabled")
        return

    log("Enabling stdout file audit device with json format")
    request(
        "PUT",
        f"{base_url}/v1/sys/audit/file",
        payload={
            "type": "file",
            "options": {
                "file_path": "stdout",
                "format": "json",
            },
        },
        token=token,
        expected_statuses={204},
    )


# Enable internal client usage counters and keep one year of retained usage data.
def ensure_client_counters(base_url, token):
    log("Configuring Vault client usage counters")
    request(
        "POST",
        f"{base_url}/v1/sys/internal/counters/config",
        payload={
            "enabled": "enable",
            "retention_months": 12,
        },
        token=token,
        expected_statuses={200, 204},
    )


# Ensure the database secrets engine is mounted before configuring any connection.
def ensure_database_secrets_engine(base_url, token):
    _, mounts = request("GET", f"{base_url}/v1/sys/mounts", token=token)
    database_mount = mounts.get("database/")
    if database_mount:
        if database_mount.get("type") != "database":
            raise RuntimeError("A mount already exists at database/ but it is not of type database")
        log("database secrets engine is already enabled at database/")
        return

    log("Enabling database secrets engine at database/")
    request(
        "POST",
        f"{base_url}/v1/sys/mounts/database",
        payload={"type": "database"},
        token=token,
        expected_statuses={204},
    )


# Create or update the PostgreSQL connection used by Vault to issue dynamic credentials.
def ensure_postgres_connection(base_url, token, args):
    log(f"Configuring PostgreSQL connection {args.vault_db_connection_name}")
    request(
        "POST",
        f"{base_url}/v1/database/config/{args.vault_db_connection_name}",
        payload={
            "plugin_name": "postgresql-database-plugin",
            "allowed_roles": args.vault_db_role_name,
            "connection_url": "postgresql://{{username}}:{{password}}@%s:%s/%s?sslmode=disable"
            % (args.postgres_host, args.postgres_port, args.postgres_database_name),
            "username": args.postgres_admin_username,
            "password": args.postgres_admin_password,
        },
        token=token,
        expected_statuses={204},
    )


# Create or update the Vault database role that issues short-lived PostgreSQL superusers.
def ensure_postgres_role(base_url, token, args):
    log(f"Configuring dynamic PostgreSQL role {args.vault_db_role_name}")
    request(
        "POST",
        f"{base_url}/v1/database/roles/{args.vault_db_role_name}",
        payload={
            "db_name": args.vault_db_connection_name,
            "creation_statements": [
                "CREATE ROLE \"{{name}}\" WITH SUPERUSER LOGIN ENCRYPTED PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';"
            ],
            "default_ttl": "10m",
            "max_ttl": "1h",
        },
        token=token,
        expected_statuses={204},
    )


def ensure_approle_auth(base_url, token):
    _, auth_methods = request("GET", f"{base_url}/v1/sys/auth", token=token)
    if "approle/" not in auth_methods:
        log("Enabling auth method approle")
        request(
            "POST",
            f"{base_url}/v1/sys/auth/approle",
            payload={"type": "approle"},
            token=token,
            expected_statuses={204},
        )
    else:
        log("Auth method approle is already enabled")


def ensure_ssh_rotator_role(base_url, token):
    log("Configuring AppRole role ssh-rotator")
    request(
        "POST",
        f"{base_url}/v1/auth/approle/role/ssh-rotator",
        payload={
            "token_policies": ["ssh-rotator"],
            "token_ttl": "5m",
            "token_max_ttl": "10m",
        },
        token=token,
        expected_statuses={204},
    )


def print_ssh_rotator_credentials(base_url, token):
    _, role_id_response = request(
        "GET",
        f"{base_url}/v1/auth/approle/role/ssh-rotator/role-id",
        token=token,
        expected_statuses={200},
    )
    role_id = role_id_response.get("data", {}).get("role_id", "")
    log(f"AppRole role_id:   {role_id}")

    _, secret_id_response = request(
        "POST",
        f"{base_url}/v1/auth/approle/role/ssh-rotator/secret-id",
        token=token,
        expected_statuses={200},
    )
    secret_id = secret_id_response.get("data", {}).get("secret_id", "")
    log(f"AppRole secret_id: {secret_id}")


def ensure_policy(base_url, token, name, policy):
    log(f"Configuring policy {name}")
    request(
        "PUT",
        f"{base_url}/v1/sys/policies/acl/{name}",
        payload={"policy": policy},
        token=token,
        expected_statuses={200, 204},
    )


def normalize_oidc_discovery_url(url):
    normalized = url.strip()
    if not normalized:
        return normalized

    if normalized.endswith("/.well-known/openid-configuration"):
        normalized = normalized[: -len("/.well-known/openid-configuration")]

    parsed = urllib.parse.urlparse(normalized)
    if parsed.scheme and parsed.netloc and parsed.path in {"", "/"}:
        return f"{parsed.scheme}://{parsed.netloc}/"

    if not normalized.endswith("/"):
        return f"{normalized}/"

    return normalized


def ensure_oidc_auth(base_url, token, args):
    if not args.oidc_discovery_url or not args.oidc_client_id or not args.oidc_client_secret or not args.oidc_bound_email:
        log("OIDC inputs were not fully provided, skipping OIDC configuration")
        return

    oidc_discovery_url = normalize_oidc_discovery_url(args.oidc_discovery_url)

    _, auth_methods = request("GET", f"{base_url}/v1/sys/auth", token=token)
    if "oidc/" not in auth_methods:
        log("Enabling auth method oidc")
        request(
            "POST",
            f"{base_url}/v1/sys/auth/oidc",
            payload={"type": "oidc"},
            token=token,
            expected_statuses={204},
        )
    else:
        log("Auth method oidc is already enabled")

    redirect_uris = [
        f"https://{args.vault_hostname}/ui/vault/auth/oidc/oidc/callback",
        "http://localhost:8250/oidc/callback",
    ]

    log("Configuring Vault OIDC auth backend")
    request(
        "POST",
        f"{base_url}/v1/auth/oidc/config",
        payload={
            "oidc_discovery_url": oidc_discovery_url,
            "oidc_client_id": args.oidc_client_id,
            "oidc_client_secret": args.oidc_client_secret,
            "default_role": args.oidc_role_name,
            "bound_issuer": oidc_discovery_url,
        },
        token=token,
        expected_statuses={204},
    )

    log(f"Configuring Vault OIDC role {args.oidc_role_name}")
    request(
        "POST",
        f"{base_url}/v1/auth/oidc/role/{args.oidc_role_name}",
        payload={
            "role_type": "oidc",
            "user_claim": "email",
            "bound_claims": {
                "email": args.oidc_bound_email,
            },
            "allowed_redirect_uris": redirect_uris,
            "oidc_scopes": ["openid", "profile", "email"],
            "policies": ["admin"],
        },
        token=token,
        expected_statuses={200, 204},
    )


# Define the Terraform-provided inputs required to initialize Vault and configure integrations.
def parse_args():
    parser = argparse.ArgumentParser(description="Bootstrap Vault after Terraform apply")
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--service-account", required=True)
    parser.add_argument("--cluster-name", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--kubernetes-host", required=True)
    parser.add_argument("--kubernetes-ca-b64", required=True)
    parser.add_argument("--vault-ca-cert-b64", required=True)
    parser.add_argument("--output-file", required=True,
                        help="Caminho local para salvar vault-init.json (usado em runs locais).")
    parser.add_argument("--output-s3-uri", default=None,
                        help="URI S3 para salvar vault-init.json diretamente no bucket (ex: s3://bucket/path/vault-init.json). "
                             "Quando fornecido, o arquivo NÃO é gravado localmente.")
    parser.add_argument("--postgres-host", required=True)
    parser.add_argument("--postgres-port", required=True, type=int)
    parser.add_argument("--postgres-database-name", required=True)
    parser.add_argument("--postgres-admin-username", required=True)
    parser.add_argument("--postgres-admin-password", required=True)
    parser.add_argument("--vault-db-connection-name", default="postgres")
    parser.add_argument("--vault-db-role-name", default="postgres-dynamic")
    parser.add_argument("--vault-hostname", required=True)
    parser.add_argument("--oidc-discovery-url", default="")
    parser.add_argument("--oidc-client-id", default="")
    parser.add_argument("--oidc-client-secret", default="")
    parser.add_argument("--oidc-bound-email", default="")
    parser.add_argument("--oidc-role-name", default="auth0-admin")
    return parser.parse_args()


# Orchestrate the full bootstrap sequence from connectivity checks to engine/auth/database setup.
def main():
    global TLS_CONTEXT, KUBERNETES_CONTEXT

    args = parse_args()
    TLS_CONTEXT = build_tls_context(args.vault_ca_cert_b64)
    KUBERNETES_CONTEXT = build_kubernetes_context(args.kubernetes_ca_b64)

    pod_name = "vault-0"
    wait_for_pod_running(args.namespace, pod_name, args.kubernetes_host, args.cluster_name, args.region)

    local_port = find_free_port()
    process = start_port_forward(args.namespace, pod_name, local_port)
    try:
        base_url = f"https://127.0.0.1:{local_port}"
        wait_for_vault(base_url)
        root_token = ensure_initialized(base_url, args.output_file, args.output_s3_uri)
        wait_for_vault_post_init(base_url)
        ensure_kv_v2(base_url, root_token)
        ensure_kubernetes_auth(
            base_url,
            root_token,
            args.namespace,
            args.service_account,
            args.kubernetes_host,
            args.kubernetes_ca_b64,
            args.cluster_name,
            args.region,
        )
        ensure_audit_stdout(base_url, root_token)
        ensure_client_counters(base_url, root_token)
        ensure_database_secrets_engine(base_url, root_token)
        ensure_postgres_connection(base_url, root_token, args)
        ensure_postgres_role(base_url, root_token, args)
        ensure_policy(
            base_url,
            root_token,
            "admin",
            'path "*" {\n  capabilities = ["create", "read", "update", "delete", "list", "patch", "sudo"]\n}\n',
        )
        ensure_oidc_auth(base_url, root_token, args)
        ensure_approle_auth(base_url, root_token)
        ensure_policy(
            base_url,
            root_token,
            "ssh-rotator",
            'path "kv/data/ssh-passwords/*" {\n  capabilities = ["create", "update"]\n}\n',
        )
        ensure_ssh_rotator_role(base_url, root_token)
        print_ssh_rotator_credentials(base_url, root_token)
        log("Vault bootstrap completed successfully")
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()


# Fail fast with a clear message so Terraform surfaces bootstrap issues immediately.
if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log(str(exc))
        sys.exit(1)
