import? '.devbox/virtenv/pokerops.ansible-utils.molecule/justfile'

talos +args:
  MOLECULE_SCENARIO=talos \
    just {{args}}

kubectl *args:
  KUBECONFIG=./.ansible/talos/kubeconfig \
    kubectl {{args}}

talosctl *args:
  TALOSCONFIG=./.ansible/talos/talosconfig \
    talosctl {{args}}

black:
  @uv run black plugins/ tests/ --quiet --check

pytest:
  @uv run pytest tests/unit --quiet

sanity *args: sync
  #!/usr/bin/env bash
  set -euo pipefail
  root="{{justfile_directory()}}"
  work="${TMPDIR:-/tmp}/pokerops-baremetal-sanity"
  dest="$work/ansible_collections/pokerops/baremetal"
  rm -rf "$work"
  mkdir -p "$dest"
  git -C "$root" ls-files -z --cached --others --exclude-standard \
    | rsync -a --files-from=- --from0 "$root/" "$dest/"
  git -C "$dest" init -q
  git -C "$dest" add -A
  cd "$dest"
  "$root/.venv/bin/ansible-test" sanity {{args}}
