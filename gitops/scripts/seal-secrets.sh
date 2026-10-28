#!/usr/bin/env bash
# Sinh toàn bộ secret đã mã hoá SOPS trong gitops/apps/prod/secrets/ từ gitops/secrets.env.
# Bản rõ chỉ nằm trong file tạm (mktemp, quyền 600) và bị xoá ngay sau khi mã hoá.
set -euo pipefail

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$ROOT"

ENV_FILE=${ENV_FILE:-gitops/secrets.env}
OUT=gitops/apps/prod/secrets
REGISTRY=registry.daidq.io.vn

for cmd in sops jq openssl; do
  command -v "$cmd" >/dev/null || { echo "Thiếu lệnh: $cmd" >&2; exit 1; }
done
[[ -f $ENV_FILE ]] || { echo "Không thấy $ENV_FILE — copy từ gitops/secrets.env.example" >&2; exit 1; }

# Đọc KEY=VALUE thủ công thay vì source để mật khẩu chứa $, `, dấu cách không bị shell diễn giải
while IFS= read -r line || [[ -n $line ]]; do
  [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
  [[ $line =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || { echo "Dòng không hợp lệ trong $ENV_FILE: $line" >&2; exit 1; }
  printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
done < "$ENV_FILE"

for var in AGE_PUBLIC_KEY HARBOR_USERNAME HARBOR_PASSWORD BACKEND_ENV_FILE GCP_CREDENTIALS_FILE; do
  [[ -n ${!var:-} ]] || { echo "Thiếu $var trong $ENV_FILE" >&2; exit 1; }
done
[[ -f $BACKEND_ENV_FILE ]] || { echo "Không thấy $BACKEND_ENV_FILE" >&2; exit 1; }
[[ -f $GCP_CREDENTIALS_FILE ]] || { echo "Không thấy $GCP_CREDENTIALS_FILE" >&2; exit 1; }

if [[ -z ${FLUX_WEBHOOK_TOKEN:-} ]]; then
  FLUX_WEBHOOK_TOKEN=$(openssl rand -hex 32)
  if grep -q '^FLUX_WEBHOOK_TOKEN=' "$ENV_FILE"; then
    sed -i "s/^FLUX_WEBHOOK_TOKEN=.*/FLUX_WEBHOOK_TOKEN=$FLUX_WEBHOOK_TOKEN/" "$ENV_FILE"
  else
    echo "FLUX_WEBHOOK_TOKEN=$FLUX_WEBHOOK_TOKEN" >> "$ENV_FILE"
  fi
  echo "Đã sinh FLUX_WEBHOOK_TOKEN mới vào $ENV_FILE → cập nhật GitHub secret FLUX_WEBHOOK_TOKEN ở cả 2 repo"
fi

# .sops.yaml chỉ chứa public key nên commit được; sinh lại để luôn khớp AGE_PUBLIC_KEY
cat > .sops.yaml <<EOF
# File sinh bởi gitops/scripts/seal-secrets.sh từ AGE_PUBLIC_KEY trong gitops/secrets.env
creation_rules:
  # .env / .json: mã hoá toàn bộ giá trị
  - path_regex: gitops/.*\.sops\.(env|json)$
    age: $AGE_PUBLIC_KEY
  # Secret manifest: chỉ mã hoá data/stringData, giữ metadata đọc được
  - path_regex: gitops/.*\.sops\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: $AGE_PUBLIC_KEY
EOF

# seal <đích>: đọc bản rõ từ stdin, mã hoá theo rule trong .sops.yaml ứng với tên <đích>
seal() {
  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN
  cat > "$tmp"
  sops -e --filename-override "$1" "$tmp" > "$1.tmp"
  mv "$1.tmp" "$1"
  echo "✔ $1"
}

# secret <name> <namespace> <type> <key> <value>: in Secret manifest (JSON cũng là YAML hợp lệ)
secret() {
  jq -n --arg name "$1" --arg ns "$2" --arg type "$3" --arg key "$4" --arg val "$5" \
    '{apiVersion: "v1", kind: "Secret", metadata: {name: $name, namespace: $ns}, type: $type, stringData: {($key): $val}}'
}

dockerconfig=$(jq -nc --arg r "$REGISTRY" --arg u "$HARBOR_USERNAME" --arg p "$HARBOR_PASSWORD" \
  '{auths: {($r): {username: $u, password: $p, auth: ("\($u):\($p)" | @base64)}}}')

secret harbor-pull do-an kubernetes.io/dockerconfigjson .dockerconfigjson "$dockerconfig" | seal "$OUT/harbor-pull.sops.yaml"
secret harbor-pull flux-system kubernetes.io/dockerconfigjson .dockerconfigjson "$dockerconfig" | seal "$OUT/harbor-pull-flux.sops.yaml"
secret webhook-token flux-system Opaque token "$FLUX_WEBHOOK_TOKEN" | seal "$OUT/webhook-token.sops.yaml"
seal "$OUT/backend.sops.env" < "$BACKEND_ENV_FILE"
seal "$OUT/gcloud.sops.json" < "$GCP_CREDENTIALS_FILE"
