#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Agave updater (fixed version, NO service edits)
# -----------------------------------------------------------------------------
# Этот скрипт:
#  1) Ставит зависимости и Rust/cargo (идемпотентно);
#  2) Качает исходники Agave ТОЛЬКО для нужного тега (версию укажи ниже);
#  3) Собирает ТОЛЬКО валидатор в:
#       /root/.local/share/solana/install/releases/<ver>/solana-release
#  4) Переключает symlink:
#       /root/.local/share/solana/install/active_release -> .../<ver>/solana-release
#  5) Делает совместимый symlink:
#       /root/agave/bin -> /root/.local/share/solana/install/active_release/bin
#     (чтобы старые ExecStart=/root/agave/bin/agave-validator продолжали работать)
#  6) Считывает из ТВОЕГО service-файла пути --ledger / --snapshots (Только чтение!)
#  7) Ждёт "окно рестарта" и делает безопасный restart сервиса.
#
# ВАЖНО: Сервисный файл НЕ изменяется. Если нужно что-то поменять в юните — делай руками.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

# Понятные таймстамп-логи
log(){ printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"; }
# Аккуратная обработка ошибок
trap 'log "❌ Ошибка на строке $LINENO. Прерываю."' ERR

# >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> РЕДАКТИРУЙ ТОЛЬКО ЭТО <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
VERSION="3.0.1"     # <-- ВПИШИ нужную версию Agave (без префикса v), напр. 3.0.1
# <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

# Пути установки (совместимы с стандартным layout agave/solana)
INSTALL_ROOT="/root/.local/share/solana/install"
INSTALL_DIR="$INSTALL_ROOT/releases/$VERSION/solana-release"
ACTIVE_LINK="$INSTALL_ROOT/active_release"

# Временная рабочая папка под исходники
WORK="/tmp/agave-src-$VERSION"
TARBALL="v$VERSION.tar.gz"
URL="https://github.com/anza-xyz/agave/archive/refs/tags/$TARBALL"

# Проверка прав
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  log "⚠️  Нужны root-права. Запусти: sudo bash agave-update-fixed.sh"
  exit 1
fi

log "▶️  Обновление Agave до версии v$VERSION (без правок service-файла)"

# --- 0. Ставим зависимости (идемпотентно) -----------------------------------
export DEBIAN_FRONTEND=noninteractive
log "🔧 Проверяю/ставлю зависимости сборки (build-essential, openssl, llvm, и т.д.)..."
apt-get update -y
apt-get install -y build-essential pkg-config libssl-dev zlib1g-dev \
  libudev-dev llvm clang libclang-dev cmake protobuf-compiler curl git jq

# --- 1. Устанавливаем Rust/cargo при необходимости ---------------------------
if ! command -v cargo >/dev/null 2>&1; then
  log "🦀 Cargo не найден — устанавливаю Rust toolchain..."
  curl -sSf https://sh.rustup.rs | sh -s -- -y
  # подхватим cargo в текущей сессии, если скрипт запущен не через login-shell
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
  fi
fi
log "✅ Cargo: $(cargo --version 2>/dev/null || echo 'не обнаружен')"

# --- 2. Читаем активный service-файл (ТОЛЬКО ЧТЕНИЕ) -------------------------
SERVICE_FILE="$(systemctl show -p FragmentPath solana | awk -F= '{print $2}')"
if [[ -z "$SERVICE_FILE" || ! -f "$SERVICE_FILE" ]]; then
  SERVICE_FILE="/etc/systemd/system/solana.service"
fi
log "📄 Использую service-файл только для чтения путей: $SERVICE_FILE"

# Вытаскиваем пути --ledger и --snapshots (если нет — поставим разумный дефолт)
LEDGER="$(grep -Po '(?<=--ledger )\S+' "$SERVICE_FILE" 2>/dev/null | head -n1 || true)"
SNAPS="$(grep -Po '(?<=--snapshots )\S+' "$SERVICE_FILE" 2>/dev/null | head -n1 || true)"
if [[ -z "$LEDGER" ]]; then
  LEDGER="/mnt/ramdisk/ledger"
  log "ℹ️  В service-файле не найден --ledger. Использую дефолт: $LEDGER"
else
  log "📌 Найден путь ledger из service-файла: $LEDGER"
fi
if [[ -n "$SNAPS" ]]; then
  log "📌 Найден путь snapshots из service-файла: $SNAPS"
else
  log "ℹ️  --snapshots в service-файле не найден. Буду запускать без него."
fi

# Не редактируем, только подсказываем важные вещи для Agave 3.x
#  - LimitMEMLOCK=2000000000 обязательно
#  - --dynamic-port-range шириной >= 25 портов (и не дублировать опцию)
if ! grep -q 'LimitMEMLOCK=2000000000' "$SERVICE_FILE" 2>/dev/null; then
  log "⚠️  Рекомендация: добавь LimitMEMLOCK=2000000000 в [Service] $SERVICE_FILE (требование Agave 3.x)"
fi
if grep -q -- '--dynamic-port-range [0-9]\{1,5\}-[0-9]\{1,5\}' "$SERVICE_FILE"; then
  WIDTH="$(grep -Po -- '--dynamic-port-range \K[0-9]+-[0-9]+' "$SERVICE_FILE" | awk -F- '{print $2-$1}' | head -n1 || echo 0)"
  if [[ "${WIDTH:-0}" -lt 25 ]]; then
    log "⚠️  Рекомендация: расширь --dynamic-port-range минимум на 25 портов (сейчас ~${WIDTH:-0})"
  fi
fi

# --- 3. Качаем исходники нужного тега и готовим каталог релиза ---------------
if [[ -x "$INSTALL_DIR/bin/agave-validator" ]]; then
  log "✅ Версия v$VERSION уже собрана: $INSTALL_DIR (пропускаю сборку)"
else
  log "⬇️  Скачиваю архив исходников: $URL"
  rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"
  curl -fsSL -o "$TARBALL" "$URL"
  tar -xzf "$TARBALL"

  log "🛠️  Собираю ТОЛЬКО валидатор в: $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  # Иногда сборка на некоторых системах просит явные пути к OpenSSL
  export OPENSSL_DIR=/usr
  export OPENSSL_LIB_DIR=/usr/lib/x86_64-linux-gnu
  export PKG_CONFIG_PATH=/usr/lib/x86_64-linux-gnu/pkgconfig

  bash "agave-$VERSION/scripts/cargo-install-all.sh" --validator-only "$INSTALL_DIR"
fi

# --- 4. Переключаем active_release + делаем совместимый symlink --------------
log "🔗 Переключаю active_release -> $INSTALL_DIR"
ln -sfn "$INSTALL_DIR" "$ACTIVE_LINK"

log "🔗 Делаю совместимый путь /root/agave/bin -> active_release/bin (без правок юнита)"
mkdir -p /root/agave
ln -sfn "$ACTIVE_LINK/bin" /root/agave/bin

# --- 5. Ожидаем «окно рестарта», затем мягко рестартуем сервис ---------------
BIN="$ACTIVE_LINK/bin/agave-validator"
log "⏳ Жду «окно рестарта» (wait-for-restart-window), чтобы не ловить высокий delinquent..."
if [[ -n "$SNAPS" ]]; then
  "$BIN" --ledger "$LEDGER" --snapshots "$SNAPS" \
    wait-for-restart-window --min-idle-time 10 --max-delinquent-stake 10
else
  "$BIN" --ledger "$LEDGER" \
    wait-for-restart-window --min-idle-time 10 --max-delinquent-stake 10
fi

log "♻️  Перезапускаю сервис solana (юнит НЕ изменяем, только рестарт)"
systemctl restart solana

# --- 6. Короткий отчёт --------------------------------------------------------
sleep 2
NEW_VER="$("$BIN" --version 2>/dev/null || true)"
log "✅ Готово. Текущая версия бинаря: ${NEW_VER:-<не удалось прочитать>}"
log "📂 Активный релиз: $ACTIVE_LINK -> $INSTALL_DIR"
log "📌 Ledger: $LEDGER"
[[ -n "$SNAPS" ]] && log "📌 Snapshots: $SNAPS" || true
log "ℹ️  Если нужно менять флаги/лимиты — правь руками $SERVICE_FILE и делай: systemctl daemon-reload && systemctl restart solana"
