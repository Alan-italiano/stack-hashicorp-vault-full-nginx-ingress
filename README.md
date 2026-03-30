# Stack HashiCorp Vault — NGINX Ingress + Let's Encrypt

Infraestrutura completa para um cluster **HashiCorp Vault em alta disponibilidade** no AWS EKS, usando **NGINX Ingress Controller** como edge de entrada com **ModSecurity WAF (OWASP CRS)** e certificados **Let's Encrypt** gerenciados pelo **cert-manager** via DNS-01.

> Variante do stack ALB+WAF: substitui o AWS Application Load Balancer Controller e o AWS WAF por NGINX Ingress Controller com defesa em profundidade nativa do Kubernetes.

---

## Arquitetura

```
Internet
   │
   ▼
AWS NLB (Network Load Balancer — Layer 4)
   │  provisionado automaticamente pelo AWS Cloud Provider
   │  via Service type=LoadBalancer do NGINX
   ▼
NGINX Ingress Controller (3+ réplicas, HPA, PDB)
   │  ┌─ TLS 1.2/1.3 terminado aqui (cert Let's Encrypt)
   │  ├─ ModSecurity WAF (OWASP CRS)
   │  ├─ Rate limiting por IP
   │  └─ Security headers (HSTS, X-Frame-Options, CSP…)
   │
   ├──► Vault (re-encrypt HTTPS → porta 8200)
   │       3 réplicas em HA com Raft consensus
   │       KMS auto-unseal, mTLS entre peers
   │
   └──► Grafana (HTTP → porta 3000)
           Prometheus + Loki + Promtail
```

### Componentes

| Camada | Componente | Observações |
|--------|-----------|-------------|
| Edge | NGINX Ingress Controller 4.12.1 | NLB, ModSecurity OWASP CRS, rate limit, HSTS |
| TLS Público | cert-manager + Let's Encrypt | DNS-01 via Route53, renovação automática |
| TLS Interno | cert-manager + CA própria | mTLS Vault peer-to-peer |
| DNS | External DNS 1.20.0 | Route53 automático via annotations do Ingress |
| Secrets | HashiCorp Vault 1.21.4 | 3 réplicas Raft, KMS unseal, UI |
| Observabilidade | kube-prometheus-stack 82.15.1 | Prometheus, Grafana, Alertmanager |
| Logs | Loki 6.55.0 + Promtail 6.17.1 | Audit logs do Vault via Loki |
| Banco | PostgreSQL 17 (ClusterIP) | Credenciais dinâmicas via Vault |
| Rede | NetworkPolicies | Segmentação Vault/Grafana/NGINX |
| Storage | EBS gp3 (StorageClass) | Vault data + Loki |
| IAM | IRSA | Vault, EBS CSI, External DNS, cert-manager |

---

## Diferenças em relação ao stack ALB+WAF

| Feature | Stack ALB+WAF | Este Stack (NGINX) |
|---------|--------------|-------------------|
| Load Balancer | AWS ALB (Layer 7) | AWS NLB (Layer 4) + NGINX (Layer 7) |
| Ingress Class | `alb` | `nginx` |
| WAF | AWS WAF v2 (managed rules) | ModSecurity OWASP CRS (embutido no NGINX) |
| Rate Limiting | AWS WAF rate-based rule | NGINX `limit-req` por IP por ingress |
| TLS Público | AWS ACM | cert-manager + Let's Encrypt |
| TLS Challenge | ACM DNS validation | ACME DNS-01 via Route53 |
| IP Reputation | AWS IP Reputation List | Configurável via ModSecurity |
| PostgreSQL | NLB externo | ClusterIP interno (port-forward) |
| IRSA Removido | ALB Controller | — |
| IRSA Adicionado | — | cert-manager (Route53 DNS-01) |
| NetworkPolicies | ❌ | ✅ (vault, grafana, nginx) |
| Custo estimado | NLB + ALB + WAF | NLB apenas |

---

## Segurança — Defesa em Profundidade

### 1. Camada de Rede (AWS)
- NLB com `externalTrafficPolicy: Local` (preserva IP real do cliente)
- `vault_allowed_cidrs`: restrição de IPs a nível de NLB source ranges (opcional)

### 2. Camada de Aplicação (NGINX)
- **ModSecurity WAF** com OWASP Core Rule Set habilitado globalmente
- **Rate limiting** por IP: `nginx_rate_limit_rps` req/s + `nginx_rate_limit_connections` conexões simultâneas
- **TLS 1.2/1.3** com cipher suites Forward Secrecy (ECDHE/DHE)
- **HSTS** com preload (`max-age=31536000`)
- `ssl-reject-handshake: true` — rejeita hosts não declarados
- `server-tokens: false` — oculta versão NGINX
- Security headers por ingress: `X-Frame-Options`, `X-Content-Type-Options`, `CSP`, `Referrer-Policy`

### 3. Camada de Rede do Cluster (Kubernetes)
- **NetworkPolicy** `vault-allow-ingress-and-peers`:
  - Vault aceita apenas tráfego do namespace `ingress-nginx` (porta 8200) e de peers Vault (8200/8201)
  - Prometheus pode coletar métricas (8200)
- **NetworkPolicy** `grafana-allow-nginx-ingress`:
  - Grafana aceita apenas tráfego do namespace `ingress-nginx`
- **NetworkPolicy** `nginx-allow-egress-to-backends`:
  - NGINX só pode alcançar Vault (8200) e Grafana (3000)

### 4. Camada de Identidade
- **IRSA** (IAM Roles for Service Accounts) para cada service account — sem credenciais long-lived no cluster
- KMS key com política restrita ao role do Vault

---

## Pré-requisitos

- AWS Account com permissões para: EC2, EKS, IAM, KMS, S3, Route53, NLB
- Hosted Zone Route53 existente para o domínio configurado
- OpenTofu >= 1.8.3 (ou Terraform >= 1.6.0)
- kubectl, Python 3.12+

---

## Deploy Local

```bash
# 1. Clone o repositório
git clone <repo-url>
cd stack-hashicorp-vault-full-nginx-ingress

# 2. Configure credenciais AWS
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...

# 3. Crie o arquivo de variáveis
cp tofu.tfvars.example tofu.tfvars
# Edite tofu.tfvars com seus valores

# 4. Inicialize o backend
tofu init -backend-config=backend.local.hcl

# 5. Plan e Apply
tofu plan -var-file=tofu.tfvars
tofu apply -var-file=tofu.tfvars

# 6. Configure o kubeconfig
aws eks update-kubeconfig --name vault-eks-lab --region us-east-1

# 7. Bootstrap do Vault
tofu output   # colete os parâmetros necessários
python3 scripts/bootstrap_vault.py \
  --namespace vault \
  --service-account vault \
  # ... demais parâmetros
```

---

## Deploy via GitHub Actions

### Secrets obrigatórios

Configure em **Settings → Secrets and variables → Actions**:

| Secret | Descrição |
|--------|-----------|
| `AWS_ACCESS_KEY_ID` | Chave de acesso AWS |
| `AWS_SECRET_ACCESS_KEY` | Secret da chave AWS |
| `TF_STATE_BUCKET` | Bucket S3 para o Terraform state |
| `POSTGRES_ADMIN_PASSWORD` | Senha do administrador do PostgreSQL |
| `VAULT_OIDC_CLIENT_SECRET` | Client secret OIDC (opcional) |

### Workflows disponíveis

- **Terraform Apply** (`workflow_dispatch`): provisiona toda a infraestrutura + bootstrap do Vault
- **Terraform Destroy** (`workflow_dispatch`): destrói tudo (requer digitar `DESTROY`)

---

## Operação

### Verificar status do Vault
```bash
kubectl exec -n vault vault-0 -- sh -lc \
  'VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 \
   VAULT_CACERT=/vault/userconfig/ca/ca.crt vault status'
```

### Verificar peers Raft
```bash
ROOT_TOKEN=$(jq -r .root_token bootstrap/vault-init.json)
kubectl exec -n vault vault-0 -- sh -lc \
  "VAULT_ADDR=https://vault-0.vault-internal.vault.svc.cluster.local:8200 \
   VAULT_CACERT=/vault/userconfig/ca/ca.crt \
   VAULT_TOKEN=$ROOT_TOKEN vault operator raft list-peers"
```

### Acessar PostgreSQL localmente
```bash
kubectl port-forward -n postgres svc/postgres-service 5432:5432
# PostgreSQL agora acessível em localhost:5432
```

### Verificar certificados Let's Encrypt
```bash
kubectl get certificate -n vault
kubectl get certificate -n monitoring
kubectl describe clusterissuer letsencrypt-prod
```

### Verificar NGINX Ingress NLB
```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller
# Obtenha o hostname do NLB no campo EXTERNAL-IP
```

### Grafana admin password
```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

---

## Variáveis principais

| Variável | Default | Descrição |
|----------|---------|-----------|
| `letsencrypt_email` | `admin@lab-internal.com.br` | Email para conta ACME Let's Encrypt |
| `nginx_ingress_replica_count` | `3` | Réplicas do NGINX (mínimo para HA) |
| `nginx_enable_modsecurity` | `true` | Habilita ModSecurity OWASP CRS |
| `nginx_rate_limit_rps` | `20` | Req/s por IP por ingress |
| `nginx_rate_limit_connections` | `20` | Conexões simultâneas por IP |
| `nginx_scheme` | `internet-facing` | NLB público ou interno |
| `vault_allowed_cidrs` | `[]` | Restrição de CIDRs no NLB |

---

## Dashboards Grafana incluídos

- `12904_rev2_eks_custom_clean.json` — EKS cluster (nodes, pods, CPU, memória)
- `vault-telemetry-dashboard.json` — Vault performance e contadores
- `vault-audit-loki-dashboard.json` — Audit logs do Vault via Loki

Import em **Grafana → Dashboards → Import → Upload JSON file**.
