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

update:
  #!/usr/bin/env bash
  set -euo pipefail
  devbox update
  scenario="{{justfile_directory()}}/extensions/molecule/upgrade"
  version="$(devbox run -- talosctl version --client --short | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  minor="${version%.*}"
  tags="$(curl -fsSL 'https://api.github.com/repos/siderolabs/talos/releases?per_page=100' \
    | jq -r --arg minor "$minor" '.[]
        | select(.prerelease | not)
        | .tag_name
        | select(startswith($minor + "."))' \
    | sort -V -r)"
  newer="$(echo "$tags" | sed -n 1p)"
  older="$(echo "$tags" | sed -n 2p)"
  if [ -z "$newer" ] || [ -z "$older" ]; then
    echo "toolchain is ${version}; need two ${minor} releases to pin, found: ${tags:-none}" >&2
    exit 1
  fi
  sed -i "s|baremetal_talos_release: v[0-9.]*|baremetal_talos_release: ${older}|" "$scenario/converge.yml"
  sed -i "s|baremetal_talos_release: v[0-9.]*|baremetal_talos_release: ${newer}|" "$scenario/side_effect.yml"
  sed -i "s|_downgrade_release: v[0-9.]*|_downgrade_release: ${older}|" "$scenario/side_effect.yml"
  echo "toolchain ${version}: upgrade scenario now ${older} -> ${newer}"
