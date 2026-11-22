#!/bin/sh
# Build through make, or start the release workflow.
set -eu

cd "$(dirname "$0")"

usage() {
	cat <<EOF
usage: $(basename "$0") [make target...] | --public --version vX.Y.Z [--notes "text"] [--prerelease]

  (no flag)             make, with any targets given: check, install, clean
  --public              trigger release.yml through the gh CLI
  --version <tag>       required with --public
  --notes <text>        release notes
  --prerelease          mark the release as a pre-release
EOF
}

case "${1:-}" in
	--public) ;;
	-h|--help) usage; exit 0 ;;
	*) exec make "$@" ;;
esac

version=""
notes=""
prerelease=false
shift
while [ $# -gt 0 ]; do
	case "$1" in
		--version)    version="${2:-}"; shift 2 ;;
		--notes)      notes="${2:-}"; shift 2 ;;
		--prerelease) prerelease=true; shift ;;
		*) echo "unknown flag: $1" >&2; usage; exit 1 ;;
	esac
done

# It builds nothing here. The workflow builds from the commit GitHub has, so
# a release never carries a local change that was never pushed.
workflow=release.yml

if [ -z "$version" ]; then
	echo "error: --public needs --version <tag>" >&2
	exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
	echo "error: no gh CLI. Install it and run 'gh auth login'" >&2
	exit 1
fi

repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
if [ -z "$repo" ]; then
	echo "error: not a GitHub repository, or gh is not authenticated" >&2
	exit 1
fi

printf '==> trigger %s on %s (%s)\n' "$workflow" "$repo" "$version"
old_id=$(gh run list --workflow="$workflow" --limit 1 \
	--json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")

gh workflow run "$workflow" \
	--field version="$version" \
	--field notes="$notes" \
	--field prerelease="$prerelease"

echo "==> waiting for the run to appear"
new_id=""
attempt=0
while [ "$attempt" -lt 30 ]; do
	attempt=$((attempt + 1))
	sleep 2
	latest_id=$(gh run list --workflow="$workflow" --limit 1 \
		--json databaseId -q '.[0].databaseId' 2>/dev/null || echo "")
	if [ -n "$latest_id" ] && [ "$latest_id" != "$old_id" ]; then
		new_id="$latest_id"
		break
	fi
done

if [ -z "$new_id" ]; then
	echo "error: no new workflow run appeared" >&2
	exit 1
fi

printf '==> watching run %s\n' "$new_id"
gh run watch "$new_id" --exit-status
