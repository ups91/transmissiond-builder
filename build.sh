
#!/bin/sh
# ==============================================================================
# RU: Нативная сборка Transmission и создание Debian-пакета (.deb).
# EN: Native Transmission build and Debian package (.deb) creation.
#
# RU: Скрипт можно запускать непосредственно в Debian/Ubuntu или в Docker.
# EN: The script can run directly on Debian/Ubuntu or inside Docker.
# ==============================================================================

# RU: Останавливаемся при ошибке или использовании необъявленной переменной.
# EN: Stop on errors and on use of unset variables.
set -eu

# ==============================================================================
# CONFIGURATION / КОНФИГУРАЦИЯ
# ==============================================================================

# RU: Каталог с исходниками Transmission.
# EN: Transmission source directory.
SRC_DIR=${SRC_DIR:-.}

# RU: Версия пакета.
# EN: Package version.
PACKAGE_VERSION=${PACKAGE_VERSION:-4.1.0-custom}

# RU: Имя сопровождающего пакета.
# EN: Package maintainer.
MAINTAINER=${MAINTAINER:-"UPS <ups@localhost>"}

# RU: Количество параллельных задач сборки.
# EN: Number of parallel build jobs.
BUILD_JOBS=${BUILD_JOBS:-1}

# RU: Файл дополнительного APT-репозитория Ports, если он использовался.
# EN: Additional APT Ports repository file, if it was used.
PORTS_SOURCE_FILE=${PORTS_SOURCE_FILE:-/etc/apt/sources.list.d/arm64-ports.sources}

# ==============================================================================
# PATHS AND ARCHITECTURE / ПУТИ И АРХИТЕКТУРА
# ==============================================================================

echo "=== STEP 1: Preparing build environment / Подготовка окружения ==="

# RU: Приводим путь к исходникам к абсолютному виду.
# EN: Convert the source directory path to an absolute path.
cd "${SRC_DIR}"
SRC_DIR=$(pwd -P)

# RU: Архитектура определяется непосредственно в текущей системе.
# EN: Detect architecture directly on the current system.
ARCH=$(dpkg --print-architecture)

case "${ARCH}" in
    amd64|i386|arm64|armhf)
        echo "Target architecture / Целевая архитектура: ${ARCH}"
        ;;
    *)
        echo "ERROR: Unsupported architecture / Неподдерживаемая архитектура: ${ARCH}" >&2
        exit 1
        ;;
esac

# RU: Формируем абсолютные пути.
# EN: Define absolute paths.
BUILD_DIR="${SRC_DIR}/build-${ARCH}"
PKG_ROOT="${SRC_DIR}/pkg-root-${ARCH}"
DEB_FILE="${SRC_DIR}/transmission_${ARCH}.deb"

# RU: Проверяем наличие исходников.
# EN: Check that source files are present.
if [ ! -f "${SRC_DIR}/CMakeLists.txt" ]; then
    echo "ERROR: CMakeLists.txt not found in ${SRC_DIR}" >&2
    exit 1
fi

# ==============================================================================
# CLEANUP / ОЧИСТКА
# ==============================================================================

echo "=== STEP 2: Cleaning previous build / Очистка предыдущей сборки ==="

rm -rf "${BUILD_DIR}" "${PKG_ROOT}" "${DEB_FILE}"

# ==============================================================================
# DEPENDENCIES / ЗАВИСИМОСТИ
# ==============================================================================

echo "=== STEP 3: Installing build dependencies / Установка зависимостей ==="

# RU: Отключаем интерактивные запросы APT.
# EN: Disable interactive APT prompts.
export DEBIAN_FRONTEND=noninteractive

apt-get update

apt-get install -y --no-install-recommends \
    build-essential \
    binutils \
    ca-certificates \
    cmake \
    file \
    git \
    pkg-config \
    python3 \
    libcurl4-openssl-dev \
    libssl-dev \
    libsystemd-dev \
    zlib1g-dev

# ==============================================================================
# CMAKE CONFIGURATION / КОНФИГУРАЦИЯ CMAKE
# ==============================================================================

echo "=== STEP 4: Configuring CMake / Конфигурация CMake ==="

# RU: Нативная сборка с использованием компилятора текущей архитектуры.
# EN: Native build using the compiler for the current architecture.
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DENABLE_DAEMON=ON \
    -DENABLE_UTILS=ON \
    -DENABLE_CLI=ON \
    -DENABLE_TESTS=OFF \
    -DWITH_SYSTEMD=ON \
    -DWITH_CRYPTO=openssl

# ==============================================================================
# BUILD / СБОРКА
# ==============================================================================

echo "=== STEP 5: Building Transmission / Компиляция Transmission ==="

cmake --build "${BUILD_DIR}" --parallel "${BUILD_JOBS}"

# ==============================================================================
# INSTALL TO PACKAGE ROOT / УСТАНОВКА ВО ВРЕМЕННЫЙ КАТАЛОГ
# ==============================================================================

echo "=== STEP 6: Installing into package directory / Установка в каталог пакета ==="

mkdir -p "${PKG_ROOT}"

DESTDIR="${PKG_ROOT}" cmake --install "${BUILD_DIR}"

# ==============================================================================
# STRIP BINARIES / УДАЛЕНИЕ ОТЛАДОЧНОЙ ИНФОРМАЦИИ
# ==============================================================================

echo "=== STEP 7: Stripping binaries / Удаление отладочной информации ==="

# RU: Используем strip текущей архитектуры.
# EN: Use strip for the current architecture.
find "${PKG_ROOT}" -type f -exec sh -c '
    for bin do
        if file "$bin" | grep -q "ELF"; then
            echo "Stripping / Обработка: $bin"
            strip --strip-unneeded "$bin" || true
        fi
    done
' sh {} +

# ==============================================================================
# VERIFY BINARIES / ПРОВЕРКА БИНАРНЫХ ФАЙЛОВ
# ==============================================================================

echo "=== STEP 8: Checking installed binaries / Проверка бинарных файлов ==="

find "${PKG_ROOT}" -type f -exec sh -c '
    for bin do
        if file "$bin" | grep -q "ELF"; then
            ls -lh "$bin"
        fi
    done
' sh {} +

if [ ! -x "${PKG_ROOT}/usr/bin/transmission-daemon" ]; then
    echo "ERROR: transmission-daemon was not installed" >&2
    exit 1
fi

# ==============================================================================
# DEBIAN CONTROL FILES / УПРАВЛЯЮЩИЕ ФАЙЛЫ DEBIAN
# ==============================================================================

echo "=== STEP 9: Creating Debian control files / Создание управляющих файлов ==="

mkdir -p "${PKG_ROOT}/DEBIAN"

# RU: Описание пакета и runtime-зависимости.
# EN: Package metadata and runtime dependencies.
cat > "${PKG_ROOT}/DEBIAN/control" <<EOF
Package: transmission-${ARCH}
Version: ${PACKAGE_VERSION}
Section: net
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Depends: libc6, libcurl4, libssl3, libsystemd0, zlib1g
Description: BitTorrent client (transmission-daemon and CLI) built for ${ARCH}
EOF

# RU: Создаём системного пользователя Transmission.
# EN: Create the Transmission system user.
cat > "${PKG_ROOT}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if ! id transmission >/dev/null 2>&1; then
    useradd --system \
        --home-dir /var/lib/transmission-daemon \
        --create-home \
        --shell /usr/sbin/nologin \
        transmission
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
fi

echo "Transmission successfully installed."
exit 0
EOF

# RU: Останавливаем службу перед удалением или обновлением пакета.
# EN: Stop the service before package removal or upgrade.
cat > "${PKG_ROOT}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop transmission-daemon.service 2>/dev/null || true
fi

exit 0
EOF

# RU: Обновляем состояние systemd после удаления пакета.
# EN: Reload systemd state after package removal.
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
# BUILD DEB PACKAGE / СБОРКА DEB-ПАКЕТА
# ==============================================================================

echo "=== STEP 10: Building Debian package / Сборка Debian-пакета ==="

dpkg-deb --build --root-owner-group "${PKG_ROOT}" "${DEB_FILE}"

# ==============================================================================
# FINAL VALIDATION / ФИНАЛЬНАЯ ПРОВЕРКА
# ==============================================================================

echo "=== STEP 11: Validating package / Проверка пакета ==="

dpkg-deb --info "${DEB_FILE}"
dpkg-deb --contents "${DEB_FILE}" >/dev/null
file "${PKG_ROOT}/usr/bin/transmission-daemon"
file "${DEB_FILE}"
ls -lh "${DEB_FILE}"

echo "============================================================"
echo "SUCCESS: ${DEB_FILE}"
echo "Architecture / Архитектура: ${ARCH}"
echo "============================================================"

# ==============================================================================
# SYSTEM CLEANUP / ОЧИСТКА СИСТЕМЫ
# ==============================================================================

echo "=== STEP 12: Removing unused dependencies / Удаление неиспользуемых зависимостей ==="

# RU: Удаляем автоматически установленные и больше не нужные пакеты.
# EN: Remove automatically installed packages that are no longer needed.
apt-get autoremove -y --purge

echo "=== STEP 13: Cleaning APT repositories and cache / Очистка APT-репозиториев и кэша ==="

# RU: Удаляем только явно указанный дополнительный файл Ports.
# EN: Remove only the explicitly configured additional Ports source file.
if [ -n "${PORTS_SOURCE_FILE}" ] && [ -f "${PORTS_SOURCE_FILE}" ]; then
    rm -f "${PORTS_SOURCE_FILE}"
fi

# RU: Обновляем индексы после изменения списка источников.
# EN: Refresh package indexes after changing repository sources.
apt-get update

# RU: Очищаем загруженный кэш APT.
# EN: Clean the downloaded APT package cache.
apt-get clean

echo "=== BUILD AND CLEANUP COMPLETED / СБОРКА И ОЧИСТКА ЗАВЕРШЕНЫ ==="
