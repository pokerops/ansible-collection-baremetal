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

# Unit tests for the collection's Python. Repo-specific, so it lives here rather
# than upstream: the shared justfile covers lint and molecule, and nothing in it
# knows about plugins/.
#
# This is the fast half of the test pyramid. The molecule scenario needs libvirt,
# a network and twelve minutes; these run in well under a second, and they exist
# because the bugs that cost the most here were pure functions of talosctl output
# -- a flag in the wrong position, a field that does not exist in the JSON.
units:
    @uv run pytest tests/unit -q

