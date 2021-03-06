#!/bin/bash
set -Eeuo pipefail

defaultDebianSuite='stretch'
declare -A debianSuite=(
	[1.8]='jessie'
	[1.7]='jessie'
)
defaultAlpineVersion='3.6'
declare -A alpineVersion=(
	[1.7]='3.4'
	[1.8]='3.5'
)

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

source '.architectures-lib'

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

# see http://stackoverflow.com/a/2705678/433558
sed_escape_lhs() {
	echo "$@" | sed -e 's/[]\/$*.^|[]/\\&/g'
}
sed_escape_rhs() {
	echo "$@" | sed -e 's/[\/&]/\\&/g' | sed -e ':a;N;$!ba;s/\n/\\n/g'
}

# https://github.com/golang/go/issues/13220
allGoVersions=()
apiBaseUrl='https://www.googleapis.com/storage/v1/b/golang/o?fields=nextPageToken,items%2Fname'
pageToken=
while [ "$pageToken" != 'null' ]; do
	page="$(curl -fsSL "$apiBaseUrl&pageToken=$pageToken")"
	allGoVersions+=( $(
		echo "$page" \
			| jq -r '.items[].name' \
			| grep -E '^go[0-9].*[.]src[.]tar[.]gz$' \
			| sed -r -e 's!^go!!' -e 's![.]src[.]tar[.]gz$!!'
	) )
	# TODO extract per-version "available binary tarballs" information while we've got it handy here?
	pageToken="$(echo "$page" | jq -r '.nextPageToken')"
done

travisEnv=
appveyorEnv=
for version in "${versions[@]}"; do
	rcVersion="${version%-rc}"
	rcGrepV='-v'
	if [ "$rcVersion" != "$version" ]; then
		rcGrepV=
	fi
	rcGrepV+=' -E'
	rcGrepExpr='beta|rc'

	fullVersion="$(
		echo "${allGoVersions[@]}" | xargs -n1 \
			| grep $rcGrepV -- "$rcGrepExpr" \
			| grep -E "^${rcVersion}([.a-z]|$)" \
			| sort -V \
			| tail -1
	)" || true
	if [ -z "$fullVersion" ]; then
		echo >&2 "warning: cannot find full version for $version"
		continue
	fi
	fullVersion="${fullVersion#go}" # strip "go" off "go1.4.2"

	# https://github.com/golang/build/commit/24f7399f96feb8dd2fc54f064e47a886c2f8bb4a
	srcSha256="$(curl -fsSL "https://storage.googleapis.com/golang/go${fullVersion}.src.tar.gz.sha256")"
	if [ -z "$srcSha256" ]; then
		echo >&2 "warning: cannot find sha256 for $fullVersion src tarball"
		continue
	fi

	linuxArchCase='dpkgArch="$(dpkg --print-architecture)"; '$'\\\n'
	linuxArchCase+=$'\t''case "${dpkgArch##*-}" in '$'\\\n'
	for dpkgArch in $(dpkgArches "$version"); do
		goArch="$(dpkgToGoArch "$version" "$dpkgArch")"
		sha256="$(curl -fsSL "https://storage.googleapis.com/golang/go${fullVersion}.linux-${goArch}.tar.gz.sha256")"
		if [ -z "$sha256" ]; then
			echo >&2 "warning: cannot find sha256 for $fullVersion on arch $goArch"
			continue 2
		fi
		linuxArchCase+=$'\t\t'"$dpkgArch) goRelArch='linux-$goArch'; goRelSha256='$sha256' ;; "$'\\\n'
	done
	linuxArchCase+=$'\t\t'"*) goRelArch='src'; goRelSha256='$srcSha256'; "$'\\\n'
	linuxArchCase+=$'\t\t\t''echo >&2; echo >&2 "warning: current architecture ($dpkgArch) does not have a corresponding Go binary release; will be building from source"; echo >&2 ;; '$'\\\n'
	linuxArchCase+=$'\t''esac'

	windowsSha256="$(curl -fsSL "https://storage.googleapis.com/golang/go${fullVersion}.windows-amd64.zip.sha256")"

	for variant in alpine3.5 alpine3.6 alpine; do
		if [ -d "$version/$variant" ]; then
			ver="${variant#alpine}"
			ver="${ver:-${alpineVersion[$version]:-$defaultAlpineVersion}}"
			sed -r \
				-e 's!%%VERSION%%!'"$fullVersion"'!g' \
				-e 's!%%ALPINE-VERSION%%!'"$ver"'!g' \
				-e 's!%%SRC-SHA256%%!'"$srcSha256"'!g' \
				Dockerfile-alpine.template > "$version/$variant/Dockerfile"
			cp go-wrapper "$version/$variant/"
			travisEnv='\n  - VERSION='"$version VARIANT=$variant$travisEnv"
		fi
	done
	for variant in stretch wheezy ''; do
		if [ -d "$version/$variant" ]; then
			sed -r \
				-e 's!%%VERSION%%!'"$fullVersion"'!g' \
				-e 's!%%DEBIAN-SUITE%%!'"${variant:-${debianSuite[$version]:-$defaultDebianSuite}}"'!g' \
				-e 's!%%ARCH-CASE%%!'"$(sed_escape_rhs "$linuxArchCase")"'!g' \
				Dockerfile-debian.template > "$version/$variant/Dockerfile"
			cp go-wrapper "$version/$variant/"
			travisEnv='\n  - VERSION='"$version VARIANT=$variant$travisEnv"
		fi
	done
	for winVariant in windowsservercore nanoserver; do
		if [ -d "$version/windows/$winVariant" ]; then
			sed -r \
				-e 's!%%VERSION%%!'"$fullVersion"'!g' \
				-e 's!%%WIN-SHA256%%!'"$windowsSha256"'!g' \
				"Dockerfile-windows-$winVariant.template" > "$version/windows/$winVariant/Dockerfile"
			appveyorEnv='\n    - version: '"$version"'\n      variant: '"$winVariant$appveyorEnv"
		fi
	done

	echo "$version: $fullVersion ($srcSha256)"
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml

appveyor="$(awk -v 'RS=\n\n' '$1 == "environment:" { $0 = "environment:\n  matrix:'"$appveyorEnv"'" } { printf "%s%s", $0, RS }' .appveyor.yml)"
echo "$appveyor" > .appveyor.yml
