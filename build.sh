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

SRC_DIR=${SRC_DIR:-.} # it MUST be transmissiond src directory
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
# PATHS AND ARCHITECTURE
# ==============================================================================

echo "=== STEP 1: Preparing build environment ==="

if [ ! -d "${SRC_DIR}" ]; then
    die "Source directory does not exist: ${SRC_DIR}"
fi

cd "${SRC_DIR}"
SRC_DIR=$(pwd -P)

for tool in id dpkg dpkg-deb dpkg-query; do
    require_command "${tool}"
done

# Validate Debian package version syntax.
if ! dpkg --validate-version "${PACKAGE_VERSION}" >/dev/null 2>&1; then
    die "Invalid Debian package version: ${PACKAGE_VERSION}"
fi

# Detect the architecture of the current system.
ARCH=$(dpkg --print-architecture)

if [ -z "${ARCH}" ]; then
    die "Unable to determine system architecture"
fi

echo "Target architecture: ${ARCH}"

# Define absolute paths for working directories.
BUILD_DIR="${SRC_DIR}/build-${ARCH}"

if [ "${CLEAN_BUILD}" -eq 1 ]; then
    rm -rf "${BUILD_DIR}"
fi

mkdir -p "${BUILD_DIR}"


# Debian package name.
PKG_NAME="transmissiond-systemd-${ARCH}"

OUTPUT_DIR="${SRC_DIR}/dist/"
mkdir -p "${OUTPUT_DIR}"
cd "${OUTPUT_DIR}"
OUTPUT_DIR=$(pwd -P)

cd "${SRC_DIR}"

# ==============================================================================
# DEPENDENCIES
# ==============================================================================

echo "=== STEP 2: Checking build tools ==="

# Install dependencies if enabled in the configuration.
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
    echo "INSTALL_DEPS=0: skipping dependency installation"
fi

# Verify all required tools after dependency installation.
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

echo "=== STEP 4: Configuring CMake ==="

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

echo "=== STEP 5: Building Transmission ==="

cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"

# ==============================================================================
# TEMPORARY WORKSPACE
# ==============================================================================

echo "=== STEP 6: Preparing temporary workspace ==="

# Создаём уникальный временный каталог внутри OUTPUT_DIR; XXXXXX — шаблон для mktemp.
WORK_DIR=$(mktemp -d "${BUILD_DIR}/.transmission-build-${ARCH}.XXXXXX")
    if [ -z "${WORK_DIR}" ] || [ ! -d "${WORK_DIR}" ]; then
       die "Failed to create tmp BUILD_DIR (${WORK_DIR})"
    fi
# Определяем путь к корню будущего Debian-пакета — структура каталогов, которая попадёт в .deb.
PKG_ROOT="${WORK_DIR}/pkg-root"

# Создаём корневой каталог пакета, чтобы cmake --install было куда устанавливать файлы.
mkdir -p "${PKG_ROOT}"

# ==============================================================================
# INSTALL COMPILED FILES
# ==============================================================================

DESTDIR="${PKG_ROOT}" cmake --install "${BUILD_DIR}"



# ==============================================================================
# VERIFY BINARIES
# ==============================================================================

echo "=== STEP 8: Validating ELF files ==="

# Задаём путь к временному файлу, в который соберём список всех ELF-бинарников из пакета.
ELF_LIST="${WORK_DIR}/elf-files.txt"

: > "${ELF_LIST}"

# Ищем все обычные файлы в корне пакета и для каждого запускаем file, чтобы отфильтровать только ELF.
find "${PKG_ROOT}" -type f -exec file {} \; | awk -F: '/: ELF/ {print $1}' > "${ELF_LIST}"

if [ ! -s "${ELF_LIST}" ]; then
    die "No ELF files found in package root"
fi
# ==============================================================================
# STRIP
# ==============================================================================
if [ "${STRIP_BINARIES}" -eq 1 ]; then
    echo "=== Stripping binaries ==="
    while IFS= read -r f; do
        strip --strip-unneeded "$f" 2>/dev/null
    done < "${ELF_LIST}"
else
    echo "STRIP_BINARIES=0: skipping strip"
fi





# ==============================================================================
# RUNTIME DEPENDENCIES
# ==============================================================================

echo "=== STEP 9: Detecting runtime dependencies ==="
RUNTIME_DEPS_FILE="${WORK_DIR}/runtime-deps.txt" # Файл для накопления имён Debian-пакетов с необходимыми библиотеками.
: > "${RUNTIME_DEPS_FILE}" # Очищаем файл, чтобы исключить данные от предыдущих операций.

while IFS= read -r bin; do # Последовательно обрабатываем каждый ELF-файл из списка.

    if ! readelf -d "${bin}" 2>/dev/null | grep -q '(NEEDED)'; then # Проверяем, есть ли у ELF динамические зависимости.
        continue # Пропускаем статически скомпонованные файлы и файлы без динамических библиотек.
    fi

    # Get list of dynamically linked libraries for this binary.
    # The awk script prints absolute paths of resolved libraries and exits 1 if any are missing.
    BIN_LIBS=$(ldd "${bin}" 2>&1 | awk '
        /not found/ { failed = 1 }
        $2 == "=>" && $3 ~ /^\// { print $3 }
        $1 ~ /^\// { print $1 }
        END { if (failed) exit 1 }
    ') || die "Unable to resolve runtime dependencies: ${bin}"

    # Process each library individually.
    for library in ${BIN_LIBS}; do
        REAL_LIBRARY=$(readlink -f "${library}") || die "Cannot resolve library: ${library}"
        [ -f "${REAL_LIBRARY}" ] || die "Runtime library does not exist: ${REAL_LIBRARY}"
        OWNER=$(dpkg-query -S "${REAL_LIBRARY}" 2>/dev/null | sed -n '1s/: .*//p') || die "Cannot determine package owner: ${REAL_LIBRARY}"
        [ -n "${OWNER}" ] || die "No Debian package owns library: ${REAL_LIBRARY}"
        printf '%s\n' "${OWNER%%:*}" >> "${RUNTIME_DEPS_FILE}"
    done

done < "${ELF_LIST}" # Завершаем обработку всех ELF-файлов.


[ -s "${RUNTIME_DEPS_FILE}" ] || die "Unable to determine runtime dependencies" # Проверяем, что удалось обнаружить хотя бы одну зависимость.

RUNTIME_DEPS=$(sort -u "${RUNTIME_DEPS_FILE}" | paste -sd ',' -) # Удаляем дубликаты и формируем строку Depends для Debian.

[ -n "${RUNTIME_DEPS}" ] || die "Runtime dependency list is empty" # Проверяем, что итоговая строка зависимостей не пуста.

echo "Runtime dependencies: ${RUNTIME_DEPS}" # Выводим обнаруженные зависимости для контроля.

# ==============================================================================
# DEBIAN CONTROL FILES
# ==============================================================================

echo "=== STEP 10: Creating Debian control files ==="

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
# POSTINST
# ==============================================================================

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
# PRERM
# ==============================================================================

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
# POSTRM
# ==============================================================================

cat > "${PKG_ROOT}/DEBIAN/postrm" <<'EOF'
#!/bin/sh

set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

exit 0
EOF

chmod 755 \
    "${PKG_ROOT}/DEBIAN/postinst" \
    "${PKG_ROOT}/DEBIAN/prerm" \
    "${PKG_ROOT}/DEBIAN/postrm"

chmod 644 "${PKG_ROOT}/DEBIAN/control"

# ==============================================================================
# BUILD DEB PACKAGE
# ==============================================================================

echo "=== STEP 11: Building Debian package ==="

TEMP_DEB="${WORK_DIR}/${PKG_NAME}_${PACKAGE_VERSION}_${ARCH}.deb"

dpkg-deb --build --root-owner-group "${PKG_ROOT}" "${TEMP_DEB}"

# ==============================================================================
# FINAL VALIDATION
# ==============================================================================

echo "=== STEP 12: Validating Debian package ==="

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

if ! dpkg-deb --contents "${TEMP_DEB}" |
    grep -Fq './usr/bin/transmission-daemon'
then
    die "transmission-daemon is missing from the Debian package"
fi

# Extract control archive to validate maintainer scripts.
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

# Move the package to its final destination only after successful validation.

FINAL_DEB="${OUTPUT_DIR}/${PKG_NAME}_${PACKAGE_VERSION}_${ARCH}.deb"

mv -f "${TEMP_DEB}" "${FINAL_DEB}"

# ==============================================================================
# SUCCESS
# ==============================================================================

echo "============================================================"
echo "SUCCESS: ${FINAL_DEB}"
echo "Package: ${PKG_NAME}"
echo "Version: ${PACKAGE_VERSION}"
echo "Architecture: ${ARCH}"
echo "Runtime dependencies: ${RUNTIME_DEPS}"
echo "============================================================"

# ==============================================================================
# SYSTEM CLEANUP
# ==============================================================================

if [ "${CLEAN_BUILD}" -eq 0 ]; then
    echo "CLEAN_BUILD=0: preserving CMake build directory"
else
    rm -rf "${BUILD_DIR}"
    echo "CLEAN_BUILD=1: CMake build directory was removed"
fi

if [ "${INSTALL_DEPS}" -eq 1 ]; then
    apt-get autoremove -y --purge
    echo "APT cleanup : autoremove"
else
    echo "INSTALL_DEPS=0: skipping APT cleanup"
fi

echo "=== BUILD COMPLETED ==="

exit 0