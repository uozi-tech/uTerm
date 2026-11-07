#!/usr/bin/env bash
# Upload the Sparkle appcast and DMG artifacts to Alibaba Cloud OSS via curl.
# Credentials are read from a repo-root .env file (never committed).
set -euo pipefail

DRY_RUN=0
# --file LOCAL NAME (repeatable): upload just these files to $OSS_PREFIX/NAME instead of the appcast and DMGs.
FILES=()
while [ "$#" -gt 0 ]; do
	case "$1" in
		--dry-run)
			DRY_RUN=1
			;;
		--file)
			if [ "$#" -lt 3 ]; then
				echo "ERROR: --file needs a local path and a remote name" >&2
				exit 1
			fi
			FILES+=("$2" "$3")
			shift 2
			;;
		-h|--help)
			echo "Usage: $0 [--dry-run] [--file LOCAL NAME]..."
			echo "Without --file: upload build/appcast (appcast.xml and DMGs)."
			echo "Environment: ENV_FILE=/path/to/.env"
			exit 0
			;;
		*)
			echo "ERROR: unknown argument: $1" >&2
			exit 1
			;;
	esac
	shift
done

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: .env not found at $ENV_FILE" >&2
	echo "Copy .env.example to .env and fill in your OSS credentials." >&2
	exit 1
fi

# Load credentials into the environment.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# Validate required tools are available.
if [ "$DRY_RUN" -eq 0 ] && ! command -v curl >/dev/null 2>&1; then
	echo "ERROR: 'curl' is not on PATH." >&2
	exit 1
fi
if [ "$DRY_RUN" -eq 0 ] && ! command -v openssl >/dev/null 2>&1; then
	echo "ERROR: 'openssl' is not on PATH." >&2
	exit 1
fi

# Validate required variables are non-empty.
missing=""
for var in OSS_BUCKET OSS_ACCESS_KEY_ID OSS_ACCESS_KEY_SECRET OSS_ENDPOINT; do
	if [ -z "${!var:-}" ]; then
		missing="$missing $var"
	fi
done
if [ -n "$missing" ]; then
	echo "ERROR: missing required .env variable(s):$missing" >&2
	exit 1
fi

OSS_PREFIX="${OSS_PREFIX:-uTerm}"

APPCAST_DIR="$REPO_ROOT/build/appcast"
if [ ${#FILES[@]} -gt 0 ]; then
	: # single-file mode, see below
elif [ "$DRY_RUN" -eq 0 ] && [ ! -d "$APPCAST_DIR" ]; then
	echo "ERROR: $APPCAST_DIR does not exist. Run 'make appcast' first." >&2
	exit 1
fi

APPCAST_XML="$APPCAST_DIR/appcast.xml"
if [ ${#FILES[@]} -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ ! -f "$APPCAST_XML" ]; then
	echo "ERROR: $APPCAST_XML not found. Run 'make appcast' first." >&2
	exit 1
fi

# Collect DMG artifact(s) produced by generate_appcast.
shopt -s nullglob
DMGS=("$APPCAST_DIR"/*.dmg)
shopt -u nullglob
if [ ${#FILES[@]} -eq 0 ] && [ "$DRY_RUN" -eq 0 ] && [ ${#DMGS[@]} -eq 0 ]; then
	echo "ERROR: no .dmg files in $APPCAST_DIR. Run 'make appcast' first." >&2
	exit 1
fi
if [ "$DRY_RUN" -eq 1 ] && [ ${#DMGS[@]} -eq 0 ]; then
	DMGS=("$APPCAST_DIR/uTerm-VERSION-BUILD.dmg")
fi

OSS_ENDPOINT="${OSS_ENDPOINT#https://}"
OSS_ENDPOINT="${OSS_ENDPOINT#http://}"
OSS_PREFIX="${OSS_PREFIX#/}"
OSS_PREFIX="${OSS_PREFIX%/}"

DEST="https://$OSS_BUCKET.$OSS_ENDPOINT/$OSS_PREFIX/"

if [ "$DRY_RUN" -eq 1 ]; then
	echo "Dry run: no files will be uploaded."
fi
echo "Uploading to $DEST"

content_type_for() {
	case "$1" in
		*.dmg) printf '%s\n' 'application/x-apple-diskimage' ;;
		*.xml) printf '%s\n' 'application/xml' ;;
		*.json) printf '%s\n' 'application/json' ;;
		*.sh|*SHA256SUMS) printf '%s\n' 'text/plain; charset=utf-8' ;;
		*) printf '%s\n' 'application/octet-stream' ;;
	esac
}

# Files replaced in place (appcast, latest.json, install.sh) must not be served stale.
cache_control_for() {
	case "$1" in
		*.xml|*.json|*.sh) printf '%s\n' 'no-cache' ;;
		*) printf '%s\n' 'max-age=86400' ;;
	esac
}

oss_signature() {
	local method="$1"
	local content_type="$2"
	local date_header="$3"
	local object_key="$4"
	local string_to_sign

	string_to_sign="${method}

${content_type}
${date_header}
x-oss-object-acl:public-read
/${OSS_BUCKET}/${object_key}"

	printf '%s' "$string_to_sign" |
		openssl dgst -sha1 -hmac "$OSS_ACCESS_KEY_SECRET" -binary |
		openssl base64
}

oss_object_signature() {
	local method="$1"
	local date_header="$2"
	local object_key="$3"
	local string_to_sign

	string_to_sign="${method}


${date_header}
/${OSS_BUCKET}/${object_key}"

	printf '%s' "$string_to_sign" |
		openssl dgst -sha1 -hmac "$OSS_ACCESS_KEY_SECRET" -binary |
		openssl base64
}

oss_bucket_signature() {
	local method="$1"
	local date_header="$2"
	local string_to_sign

	string_to_sign="${method}


${date_header}
/${OSS_BUCKET}/"

	printf '%s' "$string_to_sign" |
		openssl dgst -sha1 -hmac "$OSS_ACCESS_KEY_SECRET" -binary |
		openssl base64
}

upload() {
	local file="$1"
	local name
	name="${2:-$(basename "$file")}"
	local object_key="$OSS_PREFIX/$name"
	local url="https://$OSS_BUCKET.$OSS_ENDPOINT/$object_key"
	local content_type
	content_type="$(content_type_for "$name")"
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '  curl --fail --show-error --location --request PUT --upload-file %s %s\n' "$file" "$url"
	else
		local date_header
		local signature
		date_header="$(LC_ALL=C TZ=GMT date '+%a, %d %b %Y %H:%M:%S GMT')"
		signature="$(oss_signature PUT "$content_type" "$date_header" "$object_key")"
		curl --fail --show-error --location --request PUT \
			--upload-file "$file" \
			--header "Date: $date_header" \
			--header "Content-Type: $content_type" \
			--header "Cache-Control: $(cache_control_for "$name")" \
			--header "Authorization: OSS $OSS_ACCESS_KEY_ID:$signature" \
			--header "x-oss-object-acl: public-read" \
			"$url"
	fi
	echo "  $url"
}

delete_remote_object() {
	local name="$1"
	local object_key="$OSS_PREFIX/$name"
	local url="https://$OSS_BUCKET.$OSS_ENDPOINT/$object_key"
	if [ "$DRY_RUN" -eq 1 ]; then
		printf '  curl --fail --show-error --location --request DELETE %s\n' "$url"
	else
		local date_header
		local signature
		date_header="$(LC_ALL=C TZ=GMT date '+%a, %d %b %Y %H:%M:%S GMT')"
		signature="$(oss_object_signature DELETE "$date_header" "$object_key")"
		curl --fail --show-error --location --request DELETE \
			--header "Date: $date_header" \
			--header "Authorization: OSS $OSS_ACCESS_KEY_ID:$signature" \
			"$url"
	fi
	echo "  deleted $url"
}

latest_dmg_name_for() {
	local name="$1"
	if [[ "$name" =~ ^(.+)-[0-9]+\.dmg$ ]]; then
		printf '%s.dmg\n' "${BASH_REMATCH[1]}"
	else
		printf '%s\n' "$name"
	fi
}

remote_dmg_names_from_oss() {
	if [ -n "${DRY_RUN_REMOTE_DMGS:-}" ]; then
		printf '%s\n' $DRY_RUN_REMOTE_DMGS
		return
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		return
	fi

	local tmp
	local date_header
	local signature
	tmp="$(mktemp)"
	date_header="$(LC_ALL=C TZ=GMT date '+%a, %d %b %Y %H:%M:%S GMT')"
	signature="$(oss_bucket_signature GET "$date_header")"
	if curl --fail --silent --show-error --location \
		--header "Date: $date_header" \
		--header "Authorization: OSS $OSS_ACCESS_KEY_ID:$signature" \
		"https://$OSS_BUCKET.$OSS_ENDPOINT/?prefix=$OSS_PREFIX/" -o "$tmp"; then
		sed -n 's#.*<Key>\(.*\.dmg\)</Key>.*#\1#p' "$tmp" |
			while IFS= read -r key; do
				printf '%s\n' "${key##*/}"
			done
	fi
	rm -f "$tmp"
}

cleanup_remote_old_dmgs() {
	local remote_names
	remote_names="$(remote_dmg_names_from_oss | sort -u)"
	if [ -z "$remote_names" ]; then
		return
	fi

	echo "Cleaning old remote versioned DMGs:"
	for dmg in "${DMGS[@]}"; do
		local current_name
		local release_prefix
		current_name="$(basename "$dmg")"
		if [[ ! "$current_name" =~ ^(.+)-[0-9]+\.dmg$ ]]; then
			continue
		fi
		release_prefix="${BASH_REMATCH[1]}"

		while IFS= read -r remote_name; do
			local build_suffix
			case "$remote_name" in
				"$release_prefix"-*.dmg) ;;
				*) continue ;;
			esac
			build_suffix="${remote_name#"$release_prefix"-}"
			build_suffix="${build_suffix%.dmg}"
			if [[ ! "$build_suffix" =~ ^[0-9]+$ ]]; then
				continue
			fi
			if [ "$remote_name" = "$current_name" ]; then
				continue
			fi
			delete_remote_object "$remote_name"
		done <<< "$remote_names"
	done
}

if [ ${#FILES[@]} -gt 0 ]; then
	echo "Public URLs:"
	for ((i = 0; i < ${#FILES[@]}; i += 2)); do
		if [ "$DRY_RUN" -eq 0 ] && [ ! -f "${FILES[i]}" ]; then
			echo "ERROR: ${FILES[i]} not found" >&2
			exit 1
		fi
		upload "${FILES[i]}" "${FILES[i + 1]}"
	done
	echo "Done."
	exit 0
fi

cleanup_remote_old_dmgs

echo "Public URLs:"
for dmg in "${DMGS[@]}"; do
	upload "$dmg"
	latest_name="$(latest_dmg_name_for "$(basename "$dmg")")"
	if [ "$latest_name" != "$(basename "$dmg")" ]; then
		upload "$dmg" "$latest_name"
	fi
done
upload "$APPCAST_XML"

echo "Done."
