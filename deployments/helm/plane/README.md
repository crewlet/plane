# Plane Helm chart

Deploys Plane (community edition) onto Kubernetes from the images this fork
publishes to GHCR. It installs standalone with `helm install`, and is shaped so
a GitOps controller can drive it from a handful of injected values.

Upstream's own chart lives at
[artifacthub.io/packages/helm/makeplane/plane-ce](https://artifacthub.io/packages/helm/makeplane/plane-ce);
this one exists because it models a deployment that chart does not: an external
managed Postgres rather than a bundled one, S3 reached through a workload
identity role rather than MinIO, and TLS terminated ahead of the release rather
than a bundled load balancer.

## What it deploys

| Component | Kind | Image suffix | Notes |
| --- | --- | --- | --- |
| `proxy` | Deployment | `-proxy` | Caddy. The single entry point; everything else stays inside the namespace. |
| `web` | Deployment | `-frontend` | Main app, static files on nginx. |
| `space` | Deployment | `-space` | Public "spaces" app, server-rendered, under `/spaces`. |
| `admin` | Deployment | `-admin` | God-mode admin, static files on nginx, under `/god-mode`. |
| `live` | Deployment | `-live` | Collaborative editing (Hocuspocus/WebSocket), under `/live`. |
| `api` | Deployment | `-backend` | Django ASGI app: `/api`, `/auth`, `/static`. |
| `worker` | Deployment | `-backend` | Celery worker. |
| `beat` | Deployment | `-backend` | Celery beat. Single replica by design. |
| `migrator` | Job | `-backend` | `manage.py migrate`, as a pre-install/pre-upgrade hook. |
| `redis` | StatefulSet | — | Valkey: Django's cache and the live server's presence store. |
| `rabbitmq` | StatefulSet | — | Celery's broker. |

Postgres is **not** part of the chart — point `DATABASE_URL` at an existing
instance.

### Images

The six Plane images are published side by side under one namespace, so
`image.repository` is a **prefix** and each component appends its own suffix:
`ghcr.io/crewlet/plane` + `-backend` + `:` + `image.tag`. One
`image.repository`/`image.tag` pair therefore configures all six, which is what
lets a generic GitOps Application template -- one that knows only how to inject
a single image reference -- drive a multi-image chart. Set `<component>.image`
to a full reference to pin one component elsewhere.

### Request routing

Caddy owns the path split, mirroring `apps/proxy/Caddyfile.ce`:

```
/spaces/*    -> space      /api/*, /auth/*, /static/*  -> api
/god-mode/*  -> admin      /*                          -> web
/live/*      -> live       /_healthz                   -> Caddy itself
```

TLS is expected to terminate ahead of the proxy, so Caddy serves plain HTTP on
port 8080 (above 1024, so it needs no `NET_BIND_SERVICE` capability) and
requests no certificates. Django decides a request is secure from
`X-Forwarded-Proto`, and Caddy only forwards that header from a peer listed in
`proxy.trustedProxies` — if the ingress hop is not trusted, every request looks
like plain HTTP and CSRF checks start failing.

## Configuration

Non-secret settings live under `config` and are rendered into a ConfigMap that
the api, worker, beat, migrator and live components consume. Anything the chart
does not model goes in `config.extraEnv`.

Secret material — `SECRET_KEY`, `DATABASE_URL`, `LIVE_SERVER_SECRET_KEY`,
`RABBITMQ_PASSWORD` — comes from one secret, either rendered by the chart
(`secrets.create: true`) or managed elsewhere (`secrets.create: false` plus an
`extraEnvFrom` entry). `extraEnvFrom` is layered after the ConfigMap, so it
wins on any key both define.

See [`values.yaml`](values.yaml) for the full set; every key is commented.

### Object storage

Uploads go to S3 through presigned URLs the API hands to the browser, so the
bucket needs CORS rules that allow the public origin. Leave
`config.storage.accessKeyId`/`secretAccessKey` empty on EKS: the env vars are
then omitted entirely and boto3 falls back to the service account's
web-identity credentials (IRSA), with the role ARN on
`serviceAccount.annotations`.

One consequence worth knowing: a presigned URL signed with temporary
credentials dies when that session does. Keep
`config.storage.signedUrlExpiration` well under the IAM role's session
duration, or links will expire earlier than the value suggests.

### Security contexts

The Plane images run as root and write inside their working directory
(collectstatic output, rotating logs, Caddy's data dir), so `runAsNonRoot` and
`readOnlyRootFilesystem` are not set — dropping capabilities and privilege
escalation is what they support without patching.

Four components shed root themselves and get a context of their own: `web` and
`admin` (nginx hands its workers to the `nginx` user) keep `SETUID`/`SETGID`,
and `redis`/`rabbitmq` (entrypoints chown the data dir and `gosu` into the
service user) additionally keep `CHOWN`, `DAC_OVERRIDE` and `FOWNER`. Dropping
`ALL` on those four stops them booting.

### Migrations

`migrator` is a Helm `pre-install,pre-upgrade` hook, which Argo CD maps onto its
own PreSync phase — the schema is always current before a new api, worker or
beat pod starts. The job is kept after success (deleted only when the next one
is created) so its logs stay available.

## Standalone install

```bash
helm install plane deployments/helm/plane \
  --namespace plane --create-namespace \
  --set image.tag=preview \
  --set config.webUrl=https://plane.example.com \
  --set config.corsAllowedOrigins=https://plane.example.com \
  --set config.storage.bucket=my-plane-uploads \
  --set config.storage.region=us-east-2 \
  --set secrets.create=true \
  --set secrets.secretKey="$(openssl rand -hex 32)" \
  --set secrets.liveServerSecretKey="$(openssl rand -hex 32)" \
  --set secrets.rabbitmqPassword="$(openssl rand -hex 16)" \
  --set secrets.databaseUrl='postgres://user:pass@host:5432/plane?sslmode=require'
```

Then send traffic to the `plane-proxy` Service on port 80.

The chart creates no Ingress. Point whatever terminates traffic — an Ingress, a
`LoadBalancer` Service, an outbound tunnel — at that Service, and make sure it
forwards `X-Forwarded-Proto`. Pod scheduling constraints (`nodeSelector`,
`affinity`, `tolerations`) are not modelled either.

## GitOps install

Under a GitOps controller the chart is usually driven entirely by injected
values, so nothing environment-specific and no secret material lands in git:

| Value | What the controller supplies |
| --- | --- |
| `image.repository`, `image.tag` | registry namespace, and the tag to roll |
| `imagePullSecrets` | pull secret for the registry, in the release namespace |
| `serviceAccount.annotations` | workload identity role for the uploads bucket |
| `secrets.create: false` + `extraEnvFrom` | a secret synced from an external secret store |
| `config.webUrl`, `config.corsAllowedOrigins` | the environment's public hostname |
| `config.storage.bucket`, `config.storage.region` | the uploads bucket |

Because `image.repository` is a prefix, that first row is a single injected
reference no matter how many component images the release actually pulls.
