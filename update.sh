#!/bin/bash
set -euo pipefail

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

phpVersions=( "$@" )
if [ ${#phpVersions[@]} -eq 0 ]; then
	phpVersions=( php*.*/ )
fi
phpVersions=( "${phpVersions[@]%/}" )

current="$(curl -fsSL 'https://downloads.joomla.org/api/v1/latest/cms' | jq -r '.branches[3].version')"
urlVersion=$(echo $current | sed -e 's/\./-/g')
sha1="$(curl -fsSL "https://downloads.joomla.org/api/v1/signatures/cms/$urlVersion"  | jq -r --arg file "Joomla_${current}-Stable-Full_Package.tar.bz2" '.[] | .[] | select(.filename == $file).sha1')"

apcu_version="$(
	git ls-remote --tags https://github.com/krakjoe/apcu.git \
		| cut -d/ -f3 \
		| grep -vE -- '-rc|-b' \
		| sed -E 's/^v//' \
		| sort -V \
		| tail -1
)"

memcached_version="$(
	git ls-remote --tags https://github.com/php-memcached-dev/php-memcached.git \
		| cut -d/ -f3 \
		| grep -vE -- '-rc|-b' \
		| sed -E 's/^[rv]//' \
		| sort -V \
		| tail -1
)"

redis_version="$(
	git ls-remote --tags https://github.com/phpredis/phpredis.git \
		| cut -d/ -f3 \
		| grep -viE '[a-z]' \
		| tr -d '^{}' \
		| sort -V \
		| tail -1
)"

declare -A variantExtras=(
	[apache]='\n# Enable Apache Rewrite Module\nRUN a2enmod rewrite\n'
	[fpm]=''
	[fpm-alpine]=''
)
declare -A variantCmds=(
	[apache]='apache2-foreground'
	[fpm]='php-fpm'
	[fpm-alpine]='php-fpm'
)
declare -A variantBases=(
	[apache]='debian'
	[fpm]='debian'
	[fpm-alpine]='alpine'
)
declare -A pecl_versions=(
	[php5-APCu]='4.0.11'
	[php5-memcached]='2.2.0'
	[php5-redis]="$redis_version"
	[php7-APCu]="$apcu_version"
	[php7-memcached]="$memcached_version"
	[php7-redis]="$redis_version"
)

travisEnv=
for phpVersion in "${phpVersions[@]}"; do
	phpVersionDir="$phpVersion"
	phpVersion="${phpVersion#php}"
	phpMajorVersion=$(echo $phpVersionDir | cut -d. -f1)

	for variant in apache fpm fpm-alpine; do
		dir="$phpVersionDir/$variant"
		mkdir -p "$dir"

		extras="${variantExtras[$variant]}"
		cmd="${variantCmds[$variant]}"
		base="${variantBases[$variant]}"

		entrypoint='docker-entrypoint.sh'

		(
			set -x

			sed -r \
				-e 's!%%VERSION%%!'"$current"'!g' \
				-e 's!%%SHA1%%!'"$sha1"'!g' \
				-e 's!%%PHP_VERSION%%!'"$phpVersion"'!g' \
				-e 's!%%VARIANT%%!'"$variant"'!g' \
				-e 's!%%VARIANT_EXTRAS%%!'"$extras"'!g' \
				-e 's!%%APCU_VERSION%%!'"${pecl_versions[$phpMajorVersion-APCu]}"'!g' \
				-e 's!%%MEMCACHED_VERSION%%!'"${pecl_versions[$phpMajorVersion-memcached]}"'!g' \
				-e 's!%%REDIS_VERSION%%!'"${pecl_versions[$phpMajorVersion-redis]}"'!g' \
				-e 's!%%CMD%%!'"$cmd"'!g' \
				"Dockerfile-${base}.template" > "$dir/Dockerfile"

			cp -a "$entrypoint" "$dir/docker-entrypoint.sh"
			cp -a "makedb.php" "$dir/makedb.php"

			if [ $phpVersionDir = "php7.2" ]; then
				sed \
					-e '/libmcrypt-dev/d' \
					-e '/mcrypt/d' \
					-i $dir/Dockerfile
			fi
		)

		travisEnv+='\n  - VARIANT='"$dir"
	done
done

travis="$(awk -v 'RS=\n\n' '$1 == "env:" { $0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml
