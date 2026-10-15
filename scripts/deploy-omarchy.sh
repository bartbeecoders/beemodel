#!/usr/bin/env bash
# Build the latest BeeModel and add it to Omarchy.
#
# By default this fetches origin and builds origin/main in a throwaway
# worktree, so the checkout you work in is left alone. Then it installs:
#   ~/.local/bin/beemodel (and beemodel-gpu, when it was built)
#   a launcher entry and icon, and .bee files opening in BeeModel
#   the bar plugin bart.beemodel, enabled on the right
# Re-run it to update. A running BeeModel keeps its old binary until it
# is restarted.
#
#   scripts/deploy-omarchy.sh              build origin/main
#   scripts/deploy-omarchy.sh --ref v0.12.0  build a tag, branch or commit
#   scripts/deploy-omarchy.sh --local      build this working tree as it is
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
ref=origin/main
local_build=0
while (($#)); do
  case $1 in
    --ref) ref=${2:?--ref needs a git ref}; shift 2 ;;
    --local) local_build=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "deploy-omarchy: unknown option $1 (see --help)" >&2; exit 1 ;;
  esac
done

plugin_id=bart.beemodel
bin_dir=$HOME/.local/bin
share=$HOME/.local/share/beemodel
plugins_dir=$HOME/.config/omarchy/plugins
link=$plugins_dir/$plugin_id
apps=$HOME/.local/share/applications
icons=$HOME/.local/share/icons/hicolor/scalable/apps

fail() {
  echo "deploy-omarchy: $*" >&2
  exit 1
}

for tool in git as ld jq omarchy omarchy-shell; do
  command -v $tool >/dev/null || fail "$tool is not on PATH"
done

# --- build -------------------------------------------------------------------
tree=$repo
if ((!local_build)); then
  echo "==> Fetching origin"
  git -C "$repo" fetch -q origin --tags
  commit=$(git -C "$repo" rev-parse --verify -q "$ref^{commit}") || fail "unknown ref $ref"
  tree=$(mktemp -d "${TMPDIR:-/tmp}/beemodel-deploy.XXXXXX")
  trap 'git -C "$repo" worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"' EXIT
  git -C "$repo" worktree add -q --detach "$tree" "$commit"
  echo "==> Building $ref ($(git -C "$tree" log -1 --format='%h %s'))"
else
  echo "==> Building the working tree ($(git -C "$repo" log -1 --format=%h)$(git -C "$repo" diff --quiet HEAD || echo ', with changes'))"
fi
"$tree/build.sh" release
[[ -x $tree/build/beemodel ]] || fail "the build made no build/beemodel"
"$tree/build/beemodel" --version >/dev/null || fail "the new binary does not run"
version=$("$tree/build/beemodel" --version)
[[ -f $tree/omarchy-plugin/manifest.json ]] || fail "$ref has no omarchy-plugin/ (it is older than the deploy script)"

# --- install -----------------------------------------------------------------
install_exe() { # src dst: replace atomically, so a running copy keeps working
  cp "$1" "$2.new"
  chmod 755 "$2.new"
  mv -f "$2.new" "$2"
}

echo "==> Installing $bin_dir/beemodel"
mkdir -p "$bin_dir"
install_exe "$tree/build/beemodel" "$bin_dir/beemodel"
if [[ -x $tree/build/beemodel-gpu ]]; then
  # (BeeModel looks for its GPU helper next to its own binary)
  install_exe "$tree/build/beemodel-gpu" "$bin_dir/beemodel-gpu"
else
  rm -f "$bin_dir/beemodel-gpu"
fi

echo "==> Installing the launcher entry, icon and .bee file type"
mkdir -p "$apps" "$icons" "$HOME/.local/share/mime/packages"
sed "s|@BIN@|$bin_dir/beemodel|" "$tree/omarchy-plugin/beemodel.desktop" > "$apps/beemodel.desktop"
cp "$tree/omarchy-plugin/beemodel.svg" "$icons/beemodel.svg"
cp "$tree/omarchy-plugin/beemodel-mime.xml" "$HOME/.local/share/mime/packages/beemodel.xml"
command -v update-mime-database >/dev/null && update-mime-database "$HOME/.local/share/mime" || true
command -v update-desktop-database >/dev/null && update-desktop-database -q "$apps" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -qtf "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

# The plugin is copied out of the build tree (which may be thrown away),
# so the bar button always matches the installed binary.
echo "==> Installing the plugin to $share/omarchy-plugin"
omarchy plugin validate "$tree/omarchy-plugin"
mkdir -p "$share"
rm -rf "$share/omarchy-plugin.new"
cp -r "$tree/omarchy-plugin" "$share/omarchy-plugin.new"
rm -rf "$share/omarchy-plugin"
mv "$share/omarchy-plugin.new" "$share/omarchy-plugin"

echo "==> Linking $link"
mkdir -p "$plugins_dir"
if [[ -L $link ]]; then
  [[ $(readlink -f "$link") == "$(readlink -f "$share/omarchy-plugin")" ]] \
    || fail "$link points at $(readlink -f "$link"), not $share/omarchy-plugin"
elif [[ -e $link ]]; then
  fail "$link exists and is not a symlink"
else
  ln -s "$share/omarchy-plugin" "$link"
fi

# --- enable ------------------------------------------------------------------
echo "==> Enabling $plugin_id"
# rescanPlugins can take longer than the default 2 s IPC budget.
export OMARCHY_SHELL_IPC_TIMEOUT="${OMARCHY_SHELL_IPC_TIMEOUT:-15s}"
omarchy-shell shell rescanPlugins >/dev/null \
  || fail "the shell did not rescan. When it is running: omarchy plugin enable $plugin_id --section right"

plugin_list=""
read_plugin_list() {
  plugin_list=$(omarchy plugin list --json) || fail "the shell did not answer. Run: omarchy restart shell"
}
deadline=$((SECONDS + 20))
until read_plugin_list; jq -e --arg id "$plugin_id" 'any(.[]; .id == $id)' <<<"$plugin_list" >/dev/null; do
  ((SECONDS < deadline)) || fail "plugin '$plugin_id' is not known. Run: omarchy-shell shell rescanPlugins"
  sleep 0.2
done
if jq -e --arg id "$plugin_id" 'any(.[]; .id == $id and .enabled)' <<<"$plugin_list" >/dev/null; then
  echo "Already enabled"
else
  omarchy plugin enable "$plugin_id" --section right
fi

echo
echo "$version is installed."
echo "  Binary    $bin_dir/beemodel"
echo "  Plugin    $link"
echo "  Bar       a click focuses BeeModel, or starts it"
echo "  Launcher  BeeModel (Super + Space); .bee files open in it"
echo "  Command   omarchy-shell $plugin_id app"
echo
echo "A key can do the same, in ~/.config/hypr/bindings.lua:"
echo "  o.bind(\"SUPER + ALT + B\", \"BeeModel\", \"omarchy-shell $plugin_id app\")"
echo
echo "Agents: claude mcp add -s user beemodel -- $bin_dir/beemodel --mcp-bridge"
