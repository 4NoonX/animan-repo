#!/usr/bin/env bash
#
# Rebuilds the F-Droid repository from the upstream GitHub releases of Yōkai
# and Yōkai Nightly.
#
# Requirements (all packaged for Debian/Ubuntu):
#
#   aapt curl dwebp fdroidserver jq python3
#
# Optional environment variables:
#
#   TOKEN   GitHub token. Only needed to raise the API rate limit, every
#           release, asset and raw file used here is public.
#
# The script expects fdroid/config.yml and fdroid/keystore.keystore to already
# exist. Both are materialised by .github/workflows/github.yml, which also
# provides $TOKEN.

set -euo pipefail

# "set -e" exits on a failing command without saying which one, and a silent
# exit from a three hundred line script is not something to debug from a
# workflow log.
trap 'status=$?; printf "\033[0;31merror:\033[0m %s exited with status %d\n" "$BASH_COMMAND" "$status" >&2; exit "$status"' ERR

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

GITHUB_API="https://api.github.com"
RAW_GITHUB="https://raw.githubusercontent.com"

FDROID_DIR="fdroid"
REPO_DIR="$FDROID_DIR/repo"
METADATA_DIR="$FDROID_DIR/metadata"

# Upstream branch the icon and the screenshots are taken from.
ASSET_REF="master"

# How many changelogs are kept around per package.
CHANGELOG_HISTORY=20

TOKEN="${TOKEN:-}"

# Upstream repository every package is built from.
declare -A UPSTREAM_REPO=(
	["eu.kanade.tachiyomi.yokai"]="null2264/yokai"
	["eu.kanade.tachiyomi.nightlyYokai"]="null2264/yokai-nightly"
)

# Repository the icon and the screenshots are taken from. Both flavours use
# the assets of the main repository.
declare -A ASSET_REPO=(
	["eu.kanade.tachiyomi.yokai"]="null2264/yokai"
	["eu.kanade.tachiyomi.nightlyYokai"]="null2264/yokai"
)

# Yōkai Nightly reuses the Android version code of the stable release, so every
# nightly build would look identical to the previous one and F-Droid clients
# would never see an update. The version code published for the nightlies is
# therefore taken from the release tag, which upstream builds as
# "r<number of commits in master>" and which grows monotonically.
#
# fdroidserver publishes the version code it reads out of the APK and has no
# metadata key to override it with, so the index is corrected once
# "fdroid update" has written it. See pin-version-code.py.
declare -A VERSION_CODE_FROM_TAG=(
	["eu.kanade.tachiyomi.yokai"]="no"
	["eu.kanade.tachiyomi.nightlyYokai"]="yes"
)

# The version code each package ended up being published under, filled in by
# update_app and read back by pin_index_version_code.
declare -A PUBLISHED_VERSION_CODE=()

declare -a APP_IDS=(
	"eu.kanade.tachiyomi.yokai"
	"eu.kanade.tachiyomi.nightlyYokai"
)

log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require() {
	command -v "$1" > /dev/null 2>&1 || die "$1 is required but was not found in \$PATH"
}

# curl wrapper that talks to the GitHub API with a fixed set of headers.
api_curl() {
	local -a headers=(
		--header "Accept: application/vnd.github+json"
		--header "X-GitHub-Api-Version: 2022-11-28"
	)

	if [[ -n "$TOKEN" ]]; then
		headers+=(--header "Authorization: Bearer $TOKEN")
	fi

	curl --silent --show-error --fail --location --retry 3 --retry-delay 2 \
		"${headers[@]}" "$@"
}

# Release assets and raw files are public, so they are fetched without the
# token to avoid leaking it to a redirect target.
fetch_curl() {
	curl --silent --show-error --fail --location --retry 3 --retry-delay 2 "$@"
}

# badging_field "<aapt dump badging output>" "<field prefix including the separator>"
#
# aapt is not consistent about its separator, it prints "name='foo'" for the
# fields of the "package:" line but "sdkVersion:'26'" and
# "application-label:'Yokai'" for the others, so the caller passes the prefix
# together with its '=' or ':'.
badging_field() {
	sed -n "s/.*$2'\\([^']*\\)'.*/\\1/p" <<< "$1" | head -n 1
}

# set_yaml_key <key> <value> <file>
#
# Replaces a top level key, keeping the key where it is so the file stays
# readable and diffable. A key that is not there yet is appended.
set_yaml_key() {
	local key="$1" value="$2" file="$3" tmp

	tmp=$(mktemp)
	if awk -v key="$key" -v value="$value" '
		index($0, key ":") == 1 { print key ": " value; found = 1; next }
		{ print }
		END { exit !found }
	' "$file" > "$tmp"; then
		mv "$tmp" "$file"
		return
	fi

	warn "'$key' is missing from $file, appending it"
	printf '%s: %s\n' "$key" "$value" >> "$file"
	rm -f "$tmp"
}

# Drops the checksum table upstream appends to every release body, it is
# noise in an F-Droid changelog.
strip_checksums() {
	sed '/^### Checksums$/,$d'
}

refresh_assets() {
	local app_id="$1" asset_repo="$2"
	local icon_dir="$REPO_DIR/$app_id/en-US"
	local remote local_name tmp

	log "$app_id: refreshing the icon and the screenshots"
	mkdir -p "$icon_dir/phoneScreenshots"

	tmp=$(mktemp)
	if fetch_curl -o "$tmp" \
		"$RAW_GITHUB/$asset_repo/$ASSET_REF/.github/readme-images/app-icon.webp"; then
		dwebp -quiet -o "$icon_dir/icon.png" "$tmp" ||
			warn "could not convert the upstream icon, keeping the previous one"
	else
		warn "could not download the upstream icon, keeping the previous one"
	fi
	rm -f "$tmp"

	local -a screenshots=(
		"material%20snackbar.png|material-snackbar.png"
		"share%20menu.png|share-menu.png"
	)

	for remote in "${screenshots[@]}"; do
		local_name="${remote##*|}"
		remote="${remote%%|*}"
		fetch_curl -o "$icon_dir/phoneScreenshots/$local_name" \
			"$RAW_GITHUB/$asset_repo/$ASSET_REF/.github/readme-images/$remote" ||
			warn "could not download $remote"
	done
}

write_changelog() {
	local app_id="$1" version_code="$2" release_json="$3"
	local dir="$METADATA_DIR/$app_id/en-US/changelogs"
	local file="$dir/$version_code.txt" tmp
	local -a existing=()

	mkdir -p "$dir"

	tmp=$(mktemp)
	jq -r '.body // ""' "$release_json" | strip_checksums | awk '
		{ lines[NR] = $0 }
		END {
			start = 1
			while (start <= NR && lines[start] ~ /^[[:space:]]*$/) start++
			end = NR
			while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
			for (i = start; i <= end; i++) print lines[i]
		}
	' > "$tmp"

	if [[ ! -s "$tmp" ]]; then
		warn "the release body is empty"
		printf '%s\n' "$app_id $version_code" > "$tmp"
	fi

	if [[ ! -f "$file" ]] || ! cmp -s "$tmp" "$file"; then
		mv "$tmp" "$file"
		log "$app_id: changelog written to fdroid/metadata/$app_id/en-US/changelogs/$version_code.txt"
	else
		rm -f "$tmp"
	fi

	mapfile -t existing < <(find "$dir" -maxdepth 1 -type f -name '*.txt' | sort -V)
	if (( ${#existing[@]} > CHANGELOG_HISTORY )); then
		log "$app_id: pruning $(( ${#existing[@]} - CHANGELOG_HISTORY )) old changelog(s)"
		rm -f "${existing[@]:0:${#existing[@]} - CHANGELOG_HISTORY}"
	fi
}

update_app() {
	local app_id="$1"
	local upstream="${UPSTREAM_REPO[$app_id]}"
	local asset_repo="${ASSET_REPO[$app_id]}"
	local metadata="$METADATA_DIR/$app_id.yml"
	local release_json tag asset apk_url apk_path tmp
	local badging apk_package apk_version_code apk_version_name apk_label version_code

	[[ -f "$metadata" ]] || die "missing metadata file $metadata"

	log "$app_id: looking up the latest release of $upstream"
	release_json=$(mktemp)
	api_curl -o "$release_json" "$GITHUB_API/repos/$upstream/releases/latest"

	tag=$(jq -r '.tag_name' "$release_json")
	[[ -n "$tag" && "$tag" != "null" ]] || die "$upstream has no published release"

	# Upstream names the universal build "yokai-<tag>.apk" and every other
	# asset after an ABI it is built for.
	apk_url=$(jq -r --arg name "yokai-$tag.apk" \
		'[.assets[] | select(.name == $name)][0].browser_download_url // empty' "$release_json")

	if [[ -z "$apk_url" ]]; then
		warn "no 'yokai-$tag.apk' asset, looking for an ABI independent build instead"
		apk_url=$(jq -r '[.assets[]
			| select(.name | test("\\.apk$"))
			| select(.name | test("arm64-v8a|armeabi-v7a|x86_64|x86|debug"; "i") | not)
		][0].browser_download_url // empty' "$release_json")
	fi

	[[ -n "$apk_url" ]] || die "no suitable APK asset in the $tag release of $upstream"

	asset="${apk_url##*/}"
	apk_path="$REPO_DIR/$asset"

	log "$app_id: downloading $asset"
	tmp=$(mktemp)
	fetch_curl -o "$tmp" "$apk_url"
	mv "$tmp" "$apk_path"

	log "$app_id: reading the badging of $asset"
	badging=$(aapt dump badging "$apk_path")
	apk_package=$(badging_field "$badging" "package: name=")
	apk_version_code=$(badging_field "$badging" "versionCode=")
	apk_version_name=$(badging_field "$badging" "versionName=")
	apk_label=$(badging_field "$badging" "application-label:")

	[[ -n "$apk_package" && -n "$apk_version_code" ]] ||
		die "could not parse the badging of $asset"
	[[ -n "$apk_label" ]] || apk_label="$app_id"

	[[ "$apk_package" == "$app_id" ]] ||
		die "expected $app_id but $asset declares $apk_package"

	log "$app_id: $apk_label $apk_version_name, upstream version code $apk_version_code"

	if [[ "${VERSION_CODE_FROM_TAG[$app_id]}" == "yes" ]]; then
		version_code="${tag#r}"
		[[ "$version_code" =~ ^[0-9]+$ ]] ||
			die "expected a nightly tag of the form r<number>, got $tag"
		log "$app_id: publishing it as version code $version_code"
	else
		version_code="$apk_version_code"
	fi

	log "$app_id: pointing the metadata at $tag"
	set_yaml_key "CurrentVersion" "$tag" "$metadata"
	set_yaml_key "CurrentVersionCode" "$version_code" "$metadata"
	PUBLISHED_VERSION_CODE["$app_id"]="$version_code"

	write_changelog "$app_id" "$version_code" "$release_json"
	refresh_assets "$app_id" "$asset_repo"

	rm -f "$release_json"
}

# F-Droid clients decide whether an update is available by comparing the
# version code in the index with the one they recorded at install time, so the
# index is what has to carry the number taken from the release tag. The APK
# itself is left alone: it is signed by upstream and its manifest still says
# 162, which only ever shows up as the "version code" line in the app details.
pin_index_version_code() {
	local app_id="$1" version_code="$2"
	local index="$REPO_DIR/index.xml"
	local output

	[[ -f "$index" ]] || die "$index was not generated"

	if ! output=$(python3 "$SCRIPT_DIR/pin-version-code.py" "$index" "$app_id" "$version_code"); then
		die "could not publish $app_id as version code $version_code"
	fi

	if [[ -n "$output" ]]; then
		log "$output"
	fi
}

# fdroidserver expects a repository icon at a fixed place and only warns when
# it is missing, so the upstream app icon is reused for the repository itself.
publish_repo_icon() {
	local source="$REPO_DIR/eu.kanade.tachiyomi.yokai/en-US/icon.png"
	local target="$REPO_DIR/icons/icon.png"

	[[ -f "$source" ]] || { warn "the upstream icon is missing, not publishing a repository icon"; return; }

	mkdir -p "$REPO_DIR/icons"
	cp -f "$source" "$target" || warn "could not publish a repository icon"
	[[ -f "$target" ]] || { warn "the repository icon is still missing"; return; }
	log "published the repository icon"
}

main() {
	local tool

	for tool in aapt curl dwebp fdroid jq mktemp python3; do
		require "$tool"
	done

	[[ -f "$SCRIPT_DIR/pin-version-code.py" ]] ||
		die "$SCRIPT_DIR/pin-version-code.py is missing"

	[[ -f "$FDROID_DIR/config.yml" ]] ||
		die "$FDROID_DIR/config.yml is missing, copy it into place first"
	[[ -f "$FDROID_DIR/keystore.keystore" ]] ||
		die "$FDROID_DIR/keystore.keystore is missing, copy it into place first"

	mkdir -p "$REPO_DIR" "$METADATA_DIR"

	local app_id
	for app_id in "${APP_IDS[@]}"; do
		update_app "$app_id"
	done

	log "running fdroid update"
	if ! ( cd "$FDROID_DIR" && fdroid update --pretty --use-date-from-apk ); then
		die "fdroid update failed"
	fi

	# fdroid update replaces a missing repository icon with a generated
	# placeholder, so the real one goes in afterwards.
	publish_repo_icon

	for app_id in "${APP_IDS[@]}"; do
		if [[ "${VERSION_CODE_FROM_TAG[$app_id]}" == "yes" ]]; then
			pin_index_version_code "$app_id" "${PUBLISHED_VERSION_CODE[$app_id]}"
		fi
	done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
