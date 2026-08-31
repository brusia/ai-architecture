set -euo pipefail

PORT="${PORT:-8080}"
IMAGE="ghcr.io/avisi-cloud/structurizr-site-generatr:latest"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Открой http://localhost:${PORT} — сайт обновляется при правках workspace.dsl (Ctrl+C для выхода)"

exec docker run -it --rm \
  -v "${REPO_ROOT}:/var/model" \
  -w /var/model \
  -p "${PORT}:8080" \
  "${IMAGE}" \
  serve \
    --workspace-file docs/architecture/workspace.dsl \
    --assets-dir docs/architecture/assets
