#!/bin/sh

# ==============================================================================
# Native Transmission build and Debian package (.deb) creation.
#
# LOCAL USAGE:
#
#   sudo sh ./build.sh
#
# CUSTOM PARAMETERS:
#
#   sudo env PACKAGE_VERSION=4.1.0-local BUILD_JOBS=4 sh ./build.sh
#
#   sudo env INSTALL_DEPS=0 STRIP_BINARIES=0 CLEAN_BUILD=0 sh ./build.sh
#
# OUTPUT:
#
#   outputs/transmissiond-<version>_<arch>.deb
#
# CONFIGURATION:
#
#   SRC_DIR          Source directory
#   PACKAGE_VERSION  Package version
#   MAINTAINER       Package maintainer
#   BUILD_JOBS       Parallel jobs
#   INSTALL_DEPS     Install build dependencies (1/0/yes/no)
#   STRIP_BINARIES   Strip ELF binaries (1/0/yes/no)
#   CLEAN_BUILD      Clean CMake build directory (1/0/yes/no)
#
# ==============================================================================

set -eu

# ==============================================================================
# CONFIGURATION
# ==============================================================================

SRC_DIR=${SRC_DIR:-.} # transmissiond src directory
PACKAGE_VERSION=${PACKAGE_VERSION:-0.0.0+local}
MAINTAINER=${MAINTAINER:-"ups<ups91@ukr.net>"}
BUILD_JOBS=${BUILD_JOBS:-1}
INSTALL_DEPS=${INSTALL_DEPS:-1}
STRIP_BINARIES=${STRIP_BINARIES:-1}
CLEAN_BUILD=${CLEAN_BUILD:-1}

# ==============================================================================
# FUNCTIONS
# ==============================================================================

die()
{
    echo "ERROR: $*" >&2
    exit 1
}

require_command()
{
    if ! command -v "$1" >/dev/null 2>&1; then
        die "Required command not found: $1"
    fi
}

validate_boolean()
{
    name=$1
    value=$2

    case "${value}" in
        0|no|NO|false|FALSE)
            eval "${name}=0"
            ;;
        1|yes|YES|true|TRUE)
            eval "${name}=1"
            ;;
        *)
            die "${name} must be one of: 0 | 1 | yes | no"
            ;;
    esac
}

# ==============================================================================
# CONFIGURATION VALIDATION
# ==============================================================================

validate_boolean INSTALL_DEPS "${INSTALL_DEPS}"
validate_boolean STRIP_BINARIES "${STRIP_BINARIES}"
validate_boolean CLEAN_BUILD "${CLEAN_BUILD}"

# ==============================================================================
# BUILD ENVIRONMENT
# ==============================================================================

echo "=== Preparing build environment ==="

# Validate the source directory and switch to its absolute path.
if [ ! -d "${SRC_DIR}" ]; then
    die "Transmission source directory not found: ${SRC_DIR}"
fi

cd "${SRC_DIR}"
SRC_DIR=$(pwd -P)

# Check the tools required for package management and architecture detection.
for tool in id dpkg dpkg-deb dpkg-query; do
    require_command "${tool}"
done

# Validate the Debian package version.
if ! dpkg --validate-version "${PACKAGE_VERSION}" >/dev/null 2>&1; then
    die "Invalid Debian package version: ${PACKAGE_VERSION}"
fi

# Detect the target architecture from the current Debian system.
ARCH=$(dpkg --print-architecture)

if [ -z "${ARCH}" ]; then
    die "Unable to determine system architecture"
fi

echo "Target architecture: ${ARCH}"
echo "Package version: ${PACKAGE_VERSION}"

# Define the architecture-specific build directory.
BUILD_DIR="${SRC_DIR}/build-${ARCH}"

if [ "${CLEAN_BUILD}" -eq 1 ]; then
    rm -rf "${BUILD_DIR}"
fi

mkdir -p "${BUILD_DIR}"

# Define the Debian package name and output directory.
PKG_NAME="transmissiond-systemd-${ARCH}"

OUTPUT_DIR="${SRC_DIR}/dist/"
mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"
OUTPUT_DIR=$(pwd -P)

cd "${SRC_DIR}"

# ==============================================================================
# BUILD DEPENDENCIES
# ==============================================================================

echo "=== Checking build dependencies ==="

# Install the required build tools and development libraries when enabled.
if [ "${INSTALL_DEPS}" -eq 1 ]; then

    if [ "$(id -u)" -ne 0 ]; then
        die "INSTALL_DEPS=1 requires root privileges"
    fi

    require_command apt-get

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        ca-certificates \
        cmake \
        dpkg-dev \
        file \
        git \
        pkg-config \
        python3 \
        libcurl4-openssl-dev \
        libevent-dev \
        libminiupnpc-dev \
        libnatpmp-dev \
        libssl-dev \
        libsystemd-dev \
        zlib1g-dev

else
    echo "Dependency installation disabled (INSTALL_DEPS=0)"
fi

# Verify that all tools required by the remaining build stages are available.
for tool in \
    id \
    dpkg \
    dpkg-deb \
    dpkg-query \
    find \
    file \
    grep \
    sed \
    awk \
    sort \
    strip \
    readelf \
    ldd \
    readlink \
    mktemp \
    install \
    chmod \
    mv \
    rm \
    cat \
    mkdir
do
    require_command "${tool}"
done

# ==============================================================================
# CMAKE CONFIGURATION
# ==============================================================================

echo "=== Configuring CMake ==="

cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DENABLE_DAEMON=ON \
    -DENABLE_UTILS=ON \
    -DENABLE_CLI=ON \
    -DENABLE_TESTS=OFF \
    -DWITH_SYSTEMD=ON \
    -DWITH_CRYPTO=openssl

# ==============================================================================
# BUILD
# ==============================================================================

echo "=== Building Transmission ==="

cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"

# ==============================================================================
# TEMPORARY PACKAGE WORKSPACE
# ==============================================================================

echo "=== Preparing temporary package workspace ==="

# Create a unique temporary directory inside the build directory.
WORK_DIR=$(mktemp -d "${BUILD_DIR}/.transmission-build-${ARCH}.XXXXXX")

if [ -z "${WORK_DIR}" ] || [ ! -d "${WORK_DIR}" ]; then
    die "Failed to create temporary build workspace: ${WORK_DIR}"
fi

# Define the staging directory for the future Debian package.
PKG_ROOT="${WORK_DIR}/pkg-root"

mkdir -p "${PKG_ROOT}"

# ==============================================================================
# INSTALL BUILD OUTPUT
# ==============================================================================

echo "=== Installing compiled files into package staging directory ==="

DESTDIR="${PKG_ROOT}" cmake --install "${BUILD_DIR}"

# ==============================================================================
# ELF VALIDATION
# ==============================================================================

echo "=== Identifying ELF binaries ==="

# Collect all ELF files installed in the package staging directory.
ELF_LIST="${WORK_DIR}/elf-files.txt"
: > "${ELF_LIST}"

find "${PKG_ROOT}" -type f -exec file {} \; | awk -F: '/: ELF/ {print $1}' > "${ELF_LIST}"

if [ ! -s "${ELF_LIST}" ]; then
    die "No ELF files found in package staging directory"
fi

# ==============================================================================
# BINARY STRIPPING
# ==============================================================================

if [ "${STRIP_BINARIES}" -eq 1 ]; then
    echo "=== Stripping ELF binaries ==="
    while IFS= read -r f; do
        strip --strip-unneeded "$f" 2>/dev/null
    done < "${ELF_LIST}"
else
    echo "Binary stripping disabled (STRIP_BINARIES=0)"
fi

# ==============================================================================
# RUNTIME DEPENDENCIES
# ==============================================================================

echo "=== Detecting runtime dependencies ==="

# Collect Debian package names providing the required shared libraries.
RUNTIME_DEPS_FILE="${WORK_DIR}/runtime-deps.txt"
: > "${RUNTIME_DEPS_FILE}"

# Process each ELF file and resolve its dynamic library dependencies.
while IFS= read -r bin; do

    # Skip ELF files without dynamic dependencies.
    if ! readelf -d "${bin}" 2>/dev/null | grep -q '(NEEDED)'; then
        continue
    fi

    # Resolve shared library paths and detect missing dependencies.
    BIN_LIBS=$(ldd "${bin}" 2>&1 | awk '
        /not found/ { failed = 1 }
        $2 == "=>" && $3 ~ /^\// { print $3 }
        $1 ~ /^\// { print $1 }
        END { if (failed) exit 1 }
    ') || die "Unable to resolve runtime dependencies for: ${bin}"

    # Identify the Debian package owning each resolved library.
    for library in ${BIN_LIBS}; do
        REAL_LIBRARY=$(readlink -f "${library}") || die "Cannot resolve library path: ${library}"
        if [ ! -f "${REAL_LIBRARY}" ]; then
            die "Runtime library not found: ${REAL_LIBRARY}"
        fi

        OWNER=$(dpkg-query -S "${REAL_LIBRARY}" 2>/dev/null | sed -n '1s/: .*//p') || die "Cannot determine Debian package owner: ${REAL_LIBRARY}"
        if [ -z "${OWNER}" ]; then
            die "No Debian package owns runtime library: ${REAL_LIBRARY}"
        fi

        printf '%s\n' "${OWNER%%:*}" >> "${RUNTIME_DEPS_FILE}"
    done

done < "${ELF_LIST}"

# Remove duplicate package names and prepare the Debian Depends field.
if [ ! -s "${RUNTIME_DEPS_FILE}" ]; then
    die "Unable to determine runtime dependencies"
fi

RUNTIME_DEPS=$(sort -u "${RUNTIME_DEPS_FILE}" | paste -sd ',' -)

if [ -z "${RUNTIME_DEPS}" ]; then
    die "Runtime dependency list is empty"
fi

echo "Detected runtime dependencies: ${RUNTIME_DEPS}"

# ==============================================================================
# DEBIAN CONTROL FILES
# ==============================================================================

echo "=== Creating Debian package metadata ==="

mkdir -p "${PKG_ROOT}/DEBIAN"

cat > "${PKG_ROOT}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${PACKAGE_VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Depends: ${RUNTIME_DEPS}
Description: BitTorrent client (transmission-daemon and CLI) built for ${ARCH}
EOF

# ==============================================================================
# POST-INSTALLATION SCRIPT
# ==============================================================================

echo "=== Creating post-installation script ==="

cat > "${PKG_ROOT}/DEBIAN/postinst" <<'EOF'
#!/bin/sh

set -e

case "$1" in
    configure)

        if ! id transmission >/dev/null 2>&1; then

            if ! command -v useradd >/dev/null 2>&1; then
                echo "ERROR: useradd is not available" >&2
                exit 1
            fi

            useradd --system \
                --user-group \
                --home-dir /var/lib/transmission-daemon \
                --create-home \
                --shell /usr/sbin/nologin \
                transmission

        fi

        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload || true
        fi

        ;;
esac

exit 0
EOF

# ==============================================================================
# PRE-REMOVAL SCRIPT
# ==============================================================================

echo "=== Creating pre-removal script ==="

cat > "${PKG_ROOT}/DEBIAN/prerm" <<'EOF'
#!/bin/sh

set -e

case "$1" in
    remove|deconfigure)

        if command -v deb-systemd-invoke >/dev/null 2>&1; then

            deb-systemd-invoke stop transmission-daemon.service \
                >/dev/null 2>&1 || true

        elif command -v systemctl >/dev/null 2>&1; then

            systemctl stop transmission-daemon.service \
                >/dev/null 2>&1 || true

        fi

        ;;
esac

exit 0
EOF

# ==============================================================================
# POST-REMOVAL SCRIPT
# ==============================================================================

echo "=== Creating post-removal script ==="

cat > "${PKG_ROOT}/DEBIAN/postrm" <<'EOF'
#!/bin/sh

set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

exit 0
EOF

# Set permissions for Debian maintainer scripts and control metadata.
chmod 755 \
    "${PKG_ROOT}/DEBIAN/postinst" \
    "${PKG_ROOT}/DEBIAN/prerm" \
    "${PKG_ROOT}/DEBIAN/postrm"

chmod 644 "${PKG_ROOT}/DEBIAN/control"

# ==============================================================================
# DEB PACKAGE CREATION
# ==============================================================================

echo "=== Building Debian package ==="

TEMP_DEB="${WORK_DIR}/${PKG_NAME}_${PACKAGE_VERSION}_${ARCH}.deb"

dpkg-deb --build --root-owner-group "${PKG_ROOT}" "${TEMP_DEB}"

# ==============================================================================
# PACKAGE VALIDATION
# ==============================================================================

echo "=== Validating Debian package ==="

# Verify package metadata and archive contents.
dpkg-deb --info "${TEMP_DEB}" >/dev/null
dpkg-deb --contents "${TEMP_DEB}" >/dev/null

PACKAGE_ARCH=$(dpkg-deb -f "${TEMP_DEB}" Architecture)
PACKAGE_NAME_CHECK=$(dpkg-deb -f "${TEMP_DEB}" Package)
PACKAGE_VERSION_CHECK=$(dpkg-deb -f "${TEMP_DEB}" Version)

if [ "${PACKAGE_ARCH}" != "${ARCH}" ]; then
    die "Package architecture mismatch: ${PACKAGE_ARCH}"
fi

if [ "${PACKAGE_NAME_CHECK}" != "${PKG_NAME}" ]; then
    die "Unexpected package name: ${PACKAGE_NAME_CHECK}"
fi

if [ "${PACKAGE_VERSION_CHECK}" != "${PACKAGE_VERSION}" ]; then
    die "Unexpected package version: ${PACKAGE_VERSION_CHECK}"
fi

# Ensure the main Transmission daemon executable is included.
if ! dpkg-deb --contents "${TEMP_DEB}" |
    grep -Fq './usr/bin/transmission-daemon'
then
    die "transmission-daemon is missing from the Debian package"
fi

# Extract and verify Debian maintainer scripts.
CONTROL_CHECK_DIR="${WORK_DIR}/control-check"

mkdir -p "${CONTROL_CHECK_DIR}"

dpkg-deb --control "${TEMP_DEB}" "${CONTROL_CHECK_DIR}"

for script in postinst prerm postrm; do

    if [ ! -f "${CONTROL_CHECK_DIR}/${script}" ]; then
        die "Missing Debian maintainer script: ${script}"
    fi

    if [ ! -x "${CONTROL_CHECK_DIR}/${script}" ]; then
        die "Debian maintainer script is not executable: ${script}"
    fi

done

# ==============================================================================
# FINAL PACKAGE
# ==============================================================================

echo "=== Installing validated package into output directory ==="

# Publish the package only after all validation checks have passed.
FINAL_DEB="${OUTPUT_DIR}/${PKG_NAME}_${PACKAGE_VERSION}_${ARCH}.deb"

mv -f "${TEMP_DEB}" "${FINAL_DEB}"

# ==============================================================================
# BUILD SUMMARY
# ==============================================================================

echo "============================================================"
echo "BUILD COMPLETED SUCCESSFULLY"
echo "------------------------------------------------------------"
echo "Package file:        ${FINAL_DEB}"
echo "Package name:        ${PKG_NAME}"
echo "Package version:     ${PACKAGE_VERSION}"
echo "Target architecture: ${ARCH}"
echo "Runtime dependencies: ${RUNTIME_DEPS}"
echo "============================================================"

# ==============================================================================
# CLEANUP
# ==============================================================================

echo "=== Cleaning up build environment ==="

if [ "${CLEAN_BUILD}" -eq 0 ]; then
    echo "Build directory preserved: ${BUILD_DIR}"
else
    rm -rf "${BUILD_DIR}"
    echo "Build directory removed: ${BUILD_DIR}"
fi

if [ "${INSTALL_DEPS}" -eq 1 ]; then
    apt-get autoremove -y --purge
    echo "Unused APT packages removed"
else
    echo "APT cleanup skipped (INSTALL_DEPS=0)"
fi

echo "=== All build stages completed ==="
exit 0
