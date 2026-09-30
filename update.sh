#!/usr/bin/env bash
#
# Rebuilds the F-Droid repository from the upstream GitHub releases of Yōkai
# and Yōkai Nightly.
#
# Requirements (all packaged for Debian/Ubuntu):
#
#   aapt apksigner curl dwebp fdroidserver jq python3 zipalign
#
# Optional environment variables:
#
#   TOKEN   GitHub token. Only needed to raise the API rate limit, every
#           release, asset and raw file used here is public.
#
# The script expects fdroid/config.yml and fdroid/keystore.keystore to already
# exist. Both are materialised by .github/workflows/github.yml, which also
# provides $TOKEN. The key material is needed at runtime as well, because the
# APKs whose version code is changed are signed again with it, so $KEYALIAS,
# $KEYSTORE_PASS and $KEY_PASSWORD have to be in the environment.

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
# metadata key to override it with, so the APK itself is rewritten before the
# index is generated. See rewrite_version_code.
declare -A VERSION_CODE_FROM_TAG=(
	["eu.kanade.tachiyomi.yokai"]="no"
	["eu.kanade.tachiyomi.nightlyYokai"]="yes"
)

# Whether the APK is rebuilt to carry the published version code. Rebuilding
# breaks the signature, so the APK is signed again with the repository key and is
# no longer the binary upstream released. This is kept separate from
# VERSION_CODE_FROM_TAG because taking the version code from the release tag is
# what decides *which* code is published, while this decides whether the shipped
# APK has to be rebuilt to match.
declare -A REPACK_APK=(
	["eu.kanade.tachiyomi.yokai"]="no"
	["eu.kanade.tachiyomi.nightlyYokai"]="yes"
)

declare -a APP_IDS=(
	"eu.kanade.tachiyomi.yokai"
	"eu.kanade.tachiyomi.nightlyYokai"
)

# Every APK this run publishes, across every package. See prune_unpublished_apks
# for why the set has to be complete before anything is removed.
declare -a PUBLISHED_APKS=()

# The APK variants published for every package. Upstream builds one APK per ABI
# plus a universal one, and all of them carry the same version code, which is
# what lets an F-Droid client pick the one that fits the device.
#
# "universal" is always published: it is the only variant that runs on every
# device, so it is the fallback for anything the client cannot match, including
# clients too old to know about variants at all. arm64-v8a is published next to
# it because that is the ABI of effectively every phone worth installing on, and
# it is roughly a third of the size. The remaining ABIs are deliberately left
# out: a 32 bit armeabi-v7a device simply downloads the universal build, which
# is a larger download but never a broken one.
#
# The variants are published for both packages, so the two always look the same.
declare -a VARIANTS=(
	"universal"
	"arm64-v8a"
)

# The ABI a variant is built for, "universal" being the empty string. This is
# what the asset is named after, and what is checked against the native code the
# APK itself declares.
declare -A VARIANT_ABI=(
	["universal"]=""
	["arm64-v8a"]="arm64-v8a"
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
	# The first match is taken with a second sed rather than with `head`, which
	# stops reading as soon as it has a line: the writer then dies of SIGPIPE and
	# `set -o pipefail` turns that into a failure. A sed with `1p` reads the whole
	# input and prints one line of it.
	sed -n "s/.*$2'\\([^']*\\)'.*/\\1/p" <<< "$1" | sed -n '1p'
}

# nativecode_field "<aapt dump badging output>"
#
# Collects every ABI the APK declares as one comma separated list. The values are
# quoted one after another, and whether aapt puts them all on a single
# "native-code:" line or on a line each depends on the build tools, so the commas
# are turned into line breaks first and both layouts end up the same way. Joining
# with awk rather than with paste keeps the tool list of the script as it is.
nativecode_field() {
	sed -n 's/^[[:space:]]*native-code:[[:space:]]*//p' <<< "$1" |
		tr ',' '\n' |
		sed -n "s/^[[:space:]]*'\([^']*\)'.*/\\1/p" |
		awk 'NR > 1 { printf "," } { printf "%s", $0 }'
}

# select_asset <release json> <tag> <variant>
#
# Prints the download url of one variant of a release, and nothing if the
# release does not have it. Upstream names the universal build after the tag
# alone, "yokai-r6433.apk", and every other variant after the ABI it is built
# for, "yokai-arm64-v8a-r6433.apk", so the name is derived rather than matched
# against a list of ABIs: an ABI this repository does not publish then simply has
# no asset to find.
select_asset() {
	local release_json="$1" tag="$2" variant="$3"

	if [[ "$variant" != "universal" ]]; then
		local abi="${VARIANT_ABI[$variant]:-}"

		# A variant that is not in VARIANT_ABI is not published, so it has no asset.
		# Returning nothing here rather than dereferencing an unset key keeps a
		# typo in the variant list from taking the whole run down.
		[[ -n "$abi" ]] || return 0

		jq -r --arg name "yokai-$abi-$tag.apk" \
			'[.assets[] | select(.name == $name)][0].browser_download_url // empty' \
			"$release_json"
		return
	fi

	# The universal build is named after the tag alone. If that name has gone, any
	# APK that is not named after an ABI or a build type is taken as the universal
	# one, which is what the several tens of megabytes of each of the others says
	# they are not.
	local exact
	exact=$(jq -r --arg name "yokai-$tag.apk" \
		'[.assets[] | select(.name == $name)][0].browser_download_url // empty' \
		"$release_json")
	if [[ -n "$exact" ]]; then
		printf '%s' "$exact"
		return
	fi

	warn "no 'yokai-$tag.apk' asset, looking for a build that is not named after an ABI"
	jq -r '[.assets[]
		| select(.name | test("\\.apk$"))
		| select(.name | test("arm64-v8a|armeabi-v7a|x86_64|x86|debug"; "i") | not)
	][0].browser_download_url // empty' "$release_json"
}

# check_nativecode <variant> <apk file name> "<the ABIs the APK declares>"
#
# The asset name says which ABI a variant is, but the name is upstream's word
# for it, so what the APK itself declares is what is checked. For the universal
# build it is the stronger of the two checks: that build is the fallback for
# every device, so it has to carry the ABIs that are also published on their own.
check_nativecode() {
	local variant="$1" asset="$2" actual="$3"

	if [[ -z "$actual" ]]; then
		warn "$asset declares no native code, a client may refuse to install it"
		return
	fi

	if [[ "$variant" != "universal" ]]; then
		local abi="${VARIANT_ABI[$variant]:-}"
		[[ "$actual" == "$abi" ]] ||
			die "$asset should be built for $abi alone but declares $actual"
		return
	fi

	local published wanted
	for published in "${VARIANTS[@]}"; do
		wanted="${VARIANT_ABI[$published]}"
		if [[ -z "$wanted" ]]; then
			continue
		fi
		if [[ ",$actual," != *",$wanted,"* ]]; then
			die "$asset is the universal build but does not declare $wanted," \
				"which is published as a variant of its own"
		fi
	done
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
	local release_json tag variant url version_code apk_path
	local -a apk_paths=() upstream_codes=() distinct_codes=()

	[[ -f "$metadata" ]] || die "missing metadata file $metadata"

	log "$app_id: looking up the latest release of $upstream"
	release_json=$(mktemp)
	api_curl -o "$release_json" "$GITHUB_API/repos/$upstream/releases/latest"

	tag=$(jq -r '.tag_name' "$release_json")
	[[ -n "$tag" && "$tag" != "null" ]] || die "$upstream has no published release"

	# Every variant has to carry the version code the index is generated from, so
	# the code is decided once here, from the tag or from the universal APK, and
	# every APK is then made to declare it. The variants of one release already
	# agree upstream, which is checked rather than assumed.
	for variant in "${VARIANTS[@]}"; do
		url=$(select_asset "$release_json" "$tag" "$variant")

		if [[ -z "$url" ]]; then
			if [[ "$variant" == "universal" ]]; then
				die "the $tag release of $upstream has no universal APK"
			fi
			# An optional variant that upstream stopped shipping is not a reason
			# to stop publishing the package: the universal build is still there
			# for every device.
			warn "$upstream ships no $variant build in $tag, publishing the universal one only"
			continue
		fi

		install_variant "$app_id" "$variant" "$url"
		apk_paths+=("$REPO_DIR/${url##*/}")
		upstream_codes+=("$LAST_UPSTREAM_VERSION_CODE")
	done

	[[ "${#apk_paths[@]}" -gt 0 ]] || die "no APK to publish for $app_id"

	read -r -a distinct_codes <<< "$(printf '%s\n' "${upstream_codes[@]}" | sort -u)"
	[[ "${#distinct_codes[@]}" -eq 1 ]] ||
		die "the variants of $tag declare different version codes: ${upstream_codes[*]}"

	if [[ "${VERSION_CODE_FROM_TAG[$app_id]}" == "yes" ]]; then
		version_code="${tag#r}"
		[[ "$version_code" =~ ^[0-9]+$ ]] ||
			die "expected a nightly tag of the form r<number>, got $tag"
		log "$app_id: publishing it as version code $version_code"
	else
		version_code="${upstream_codes[0]}"
	fi

	# fdroidserver takes the version code for the index out of the APK, so an APK
	# that keeps upstream's code would be published under that code no matter
	# what the metadata or the release tag say, and a variant left on a different
	# code would be offered as its own update instead of as the same release.
	if [[ "${REPACK_APK[$app_id]}" == "yes" ]]; then
		for apk_path in "${apk_paths[@]}"; do
			rewrite_version_code "$app_id" "$apk_path" "${upstream_codes[0]}" "$version_code"
		done
	fi

	log "$app_id: publishing ${#apk_paths[@]} variant(s):"
	for apk_path in "${apk_paths[@]}"; do
		log "  $(basename "$apk_path")"
	done

	PUBLISHED_APKS+=("${apk_paths[@]}")

	log "$app_id: pointing the metadata at $tag"
	set_yaml_key "CurrentVersion" "$tag" "$metadata"
	set_yaml_key "CurrentVersionCode" "$version_code" "$metadata"

	write_changelog "$app_id" "$version_code" "$release_json"
	refresh_assets "$app_id" "$asset_repo"

	rm -f "$release_json"
}

# install_variant <package> <variant> <download url>
#
# Downloads one variant, checks that it is the APK it is supposed to be, and
# leaves it in the repository directory. The version code it declares is returned
# in LAST_UPSTREAM_VERSION_CODE for the caller, which is the only place that
# decides what the published version code is: every variant of a release has to
# end up with the same one.
install_variant() {
	local app_id="$1" variant="$2" url="$3"
	# These are two declarations on purpose: a single "local asset=... apk_path=$asset"
	# expands the second word before the first assignment has run, and under
	# set -u that ends the build on the first variant.
	local asset="${url##*/}"
	local apk_path="$REPO_DIR/$asset"
	local tmp badging package version_code label split nativecode

	log "$app_id: downloading the $variant build, $asset"
	tmp=$(mktemp)
	fetch_curl -o "$tmp" "$url"
	mv "$tmp" "$apk_path"

	log "$app_id: reading the badging of $asset"
	badging=$(aapt dump badging "$apk_path")
	package=$(badging_field "$badging" "package: name=")
	version_code=$(badging_field "$badging" "versionCode=")
	label=$(badging_field "$badging" "application-label:")

	[[ -n "$package" && -n "$version_code" ]] ||
		die "could not parse the badging of $asset"
	[[ -n "$label" ]] || label="$app_id"

	[[ "$package" == "$app_id" ]] ||
		die "expected $app_id but $asset declares $package"

	# An asset that turned into a real split would have to be installed together
	# with the rest of its set, so publishing it on its own would leave a device
	# that picked it with a broken app. The sizes upstream ships these at (a few
	# tens of MB, one per ABI) say they are standalone builds of the whole app,
	# and this keeps that true.
	split=$(badging_field "$badging" "split=")
	[[ -z "$split" ]] ||
		die "$asset is the split $split of $app_id, not a standalone build"

	nativecode=$(nativecode_field "$badging")
	check_nativecode "$variant" "$asset" "$nativecode"

	log "$app_id: $label $(badging_field "$badging" "versionName=")," \
		"upstream version code $version_code"

	LAST_UPSTREAM_VERSION_CODE="$version_code"
}

# Removes any APK in the repository directory that this run did not publish. A
# leftover from an earlier run would be indexed next to the current version and
# offered to a client as an update. CI starts from a fresh checkout every time,
# so this only ever has anything to do for a local run.
#
# The list has to be every APK of every package, not one package's: both packages
# are built from APKs named after the release, "yokai-v1.10.2.apk" and
# "yokai-r6433.apk" side by side, so a package cannot tell its own APKs apart from
# another package's by name. Pruning per package takes the other package's APKs
# with it, and the index that is built afterwards then loses a whole app.
prune_unpublished_apks() {
	# The published paths are reduced to file names first, because that is what the
	# directory listing below yields, and comparing a path against a file name
	# would match nothing and take every APK with it.
	local keep=" " name
	for name in "$@"; do
		keep+="${name##*/} "
	done

	local apk
	local -a stale=()

	# An if is used instead of `[[ … ]] && continue` on purpose: a test that fails
	# as the last command of the loop body would make the whole script exit under
	# set -e, taking the run down for a leftover file that is not even an error.
	while IFS= read -r apk; do
		[[ -n "$apk" ]] || continue
		if [[ "$keep" != *" ${apk##*/} "* ]]; then
			stale+=("$apk")
		fi
	done < <(find "$REPO_DIR" -maxdepth 1 -name '*.apk' -type f)

	if (( ${#stale[@]} == 0 )); then
		return
	fi

	log "removing ${#stale[@]} APK(s) left by an earlier run"
	for apk in "${stale[@]}"; do
		log "  $(basename "$apk")"
		rm -f "$apk"
	done

	return 0
}

# Sets a new version code in the APK and signs the result with the repository
# key.
#
# Android refuses to install a differently signed APK over an existing one, so
# this means the result is not the binary upstream released: anyone who already
# has an upstream signed build of the same package has to uninstall it first.
# That is a deliberate trade for a version code that lets F-Droid clients see the
# nightly as an update, and it only applies to the packages in REPACK_APK.
rewrite_version_code() {
	local app_id="$1" apk_path="$2" from="$3" to="$4"
	local work badging output patched

	if [[ "$from" == "$to" ]]; then
		log "$app_id: its version code is already $to, the APK is left alone"
		return
	fi

	[[ -n "${KEYALIAS:-}" && -n "${KEYSTORE_PASS:-}" && -n "${KEY_PASSWORD:-}" ]] ||
		die "the repository key is not available, cannot re-sign $apk_path"
	[[ -f "$FDROID_DIR/keystore.keystore" ]] ||
		die "$FDROID_DIR/keystore.keystore is missing, cannot sign $apk_path"
	[[ -f "$SCRIPT_DIR/patch-manifest-version-code.py" ]] ||
		die "$SCRIPT_DIR/patch-manifest-version-code.py is missing"

	work=$(mktemp -d)
	patched="$work/patched.apk"

	log "$app_id: setting the version code of $(basename "$apk_path") $from -> $to"
	# Only the four bytes of the version code in the binary manifest change, so
	# every other byte of the APK, and every resource in it, is upstream's. The
	# intermediate is named here rather than left beside the download, so that the
	# removal of $work at the end is enough to clean it up.
	if ! output=$(python3 "$SCRIPT_DIR/patch-manifest-version-code.py" \
		-o "$patched" "$apk_path" "$to" "$from"); then
		die "could not set the version code of $(basename "$apk_path") to $to"
	fi
	log "$app_id: $output"

	# The alignment has to happen before signing, never after.
	zipalign -p -f 4 "$patched" "$work/aligned.apk" ||
		die "could not align the patched $(basename "$apk_path")"

	# The passwords go through the environment rather than the command line so
	# they do not end up in the process list of the container.
	apksigner sign \
		--ks "$FDROID_DIR/keystore.keystore" \
		--ks-key-alias "$KEYALIAS" \
		--ks-pass env:KEYSTORE_PASS \
		--key-pass env:KEY_PASSWORD \
		--out "$work/signed.apk" \
		"$work/aligned.apk" ||
		die "could not sign the patched $(basename "$apk_path")"
	apksigner verify --min-sdk-version 26 "$work/signed.apk" ||
		die "the re-signed $(basename "$apk_path") does not verify"

	# The index is generated out of the badging of whatever ends up in the
	# repository, so this is the last point where a wrong package or version
	# code can still be caught before it is published.
	badging=$(aapt dump badging "$work/signed.apk") ||
		die "could not read the badging of the re-signed $(basename "$apk_path")"
	[[ "$(badging_field "$badging" "package: name=")" == "$app_id" ]] ||
		die "the re-signed $(basename "$apk_path") is no longer $app_id"
	[[ "$(badging_field "$badging" "versionCode=")" == "$to" ]] ||
		die "the re-signed $(basename "$apk_path") declares version code $(badging_field "$badging" "versionCode=") instead of $to"

	mv -f "$work/signed.apk" "$apk_path"
	rm -rf "$work"
	log "$app_id: $(basename "$apk_path") now declares version code $to and is signed by the repository key"
}

# fdroidserver generates a signed index per format and clients read whichever
# format they support, so the published set is worth reporting: every one of
# these files has to agree, and none of them can be hand edited afterwards
# without re-signing all of them.
log_index_files() {
	local file

	for file in "$REPO_DIR"/index* "$REPO_DIR"/entry*; do
		[[ -f "$file" ]] || continue
		log "$(basename "$file") ($(stat -c %s "$file") bytes)"
	done
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

	for tool in aapt apksigner curl dwebp fdroid jq mktemp python3 zipalign; do
		require "$tool"
	done

	[[ -f "$FDROID_DIR/config.yml" ]] ||
		die "$FDROID_DIR/config.yml is missing, copy it into place first"
	[[ -f "$FDROID_DIR/keystore.keystore" ]] ||
		die "$FDROID_DIR/keystore.keystore is missing, copy it into place first"

	mkdir -p "$REPO_DIR" "$METADATA_DIR"

	local app_id
	for app_id in "${APP_IDS[@]}"; do
		update_app "$app_id"
	done

	prune_unpublished_apks "${PUBLISHED_APKS[@]}"

	log "running fdroid update"
	if ! ( cd "$FDROID_DIR" && fdroid update --pretty --use-date-from-apk ); then
		die "fdroid update failed"
	fi

	# fdroid update replaces a missing repository icon with a generated
	# placeholder, so the real one goes in afterwards.
	publish_repo_icon
	log_index_files
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
