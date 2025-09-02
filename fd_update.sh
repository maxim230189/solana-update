#!/bin/bash

set -e

# Ensure the script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Please run it with 'sudo' or as root user." >&2
    exit 1
fi

echo "Starting installation of Firedancer prerequisites..."

# Update package lists
apt update -y </dev/tty
apt install git -y
apt install -y lsb-release gnupg software-properties-common
# Function to check and install curl and wget
install_curl_and_wget() {
    echo "Checking and installing curl and wget if missing..."
    if ! command -v curl &> /dev/null; then
        echo "curl is not installed. Installing..."
        apt install -y curl
    else
        echo "curl is already installed."
    fi

    if ! command -v wget &> /dev/null; then
        echo "wget is not installed. Installing..."
        apt install -y wget
    else
        echo "wget is already installed."
    fi
}

# Function to check and install GCC (version 13 required)
install_gcc() {
    REQUIRED_GCC_VERSION=13
    INSTALLED_GCC_VERSION=$(gcc --version 2>/dev/null | head -n1 | awk '{print $3}')

    if [[ -z "$INSTALLED_GCC_VERSION" ]] || [[ "$(printf '%s\n' "$REQUIRED_GCC_VERSION" "$INSTALLED_GCC_VERSION" | sort -V | head -n1)" != "$REQUIRED_GCC_VERSION" ]]; then
        echo "GCC version is outdated or missing. Installing GCC $REQUIRED_GCC_VERSION..."
#        apt install -y software-properties-common
        add-apt-repository -y ppa:ubuntu-toolchain-r/test
        apt update -y </dev/tty
        apt install -y gcc-$REQUIRED_GCC_VERSION g++-$REQUIRED_GCC_VERSION
        update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-$REQUIRED_GCC_VERSION 100
        update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-$REQUIRED_GCC_VERSION 100
    else
        echo "GCC version $INSTALLED_GCC_VERSION is sufficient."
    fi
}

# Function to check and install rustup
# install_rustup() {
#     if ! command -v rustup &> /dev/null; then
#         echo "Installing rustup..."
#         curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
#         rustup update stable --force
#         # echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$HOME/.bashrc"
#         . "$HOME/.bashrc"
#     else
#         echo "Rustup is already installed. Updating Rust..."
#         # rustup update
#         rustup update stable --force
#     fi
# }

install_rustup() {
    if ! command -v rustup &> /dev/null; then
        echo "Installing rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
        rustup update stable --force
    else
        echo "Rustup is already installed. Updating Rust..."
        rustup update stable --force
    fi
}





# Function to check and install Clang (compatible with GCC 13)
install_clang() {
    REQUIRED_CLANG_VERSION=15
    INSTALLED_CLANG_VERSION=$(clang --version 2>/dev/null | head -n1 | awk '{print $3}' | cut -d. -f1)

    if [[ -z "$INSTALLED_CLANG_VERSION" ]] || [[ "$INSTALLED_CLANG_VERSION" -lt "$REQUIRED_CLANG_VERSION" ]]; then
        echo "Clang version is outdated or missing. Installing Clang $REQUIRED_CLANG_VERSION..."
        # wget https://apt.llvm.org/llvm.sh
        # chmod +x llvm.sh
        ./llvm.sh $REQUIRED_CLANG_VERSION
        # rm llvm.sh
        update-alternatives --install /usr/bin/clang clang /usr/bin/clang-15 100
        update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-15 100
    else
        echo "Clang version $INSTALLED_CLANG_VERSION is sufficient."
    fi
}

# Function to check and install Make (ensure it's 4.3 or higher)
install_make() {
    REQUIRED_MAKE_VERSION=4.3
    INSTALLED_MAKE_VERSION=$(make --version 2>/dev/null | head -n1 | awk '{print $3}')

    if [[ -z "$INSTALLED_MAKE_VERSION" ]] || [[ "$(printf '%s\n' "$REQUIRED_MAKE_VERSION" "$INSTALLED_MAKE_VERSION" | sort -V | head -n1)" != "$REQUIRED_MAKE_VERSION" ]]; then
        echo "Make version is outdated or missing. Installing Make..."
        apt install -y build-essential make
    else
        echo "Make version $INSTALLED_MAKE_VERSION is sufficient."
    fi
}


create_user() {
    USERNAME="firedancer"

# Проверяем, существует ли уже пользователь
    if id "$USERNAME" &>/dev/null; then
        echo "User $USERNAME exist."
    else
        # Создаём пользователя
        # sudo useradd -M -s /usr/sbin/nologin "$USERNAME"
        sudo useradd -m -s /usr/sbin/nologin "$USERNAME"

        # Получаем UID и GID пользователя
        USER_ID=$(id -u "$USERNAME")
        GROUP_ID=$(id -g "$USERNAME")

        # Выводим информацию
        echo "User $USERNAME с."
        echo "UID: $USER_ID"
        echo "GID: $GROUP_ID"
    fi
}


install_fd() {
    echo "Installing Firedancer ..."
    USERNAME="firedancer"
    USER_ID=$(id -u "$USERNAME")
    GROUP_ID=$(id -g "$USERNAME")
    rm -rf /root/firedancer
    git clone --recurse-submodules https://github.com/firedancer-io/firedancer.git
    cd /root/firedancer
    git checkout v0.707.20306 # Or the latest Frankendancer release
    git submodule update --init --recursive
    sed -i "/^[ \t]*results\[ 0 \] = pwd\.pw_uid/c results[ 0 ] = $USER_ID;" ~/firedancer/src/app/fdctl/config.c
    sed -i "/^[ \t]*results\[ 1 \] = pwd\.pw_gid/c results[ 1 ] = $GROUP_ID;" ~/firedancer/src/app/fdctl/config.c
#    git submodule update
    ./deps.sh </dev/tty
    make -j fdctl solana
    cp /root/firedancer/build/native/gcc/bin/* /usr/local/bin/
}


configuring_fd() {
    mkdir -p /home/firedancer/solana_fd
    chown -R firedancer:firedancer /home/firedancer/solana_fd/
    cat > /home/firedancer/solana_fd/solana-testnet.toml <<EOF
name = "fd1"
user = "firedancer"
dynamic_port_range = "8004-8024"

[log]
    path = "/home/firedancer/solana_fd/solana.log"
#    level_logfile = "DEBUG"
#    level_stderr = "DEBUG"
#    level_flush = "DEBUG"

[ledger]
    path = "/home/firedancer/solana_fd/ledger"
    # accounts_path = "/mnt/accounts"
    limit_size = 50_000_000

[gossip]
    entrypoints = [
    "entrypoint.testnet.solana.com:8001",
    "entrypoint2.testnet.solana.com:8001",
    "entrypoint3.testnet.solana.com:8001",
    ]

[layout]
    affinity = "auto"
    agave_affinity = "auto"
    verify_tile_count = 1
    bank_tile_count = 1

[consensus]
    identity_path = "/home/firedancer/solana_fd/validator-keypair.json"
    vote_account_path = "/home/firedancer/solana_fd/vote-account-keypair.json"

    expected_genesis_hash = "4uhcVJyU9pJkvQyS88uRDiswHXSCkY3zQawwpjk2NsNY"
    known_validators = [
        "5D1fNXzvv5NjV1ysLjirC4WY92RNsVH18vjmcszZd8on",
        "dDzy5SR3AXdYWVqbDEkVFdvSPCtS9ihF5kJkHCtXoFs",
        "Ft5fbkqNa76vnsjYNwjDZUXoTWpP7VYm3mtsaQckQADN",
        "eoKpUABi59aT4rR9HGS3LcMecfut9x7zJyodWWP43YQ",
        "9QxCLckBiJc783jnMvXZubK4wH86Eqqvashtrwvcsgkv",
    ]
    snapshot_fetch = true
    genesis_fetch = true

[rpc]
    port = 8899
    full_api = true
    private = true
    only_known = false

[reporting]
    solana_metrics_config = "host=https://metrics.solana.com:8086,db=tds,u=testnet_write,p=c4fa841aa918bf8274e3e2a44d77568d9861b3ea"

[snapshots]
    full_snapshot_interval_slots = 100000
    incremental_snapshot_interval_slots = 4000
    maximum_full_snapshots_to_retain = 1
    maximum_incremental_snapshots_to_retain = 1
    path = "/home/firedancer/solana_fd/snapshots"
EOF

    cat > /etc/systemd/system/firedancer.service <<EOF
[Unit]
Description=Firedancer Node
Wants=network.target
After=network.target

[Service]
# User=root
# Group=root
ExecStart=/bin/bash -c ' \\
    /usr/local/bin/fdctl configure init all --config /home/firedancer/solana_fd/solana-testnet.toml && \\
    /usr/local/bin/fdctl run --config /home/firedancer/solana_fd/solana-testnet.toml'
WantedBy=multi-user.target
EOF
}

logrotate_config() {
    if ! command -v logrotate &>/dev/null; then
        echo "logrotate not found, installing ..."
        apt install -y logrotate
    else
        echo "logrotate already installed."
    fi

    cat > /etc/logrotate.d/fd.logrotate <<EOF
/home/firedancer/solana_fd/solana.log {
  rotate 7
  daily
  missingok
  copytruncate
  notifempty
}
EOF
systemctl restart logrotate.service
}

move_keys() {
    cp /root/solana/validator-keypair.json /home/firedancer/solana_fd/validator-keypair.json
    cp /root/solana/vote-account-keypair.json /home/firedancer/solana_fd/vote-account-keypair.json
    chmod 660 /home/firedancer/solana_fd/validator-keypair.json
    chown root:firedancer /home/firedancer/solana_fd/validator-keypair.json
    chmod 660 /home/firedancer/solana_fd/vote-account-keypair.json
    chown root:firedancer /home/firedancer/solana_fd/vote-account-keypair.json
}

start_fd() {
    # rm -rf /root/.local/share/solana/
    systemctl daemon-reload
    # service firedancer start
}

stop_solana() {
    if [[ `service solana status | grep active` =~ "running" ]]; then
        echo "Stopping Solana ..."
        service solana stop
        sleep 5
        systemctl disable solana.service
    fi
    systemctl stop firedancer
}

# Run all installation steps

stop_solana
create_user
install_fd
start_fd

echo -e "Firedancer node installed, now reboot server and run immediately after boot: \033[0;32mfdctl configure init hugetlbfs\033[0m"
echo -e "And start Firedancer: \033[0;32mservice firedancer start\033[0m"
echo -e "You can check node status by the command: \033[0;32mservice firedancer status\033[0m"
echo -e "You can check node logs by the command: \033[0;32mjournalctl -u firedancer -fn 50\033[0m"
echo -e "You can check node logs by the command: \033[0;32mfdctl monitor --config /home/firedancer/solana_fd/solana-testnet.toml\033[0m"
reboot now

# echo -e '\033[0;32mChecking Firedancer status : \033[0m' && sleep 5
# if [[ `service firedancer status | grep active` =~ "running" ]]; then
#   echo -e "\033[0;32mYour node installed and works!\033[0m"
#   echo -e "You can check node status by the command: \033[0;32mservice firedancer status\033[0m"
#   echo -e "You can check node logs by the command: \033[0;32mjournalctl -u firedancer -fn 50\033[0m"
#   echo -e "You can check node logs by the command: \033[0;32mfdctl monitor --config /home/firedancer/solana_fd/solana-testnet.toml\033[0m"
# else
#   echo -e "\033[0;31mYour node was not installed correctly, please check logs and reinstall.\033[0m"
# fi
