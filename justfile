import? '.devbox/virtenv/pokerops.ansible-utils.molecule/justfile'

talos *args:
  MOLECULE_SCENARIO=talos \
    just {{args}}

kubectl *args:
  KUBECONFIG=./talos/kubeconfig \
    kubectl {{args}}

talosctl *args:
  TALOSCONFIG=./talos/talosconfig \
    talosctl {{args}}

black:
  @uv run black plugins/ tests/ --quiet --check

pytest:
  @uv run pytest tests/unit --quiet

