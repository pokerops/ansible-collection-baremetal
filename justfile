import? '.devbox/virtenv/pokerops.ansible-utils.molecule/justfile'

talos *args:
  MOLECULE_SCENARIO=talos \
    just {{args}}

kubectl *args:
  KUBECONFIG=./talos/kubeconfig \
    kubectl {{args}}

talosctl *args:
  TALOSCONFIG=$PWD/talos/talosconfig \
    talosctl {{args}}

black:
  @uv run black plugins/ --quiet --check

pytest:
    @uv run pytest tests/unit --quiet

