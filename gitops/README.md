# GitOps — Flux CD

## Luồng CI/CD

```
push main (DA_Backend / DA_Frontend)
  └─ GitHub Actions: test → build & push registry.daidq.io.vn/do_an/<app>:<sha>-<unix time>
       └─ POST webhook (HMAC) ──► Flux Receiver ci-image-push
                                    └─ ImageRepository quét Harbor ngay
                                         └─ ImagePolicy chọn tag có số lớn nhất (mới nhất)
                                              └─ ImageUpdateAutomation sửa tag trong apps/prod, commit lên main
                                                   └─ Kustomization apps apply → rolling update
```

## Cấu trúc

```
gitops/
├── clusters/prod/
│   ├── flux-system/          # do flux bootstrap sinh ra, không sửa tay
│   └── apps.yaml             # Kustomization "apps" → ./gitops/apps/prod (có giải mã SOPS)
├── apps/prod/
│   ├── backend/, frontend/   # Deployment (hostPort backend :8083, frontend :3000) + Service
│   ├── flux/                 # ImageRepository, ImagePolicy, ImageUpdateAutomation, Receiver + Service NodePort webhook :30292
│   └── secrets/              # *.sops.{env,json,yaml} — đã mã hoá, sinh bằng script
├── scripts/seal-secrets.sh   # secrets.env + .env/gcloud.json backend → secret đã mã hoá + .sops.yaml
└── secrets.env.example       # mẫu cho gitops/secrets.env (gitignore)
```

## Cài đặt lần đầu

### 1. Bật image automation + deploy key có quyền ghi

Bootstrap lại với 2 controller image và `--read-write-key` (ImageUpdateAutomation cần push lên repo):

```sh
flux bootstrap github \
  --owner=CBGQuocDai --repository=Do_an_tot_nghiep --personal \
  --branch=main --path=gitops/clusters/prod \
  --read-write-key \
  --components-extra=image-reflector-controller,image-automation-controller
git pull
```

Nếu sau này automation báo lỗi push bị từ chối: xoá deploy key cũ trong GitHub (Settings → Deploy keys),
`kubectl -n flux-system delete secret flux-system`, rồi chạy lại lệnh trên.

### 2. Tạo age key cho SOPS

```sh
age-keygen -o age.agekey          # in ra public key age1...
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=age.agekey
```

Cất `age.agekey` ở nơi an toàn, **không commit** (`*.agekey` đã có trong `.gitignore`).

### 3. Tạo secret đã mã hoá

Mọi giá trị nằm trong **một file** `gitops/secrets.env` (gitignore) + `.env`/`gcloud.json` sẵn có của DA_Backend:

```sh
cp gitops/secrets.env.example gitops/secrets.env
# điền AGE_PUBLIC_KEY, HARBOR_USERNAME, HARBOR_PASSWORD; FLUX_WEBHOOK_TOKEN để trống thì script tự sinh
gitops/scripts/seal-secrets.sh     # cần sops >= 3.9, jq, openssl
```

Script sinh `.sops.yaml` và toàn bộ `gitops/apps/prod/secrets/*.sops.*`; bản rõ không bao giờ nằm trong repo.

`.env` của backend phải là giá trị cho prod: `CORS_ALLOWED_ORIGINS=https://da.daidq.io.vn`,
`DB_URL`/`REDIS_HOST` truy cập được từ cluster (muốn giữ `.env` cho dev thì tạo `.env.prod` và trỏ
`BACKEND_ENV_FILE` tới đó). `PORT` và `GOOGLE_APPLICATION_CREDENTIALS` bị Deployment ghi đè nên để nguyên cũng được.

Đổi giá trị nào thì sửa file nguồn, chạy lại script rồi commit. Riêng backend cần thêm
`kubectl -n do-an rollout restart deploy/da-backend` để pod đọc lại env.

### 4. Hạ tầng

- Pod mở hostPort 8083 (backend), 3000 (frontend) trên node; Cloudflare Tunnel trỏ `api-da.daidq.io.vn` → `localhost:8083`, `da.daidq.io.vn` → `localhost:3000`. Webhook Flux ở NodePort 30292.
- Node k3s phải resolve và pull được `registry.daidq.io.vn` (qua Tailscale).

### 5. Push và cấu hình GitHub

```sh
git add . && git commit -m "Add Flux CD for backend/frontend" && git push
flux reconcile kustomization apps --with-source
kubectl -n flux-system get receiver ci-image-push -o jsonpath='{.status.webhookPath}'
```

Trong **cả 2 repo** DA_Backend và DA_Frontend (Settings → Secrets and variables → Actions):

| Loại     | Tên                   | Giá trị                                           |
|----------|-----------------------|---------------------------------------------------|
| Secret   | `FLUX_WEBHOOK_URL`    | `http://100.118.32.97:30292` + webhookPath ở trên (runner CI đi qua Tailscale) |
| Secret   | `FLUX_WEBHOOK_TOKEN`  | `FLUX_WEBHOOK_TOKEN` trong `gitops/secrets.env`   |
| Variable | `NEXT_PUBLIC_API_URL` | `https://api-da.daidq.io.vn/api` (chỉ frontend) |

## Vận hành

```sh
flux get kustomizations
flux get images all -A
flux get receivers
kubectl -n do-an get pods
```

- Flux tự commit lên `main` mỗi lần deploy → luôn `git pull --rebase` trước khi push.
- Rollback: `flux suspend image update do-an`, sửa tag trong deployment về bản cũ, commit;
  xong thì `flux resume image update do-an`.
