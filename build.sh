#!/bin/sh
# Build kippsrv and kippbus, test them, install them, or start the release
# workflow. Run download-deps.sh one time before this script.
set -eu

cd "$(dirname "$0")"
out=build
basu=vendor/basu/build

usage() {
	cat <<EOF
usage: $(basename "$0") [test | install] [--version vX.Y.Z]
       $(basename "$0") --public --version vX.Y.Z [--notes "text"] [--prerelease]

  (no flag)             kippsrv and kippbus into build/, which git ignores
  test                  build, then lint, unit tests and the round trip checks
  install               build, then install under \$PREFIX (/usr/local), staged in \$DESTDIR.
                        For a package; a person runs build/kippsrv --install
  --version <tag>       stamp the build, so kippsrv --version prints it
  --public              trigger release.yml through the gh CLI, which builds the tag
  --notes <text>        release notes
  --prerelease          mark the release as a pre-release
EOF
}

mode=build
public=0
version=""
notes=""
prerelease=false
while [ $# -gt 0 ]; do
	case "$1" in
		test|install) mode="$1"; shift ;;
		--public)     public=1; shift ;;
		--version)    version="${2:-}"; shift 2 ;;
		--notes)      notes="${2:-}"; shift 2 ;;
		--prerelease) prerelease=true; shift ;;
		-h|--help)    usage; exit 0 ;;
		*) echo "unknown flag: $1" >&2; usage; exit 1 ;;
	esac
done

# kippbus links basu statically: vendor/basu/build holds libbasu.a and nothing
# else to link against. LDFLAGS goes to both links; a release sets -static.
build() {
	if [ ! -f "$basu/libbasu.a" ]; then
		echo "error: basu is not built. Run ./download-deps.sh first" >&2
		exit 1
	fi
	mkdir -p "$out"
	odin build src -out:"$out/kippsrv" ${version:+-define:VERSION="$version"} -extra-linker-flags:"${LDFLAGS:-}"
	odin build bus -out:"$out/kippbus" -extra-linker-flags:"-L$PWD/$basu ${LDFLAGS:-}"
}

if [ "$public" = 0 ]; then
	build
	case "$mode" in
		test)
			tests/lint.sh
			odin test tests
			tests/check.sh ;;
		install)
			# PREFIX= (empty) is valid: a release stages a bare prefix tree.
			target="${DESTDIR:-}${PREFIX-/usr/local}"
			install -Dm755 -t "$target/bin" "$out/kippsrv" "$out/kippbus"
			install -Dm644 -t "$target/share/kippsrv/sources.d" sources.d/*.lua ;;
	esac
	exit 0
fi

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
