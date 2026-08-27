#!/usr/bin/env bash
# Copyright (c) NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Writes THIRD_PARTY_NOTICES.md for the Go modules linked into ./cmd/... (vendored).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hack/license-url-lib.sh disable=SC1091
source "${HERE}/license-url-lib.sh"

# LC_ALL=C on every sort and grep below: collation and case folding must not vary
# by locale (under tr_TR glibc will not fold I to i, so LICENSE stops matching).

OUTPUT="${OUTPUT:-THIRD_PARTY_NOTICES.md}"
LICENSES_DIR="${LICENSES_DIR:-.licenses-cache}"
MULTI_ARCH_MK="${MULTI_ARCH_MK:-deployments/container/multi-arch.mk}"
MODULES_TXT="${MODULES_TXT:-vendor/modules.txt}"

# The image copies a prebuilt nvidia-mig-parted in rather than building it, so
# its dependencies are in no go.mod here. They are read from the shipped binary
# itself: Go records the module, its version and every linked dependency in the
# build info, which is what actually ships rather than what a tag implies.
BUNDLED_DOCKERFILE="${BUNDLED_DOCKERFILE:-deployments/container/Dockerfile.distroless}"
BUNDLED_BINARY="${BUNDLED_BINARY:-/usr/bin/nvidia-mig-parted}"
DOCKER="${DOCKER:-docker}"

# Exactly what 'make cmds' builds and ships.
PACKAGES=("./cmd/...")

# Must match the released image platforms; verify_platform_matrix fails on
# drift. go-licenses resolves one platform per run, so collection runs per
# target and merges.
PLATFORMS=(
    "linux/amd64"
    "linux/arm64"
)

die() {
    printf 'ERROR: %s\n' "$1" >&2
    shift
    if (( $# > 0 )); then
        printf '%s\n' "$@" >&2
    fi
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

# Licenses that are themselves Markdown close a fixed ``` fence early and invert
# every block after it, so open with one backtick more than the file's longest run.
fence_for() {
    local file="$1" longest_backtick_run fence_width
    # -a: a license containing a NUL byte is otherwise treated as binary and
    # grep prints "Binary file ... matches" rather than the matches themselves,
    # on stdout or stderr depending on the grep version.
    longest_backtick_run=$(LC_ALL=C grep -oaE '`+' "${file}" 2>/dev/null \
        | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }' || true)
    fence_width=$(( longest_backtick_run + 1 ))
    (( fence_width < 3 )) && fence_width=3
    printf '%*s' "${fence_width}" '' | tr ' ' '`'
}

check_prerequisites() {
    command -v go >/dev/null 2>&1 || die "go is not installed."

    # Probe by running it, not with -x: the docker-% targets bind-mount the repo
    # into a Linux build image, so a host-built binary passes -x but cannot exec.
    if ./bin/go-licenses --help >/dev/null 2>&1; then
        GO_LICENSES="${PWD}/bin/go-licenses"
    elif command -v go-licenses >/dev/null 2>&1; then
        GO_LICENSES="$(command -v go-licenses)"
    else
        die "no usable go-licenses found." \
            "If ./bin/go-licenses exists it was built for another platform; delete it and re-run."
    fi

    local required_file
    for required_file in "${MULTI_ARCH_MK}" "${MODULES_TXT}" "${LICENSE_OVERRIDES}"; do
        [[ -f "${required_file}" ]] \
            || die "${required_file} not found — run 'make third-party-notices' from the repo root."
    done

    command -v "${DOCKER}" >/dev/null 2>&1 \
        || die "${DOCKER} is not installed, and the bundled binary is read from the released image." \
               "Set DOCKER= to a compatible CLI, or install one."

    GOMODCACHE="$(go env GOMODCACHE)"
    [[ -n "${GOMODCACHE}" ]] || die "could not determine the module cache via 'go env GOMODCACHE'."

    [[ -f "${BUNDLED_DOCKERFILE}" ]] \
        || die "${BUNDLED_DOCKERFILE} not found — run 'make third-party-notices' from the repo root."

    LOCAL_MODULE=$(go list -m 2>/dev/null || true)
    [[ -n "${LOCAL_MODULE}" ]] || die "could not determine local module path via 'go list -m'."

    # CGO must stay on: with CGO_ENABLED=0 the build constraints exclude every
    # file in go-nvml/pkg/dl, so that package drops out of the closure and ships
    # unattributed. No C compiler is needed; go-licenses never compiles.
    export GOFLAGS="-mod=vendor"
    export CGO_ENABLED=1
}

verify_platform_matrix() {
    local expected actual
    expected=$(sed -n 's/^DOCKER_BUILD_PLATFORM_OPTIONS[[:space:]]*?*=[[:space:]]*--platform=//p' \
        "${MULTI_ARCH_MK}" | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort -u)
    [[ -n "${expected}" ]] \
        || die "could not read DOCKER_BUILD_PLATFORM_OPTIONS from ${MULTI_ARCH_MK}."

    actual=$(printf '%s\n' "${PLATFORMS[@]}" | LC_ALL=C sort -u)
    [[ "${expected}" == "${actual}" ]] || die \
        "the PLATFORMS matrix is out of sync with ${MULTI_ARCH_MK}." \
        "Update the PLATFORMS array in hack/generate-third-party-notices.sh to match the released targets." \
        "  matrix (PLATFORMS): $(echo "${actual}" | paste -sd ' ' -)" \
        "  image platforms:    $(echo "${expected}" | paste -sd ' ' -)"
}

prepare_workspace() {
    # Guard the override: '', '/', '.' or '..' would make the rm -rf fatal.
    case "${LICENSES_DIR}" in
        ""|"/"|"."|"..")
            die "refusing to 'rm -rf' unsafe LICENSES_DIR='${LICENSES_DIR}'."
            ;;
    esac
    rm -rf "${LICENSES_DIR}"
    mkdir -p "${LICENSES_DIR}"

    # Explicit templates: macOS mktemp ignores TMPDIR without one.
    local workspace_template="${TMPDIR:-/tmp}/vgpu-device-manager-notices"
    SAVE_ROOT="$(mktemp -d "${workspace_template}.XXXXXX")"
    COMBINED_CSV="$(mktemp "${workspace_template}-csv.XXXXXX")"
    INDEX_FILE="$(mktemp "${workspace_template}-idx.XXXXXX")"
    BUNDLED_CSV="$(mktemp "${workspace_template}-bundled-csv.XXXXXX")"
    BUNDLED_INDEX="$(mktemp "${workspace_template}-bundled-idx.XXXXXX")"
    BUNDLED_MODULES="$(mktemp "${workspace_template}-bundled-modules.XXXXXX")"
    MERGED_INDEX="$(mktemp "${workspace_template}-merged-idx.XXXXXX")"
    SCRATCH_DIR="$(mktemp -d "${workspace_template}-scratch.XXXXXX")"

    # Composed next to OUTPUT, not in TMPDIR, so the publish below is a rename.
    local out_dir
    out_dir="$(dirname "${OUTPUT}")"
    mkdir -p "${out_dir}"
    OUT_TMP="$(mktemp "${out_dir}/.$(basename "${OUTPUT}").XXXXXX")"

    trap 'rm -rf "${SAVE_ROOT}" "${SCRATCH_DIR}"; rm -f "${COMBINED_CSV}" "${INDEX_FILE}" "${BUNDLED_CSV}" "${BUNDLED_INDEX}" "${BUNDLED_MODULES}" "${MERGED_INDEX}" "${OUT_TMP}"' EXIT
}

collect_runtime() {
    local platform goos goarch save_dir

    for platform in "${PLATFORMS[@]}"; do
        goos="${platform%/*}"
        goarch="${platform#*/}"
        log "Collecting licenses for ${goos}/${goarch}..."

        save_dir="${SAVE_ROOT}/${goos}_${goarch}"

        # Only the local module: --ignore matches raw string prefixes, not path
        # segments, so a stdlib list adds the token "go" and silently drops
        # golang.org/x/*, google.golang.org/*, gopkg.in/* and go.yaml.in/*.
        GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" save "${PACKAGES[@]}" \
            --save_path="${save_dir}" \
            --force \
            --ignore="${LOCAL_MODULE}"

        GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" csv "${PACKAGES[@]}" \
            --ignore="${LOCAL_MODULE}" \
            >> "${COMBINED_CSV}"

        merge_licenses "${save_dir}" "${LICENSES_DIR}"
    done
}

# Module cache files are 0444 and cp preserves that, so the next platform's copy
# fails unless write permission is restored.
# The Dockerfile names the image the binary is copied from. Read it rather than
# pinning it here, so bumping the image cannot leave the notices describing the
# previous one.
read_bundled_image() {
    BUNDLED_IMAGE="$(LC_ALL=C sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]*k8s-mig-manager:[^[:space:]]*\).*/\1/p' \
        "${BUNDLED_DOCKERFILE}" | head -1)"
    [[ -n "${BUNDLED_IMAGE}" ]] \
        || die "could not read the bundled binary's image from ${BUNDLED_DOCKERFILE}." \
               "Expected a 'FROM <registry>/k8s-mig-manager:<tag>' stage."
}

extract_bundled_binary() {
    local goos="$1" goarch="$2" destination="$3" container
    "${DOCKER}" pull --platform "${goos}/${goarch}" "${BUNDLED_IMAGE}" >/dev/null 2>&1 \
        || die "could not pull ${BUNDLED_IMAGE} for ${goos}/${goarch}."
    container="$("${DOCKER}" create --platform "${goos}/${goarch}" "${BUNDLED_IMAGE}")" \
        || die "could not create a container from ${BUNDLED_IMAGE}."
    "${DOCKER}" cp "${container}:${BUNDLED_BINARY}" "${destination}" >/dev/null 2>&1
    local copied=$?
    "${DOCKER}" rm "${container}" >/dev/null 2>&1 || true
    (( copied == 0 )) || die "${BUNDLED_BINARY} is not in ${BUNDLED_IMAGE} for ${goos}/${goarch}."
}

# The bundled binary's module list alone, in vendor/modules.txt's shape. Cheap
# enough for hack/resolve-module-repos.sh, which needs the module names but none
# of the license classification.
read_bundled_module_list() {
    local goos="${PLATFORMS[0]%/*}" goarch="${PLATFORMS[0]#*/}" binary
    read_bundled_image
    binary="$(mktemp "${TMPDIR:-/tmp}/vgpu-device-manager-bundled.XXXXXX")"
    extract_bundled_binary "${goos}" "${goarch}" "${binary}"
    go version -m "${binary}" | LC_ALL=C awk '$1 == "dep" { print "# " $2 " " $3 }' | LC_ALL=C sort -u
    rm -f "${binary}"
}

# Nothing in this repo records what the copied binary links, so the binary is
# the source of truth: Go writes the module, its version and every dependency
# into the build info at link time. Resolving from a git tag instead would rest
# on the image tag matching a repo tag, which nothing enforces — a rebuild or a
# patched image would be attributed to the wrong sources without a word.
collect_bundled() {
    local platform goos goarch binary
    local bundled_package bundled_module bundled_version recorded resolved

    read_bundled_image
    log "Reading bundled binary dependencies from ${BUNDLED_IMAGE}..."

    for platform in "${PLATFORMS[@]}"; do
        goos="${platform%/*}"
        goarch="${platform#*/}"

        binary="${SAVE_ROOT}/bundled-${goos}_${goarch}"
        extract_bundled_binary "${goos}" "${goarch}" "${binary}"

        bundled_package="$(go version -m "${binary}" | LC_ALL=C awk '$1 == "path" { print $2; exit }')"
        bundled_module="$(go version -m "${binary}" | LC_ALL=C awk '$1 == "mod" { print $2; exit }')"
        bundled_version="$(go version -m "${binary}" | LC_ALL=C awk '$1 == "mod" { print $3; exit }')"
        [[ -n "${bundled_package}" && -n "${bundled_module}" && -n "${bundled_version}" ]] \
            || die "${BUNDLED_BINARY} in ${BUNDLED_IMAGE} carries no Go build info." \
                   "It is not a Go binary, or it was stripped of its module metadata."

        recorded="$(go version -m "${binary}" \
            | LC_ALL=C awk '$1 == "dep" { print $2 "|" $3 }' | LC_ALL=C sort -u)"
        [[ -n "${recorded}" ]] \
            || die "${BUNDLED_BINARY} records no dependencies, which cannot be right."

        (
            cd "${SCRATCH_DIR}"
            # shellcheck disable=SC2030  # subshell-local on purpose; the outer -mod=vendor stands.
            export GOFLAGS="-mod=mod"
            [[ -f go.mod ]] || go mod init vgpu-device-manager-notices-scratch >/dev/null 2>&1
            go get "${bundled_module}@${bundled_version}" >/dev/null 2>&1 \
                || die "could not resolve ${bundled_module}@${bundled_version} recorded in the binary."
            go mod download all >/dev/null 2>&1
        )

        # go-licenses classifies packages, so the module set has to be resolved
        # from source. Everything it is pointed at comes from the binary, so the
        # only thing left to check is that the two agree.
        resolved="$(
            cd "${SCRATCH_DIR}"
            GOFLAGS="-mod=mod" GOOS="${goos}" GOARCH="${goarch}" CGO_ENABLED=1 \
                go list -deps -f '{{if .Module}}{{.Module.Path}}|{{.Module.Version}}{{end}}' \
                "${bundled_package}" 2>/dev/null \
                | LC_ALL=C grep -v "^${bundled_module}|" | LC_ALL=C sort -u
        )"

        # Fail closed. If source resolution and the shipped binary disagree, the
        # document would describe something other than what is in the image.
        if [[ "${resolved}" != "${recorded}" ]]; then
            die "the module set resolved for ${bundled_package} does not match ${BUNDLED_BINARY} in ${BUNDLED_IMAGE}." \
                "Only in the shipped binary: $(LC_ALL=C comm -13 <(printf '%s\n' "${resolved}") <(printf '%s\n' "${recorded}") | paste -sd ' ' -)" \
                "Only resolved from source: $(LC_ALL=C comm -23 <(printf '%s\n' "${resolved}") <(printf '%s\n' "${recorded}") | paste -sd ' ' -)"
        fi

        log "Collecting bundled binary licenses for ${goos}/${goarch}..."
        (
            cd "${SCRATCH_DIR}"
            # shellcheck disable=SC2031  # same subshell-local override as above.
            export GOFLAGS="-mod=mod"
            export CGO_ENABLED=1
            GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" csv "${bundled_package}" \
                --ignore="${bundled_module}"
        ) >> "${BUNDLED_CSV}"

        # Same shape as vendor/modules.txt so annotate_modules reads both. Built
        # from the binary, not from the resolution, so the row versions are the
        # shipped ones.
        printf '%s\n' "${recorded}" | LC_ALL=C awk -F'|' '{ print "# " $1 " " $2 }' > "${BUNDLED_MODULES}"
    done
}

merge_licenses() {
    cp -R "$1/." "$2/"
    chmod -R u+w "$2"
}

# Licenses are joined, not picked: go-licenses emits a row per recognized
# license, so keeping one would hide a second license behind the first.
collapse_index() {
    LC_ALL=C sort -u "$1" | awk -F, '
        {
            pkg = $1
            if (!(pkg in url)) { url[pkg] = $2; order[++n] = pkg }
            if (!((pkg SUBSEP $3) in seen)) {
                seen[pkg SUBSEP $3] = 1
                # Count, do not test "pkg in lic": mawk instantiates the
                # assignment target before evaluating the right-hand side, so
                # that test is true on the first row and BSD awk disagrees.
                lic[pkg] = (cnt[pkg]++ ? lic[pkg] " / " : "") $3
            }
        }
        END { for (i = 1; i <= n; i++) print order[i] "," url[order[i]] "," lic[order[i]] }
    '
}

# Rows carry the module path and version, not a URL: in vendor mode go-licenses
# points into this repo at HEAD, which stops describing released content once
# main moves and names our copy, not upstream. The verified upstream location
# comes from hack/license-urls.tsv.
# Longest-prefix match, because a license may sit below the module root.
annotate_modules() {
    local modfile="${1:-${MODULES_TXT}}"
    awk -v modfile="${modfile}" '
        BEGIN {
            FS = OFS = ","
            while ((getline line < modfile) > 0) {
                if (line !~ /^# /) continue
                split(line, f, " ")
                # "# <path> <version>", optionally "=> <path> <version>". The
                # replacement is what is vendored; a filesystem replace has no
                # stable module identity, so stop rather than misattribute it.
                if (f[4] == "=>" || f[3] == "=>") {
                    r = (f[4] == "=>") ? 5 : 4
                    if (f[r + 1] == "") {
                        print "ERROR: " modfile " replaces " f[2] " with a local path;" > "/dev/stderr"
                        print "teach hack/generate-third-party-notices.sh how to attribute it." > "/dev/stderr"
                        exit 1
                    }
                    mods[++m] = f[2]
                    disp[f[2]] = f[r]
                    ver[f[2]] = f[r + 1]
                } else {
                    mods[++m] = f[2]
                    disp[f[2]] = f[2]
                    ver[f[2]] = f[3]
                }
            }
            close(modfile)
            # A read error makes getline return -1 and the loop never runs.
            if (m == 0) {
                print "ERROR: no module lines read from " modfile > "/dev/stderr"
                exit 1
            }
        }
        {
            best = ""
            for (i = 1; i <= m; i++) {
                mp = mods[i]
                if (($1 == mp || index($1, mp "/") == 1) && length(mp) > length(best)) best = mp
            }
            print $0, (best == "" ? "unknown" : disp[best]), (best == "" ? "unknown" : ver[best])
        }
    '
}

build_indexes() {
    log "Generating dependency index..."
    collapse_index "${COMBINED_CSV}" | annotate_modules > "${INDEX_FILE}"

    [[ -s "${INDEX_FILE}" ]] \
        || die "go-licenses produced no entries for ${PACKAGES[*]} — refusing to write empty notices file."

    # An unclassifiable license is reported as "Unknown" with a zero exit, and an
    # empty field renders as "Unknown" through the fallback below, so both must
    # trip this or an entry that attributes nothing would ship.
    if cut -d, -f3 "${INDEX_FILE}" | LC_ALL=C grep -qE '^$|(^| / )Unknown( / |$)'; then
        die "go-licenses could not identify a license for some dependencies." \
            "Check the entries reported as Unknown before committing the file."
    fi

    if cut -d, -f4 "${INDEX_FILE}" | LC_ALL=C grep -qx 'unknown'; then
        die "could not resolve a dependency for some packages from ${MODULES_TXT}." \
            "Run 'go mod tidy && go mod vendor' and re-run, rather than committing a file" \
            "with unattributed entries."
    fi

    if cut -d, -f5 "${INDEX_FILE}" | LC_ALL=C grep -qx 'unknown'; then
        die "could not resolve a version for some packages from ${MODULES_TXT}." \
            "Run 'go mod tidy && go mod vendor' and re-run, rather than committing a file" \
            "with unattributed entries."
    fi

    collapse_index "${BUNDLED_CSV}" | annotate_modules "${BUNDLED_MODULES}" > "${BUNDLED_INDEX}"
    [[ -s "${BUNDLED_INDEX}" ]] \
        || die "go-licenses produced no entries for the bundled binary — refusing to write incomplete notices."

    local bundled_field
    for bundled_field in 4 5; do
        if cut -d, -f"${bundled_field}" "${BUNDLED_INDEX}" | LC_ALL=C grep -qx 'unknown'; then
            die "could not resolve a module or version for some bundled-binary packages." \
                "The binary's build info and the resolved package set disagree."
        fi
    done

    merge_indexes "${INDEX_FILE}" "${BUNDLED_INDEX}" > "${MERGED_INDEX}"

    check_override_coverage "${MERGED_INDEX}"
}

# One index for the whole image. The two trees are a build-time detail: what
# ships is one filesystem, so a module both binaries link at different versions
# is two honest rows rather than a second table the reader has to reconcile. The
# source tree moves into the row as a sixth field, since it is now per row
# rather than per table. Same package at the same version is one row; the bytes
# are identical, so the vendored copy wins.
merge_indexes() {
    cat <(sed 's/$/,vendor/' "$1") <(sed 's/$/,modcache/' "$2") \
        | LC_ALL=C awk -F, '!seen[$1 FS $5]++' \
        | LC_ALL=C sort -t, -k1,1 -k5,5
}

# A dropped dependency would otherwise leave its row in LICENSE_OVERRIDES
# silently asserting a license for a package no longer shipped.
check_override_coverage() {
    local index="$1" override_package
    while IFS=$'\t' read -r override_package _ _; do
        case "${override_package}" in
            ''|'#'*) continue ;;
        esac
        LC_ALL=C cut -d, -f1 "${index}" | LC_ALL=C grep -qFx "${override_package}" \
            || die "${LICENSE_OVERRIDES} has a row for ${override_package}, which is not in the generated index." \
                   "Remove that row from ${LICENSE_OVERRIDES} — the dependency was likely dropped."
    done < "${LICENSE_OVERRIDES}"
}

# Filter by name: for restricted licenses 'go-licenses save' copies the whole
# module source.
license_files_for() {
    local search_dir="$1" license_file file_basename
    [[ -d "${search_dir}" ]] || return 0
    while IFS= read -r -d '' license_file; do
        file_basename="$(basename "${license_file}")"
        # Exclude source files: the name pattern below also matches source files
        # that merely start with a license-shaped header, e.g. a Go file opening
        # with a copyright comment in a package named license.
        case "${file_basename}" in
            *.go|*.c|*.h|*.s|*.py|*.sh|*.java|*.ts|*.js) continue ;;
        esac
        if printf '%s' "${file_basename}" \
            | LC_ALL=C grep -qiE '^(licen[cs]e|notice|copying|copyright|authors|patents)([-._].*)?$'; then
            printf '%s\n' "${license_file}"
        fi
    done < <(find "${search_dir}" -maxdepth 1 -type f -print0 2>/dev/null | LC_ALL=C sort -z)
}

LICENSE_URLS="${LICENSE_URLS:-hack/license-urls.tsv}"
LICENSE_OVERRIDES="${LICENSE_OVERRIDES:-hack/license-overrides.tsv}"
VENDOR_DIR="${VENDOR_DIR:-vendor}"

# Separate from check_prerequisites: hack/verify-license-urls.sh reuses the
# collection stages to discover which license files the document will link, and
# it is the command that produces this map, so it must run without it.
require_url_map() {
    [[ -f "${LICENSE_URLS}" ]] \
        || die "${LICENSE_URLS} not found." \
               "Run 'make third-party-notices-urls' (needs network) and commit the result."
}

# A single license file can bundle more than one license, which go-licenses
# reports as whichever one it scores highest; LICENSE_OVERRIDES corrects the
# identifier by hand without touching the license text, which is unaffected.
license_identifier_for() {
    local package="$1" default_identifier="$2" override_identifier
    override_identifier="$(LC_ALL=C awk -F'\t' -v pkg="${package}" \
        '$1 == pkg { print $2; exit }' "${LICENSE_OVERRIDES}")"
    printf '%s' "${override_identifier:-${default_identifier}}"
}

# The first enclosing directory holding a license file wins, which is how
# go-licenses attributes them.
# Where the module's own source tree is on disk. The runtime set is vendored;
# the bundled binary's dependencies exist only in the module cache.
module_source_dir() {
    local module="$1" version="$2" source_kind="$3"
    case "${source_kind}" in
        vendor)
            printf '%s' "${VENDOR_DIR}/${module}"
            ;;
        modcache)
            # The cache escapes capitals exactly as the module proxy does.
            printf '%s/%s@%s' "${GOMODCACHE}" "$(proxy_escape "${module}")" "${version}"
            ;;
        *)
            die "unknown module source kind '${source_kind}' for ${module}."
            ;;
    esac
}

license_dir_within_module() {
    local package="$1" module="$2" module_dir="$3"
    local dir="${package}" relative
    while :; do
        relative="${dir#"${module}"}"
        relative="${relative#/}"
        if [[ -n "$(license_files_for "${module_dir}${relative:+/${relative}}")" ]]; then
            printf '%s' "${relative}"
            return 0
        fi
        [[ "${dir}" == "${module}" ]] && return 1
        [[ "${dir}" != */* ]] && return 1
        dir="${dir%/*}"
    done
}

location_for() {
    local url
    url="$(LC_ALL=C awk -F'\t' -v m="$1" -v v="$2" -v p="$3" \
        '$1 == m && $2 == v && $3 == p { print $4; found = 1; exit }
         END { exit !found }' "${LICENSE_URLS}")" || return 1
    [[ -n "${url}" ]] || return 1
    printf '%s' "${url}"
}

# Mirrors how the License column joins identifiers.
location_cell() {
    local package="$1" module="$2" version="$3" module_dir="$4"
    local relative_license_dir license_file_name license_path url cell="" license_file governing_dir
    relative_license_dir="$(license_dir_within_module "${package}" "${module}" "${module_dir}")" \
        || die "no license file found for ${package} under ${module_dir}."
    governing_dir="${module_dir}${relative_license_dir:+/${relative_license_dir}}"
    while IFS= read -r license_file; do
        [[ -z "${license_file}" ]] && continue
        license_file_name="$(basename "${license_file}")"
        license_path="${relative_license_dir:+${relative_license_dir}/}${license_file_name}"
        url="$(location_for "${module}" "${version}" "${license_path}")" \
            || die "${LICENSE_URLS} has no verified URL for ${module}@${version} ${license_path}." \
                   "Run 'make third-party-notices-urls' (needs network) and commit the result."
        cell="${cell:+${cell} / }[${license_file_name}](${url})"
    done < <(license_files_for "${governing_dir}")
    [[ -n "${cell}" ]] || die "no license file for ${package} under ${governing_dir}."
    printf '%s' "${cell}"
}

emit_index_table() {
    local index="$1" package _url license module version source_kind location license_identifier module_dir
    printf '| Package | Version | License | Location |\n'
    printf '|---------|---------|---------|----------|\n'

    while IFS=, read -r package _url license module version source_kind; do
        [[ -z "${package}" ]] && continue
        module_dir="$(module_source_dir "${module}" "${version}" "${source_kind}")"
        location="$(location_cell "${package}" "${module}" "${version}" "${module_dir}")"
        license_identifier="$(license_identifier_for "${package}" "${license:-Unknown}")"
        # shellcheck disable=SC2016  # backticks are literal markdown here.
        printf '| `%s` | %s | %s | %s |\n' \
            "${package}" "${version:-unknown}" \
            "${license_identifier}" "${location}"
    done < "${index}"
}

emit_sections() {
    local index="$1"
    local package _url license module version source_kind files license_file fence
    local relative_license_dir license_file_name url governing_dir license_identifier module_dir

    while IFS=, read -r package _url license module version source_kind; do
        [[ -z "${package}" ]] && continue

        license_identifier="$(license_identifier_for "${package}" "${license:-Unknown}")"
        printf '### %s\n\n' "${package}"
        printf '* Version: %s\n' "${version:-unknown}"
        printf '* License: %s\n\n' "${license_identifier}"

        module_dir="$(module_source_dir "${module}" "${version}" "${source_kind}")"
        relative_license_dir="$(license_dir_within_module "${package}" "${module}" "${module_dir}")" \
            || die "no license file found for ${package} under ${module_dir}."
        governing_dir="${module_dir}${relative_license_dir:+/${relative_license_dir}}"

        files=()
        while IFS= read -r license_file; do
            [[ -n "${license_file}" ]] && files+=("${license_file}")
        done < <(license_files_for "${governing_dir}")

        if (( ${#files[@]} == 0 )); then
            printf 'License text unavailable. See upstream source for the full license.\n'
        else
            for license_file in "${files[@]}"; do
                license_file_name="$(basename "${license_file}")"
                url="$(location_for "${module}" "${version}" "${relative_license_dir:+${relative_license_dir}/}${license_file_name}")" \
                    || die "${LICENSE_URLS} has no verified URL for ${module}@${version} ${relative_license_dir:+${relative_license_dir}/}${license_file_name}." \
                           "Run 'make third-party-notices-urls' (needs network) and commit the result."
                fence="$(fence_for "${license_file}")"
                printf '#### %s\n\n' "${license_file_name}"
                printf '<%s>\n\n' "${url}"
                printf '%stext\n' "${fence}"
                cat "${license_file}"
                echo
                printf '%s\n' "${fence}"
                echo
            done
        fi
        echo
    done < "${index}"
}

compose_document() {
    require_url_map
    log "Composing ${OUTPUT}..."
    {
        cat <<'EOF'
# Third-Party Notices

NVIDIA vGPU Device Manager

This file lists every third-party dependency that vGPU Device Manager
redistributes, along with the verbatim text of each dependency's license. In
particular, this covers all **Go modules** statically linked into the commands
under `cmd/`, resolved as the union across every released image platform. The
`nvidia-vgpu-dm` and `nvidia-k8s-vgpu-dm` commands ship in the
`vgpu-device-manager` image. The image additionally carries `nvidia-mig-parted`,
copied from the `k8s-mig-manager` image rather than built here, and its
dependencies are listed here too; they are read from the shipped binary itself.
Where `nvidia-mig-parted` and the commands built here link the same module at
different versions, both copies ship and both are listed. Go standard library
packages are excluded; they are covered by the license of the Go distribution
itself.

Each dependency is listed with the version redistributed and a link to the
license file in that version's upstream source. Every link was verified by
fetching it and comparing its contents against the copy vendored here, so each
one resolves to the same license text reproduced below. Modules that no command
under `cmd/` links are not listed; those are vendored only for this module's own
tests and build tooling.

The `vgpu-device-manager` image uses `nvcr.io/nvidia/distroless/go` as a base
image. All of the OSS packages and source included in this image can be found at
<https://developer.nvidia.com/w/distroless-oss/index.html>. A statically
compiled busybox binary is added to the image, which is licensed under GPLv2.

## Dependency Index

EOF
        emit_index_table "${MERGED_INDEX}"

        cat <<'EOF'

## Dependency License Texts

EOF
        emit_sections "${MERGED_INDEX}"
    } > "${OUT_TMP}"

    # mv, not cp: OUT_TMP is in OUTPUT's directory, so this is a rename(2) and
    # OUTPUT is never a partial write. mktemp creates 0600, hence the chmod.
    chmod 644 "${OUT_TMP}"
    mv -f "${OUT_TMP}" "${OUTPUT}"
}

main() {
    check_prerequisites
    verify_platform_matrix
    prepare_workspace

    collect_runtime
    collect_bundled
    build_indexes
    compose_document

    local package_count
    package_count=$(wc -l < "${MERGED_INDEX}" | tr -d ' ')
    log "Wrote ${OUTPUT} (${package_count} entries)"
}

# Sourced by the tests and by hack/verify-license-urls.sh, which reuse these
# functions without the side effects of a full run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
