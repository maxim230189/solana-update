
#!/bin/bash
#set -x -e

echo "###################### WARNING!!! ###################################"
echo "#####################################################################"
echo

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
sudo apt update && sudo apt install -y build-essential pkg-config libssl-dev zlib1g-dev \
  libudev-dev llvm clang libclang-dev cmake protobuf-compiler curl git

mkdir agave
git clone https://github.com/anza-xyz/agave.git && cd agave
git checkout v3.0.0
./scripts/cargo-install-all.sh  /root/agave




