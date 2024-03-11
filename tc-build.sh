#!/usr/bin/env bash

# Secret Variable for CI
# LLVM_NAME | Your desired Toolchain Name
# TG_TOKEN | Your Telegram Bot Token
# TG_CHAT_ID | Your Telegram Channel / Group Chat ID
# GL_USERNAME | Your Gitlab Username
# GL_EMAIL | Your Gitlab Email
# GL_TOKEN | Your Gitlab Token ( repo & repo_hook )
# GL_PUSH_REPO_URL | Your Repository for store compiled Toolchain ( without https:// or www. ) ex. gitlab.com/Tiktodz/electrowizard-clang.git

# Function to show an informational message
msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

# Set a directory
DIR="$(pwd ...)"
install=$DIR/install
src=$DIR/src

# Inlined function to post a message
export BOT_MSG_URL="https://api.telegram.org/bot$TG_TOKEN/sendMessage"
tg_post_msg() {
    curl -s -X POST "$BOT_MSG_URL" \
        -d chat_id="$TG_CHAT_ID" \
        -d "disable_web_page_preview=true" \
        -d "parse_mode=html" \
        -d text="$1"

}

tg_post_build() {
    curl --progress-bar -F document=@"$1" "$BOT_MSG_URL" \
        -F chat_id="$TG_CHAT_ID" \
        -F "disable_web_page_preview=true" \
        -F "parse_mode=html" \
        -F caption="$3"
}

tg_post_erlog() {
    curl -F document=@"build.log" "https://api.telegram.org/bot$TG_TOKEN/sendDocument" \
        -F chat_id="$TG_CHAT_ID" \
        -F caption="Build ran into errors, plox check logs"
}

# Build Info
rel_date="$(date "+%Y%m%d")"              # ISO 8601 format
rel_friendly_date="$(date "+%B %-d, %Y")" # "Month day, year" format
builder_commit="$(git rev-parse HEAD)"

# Send a notificaton to TG
tg_post_msg "<b>$LLVM_NAME: Toolchain Compilation Started</b>%0A<b>Date : </b><code>$rel_friendly_date</code>%0A<b>Toolchain Script Commit : </b><code>$builder_commit</code>%0A"

# Build LLVM
msg "$LLVM_NAME: Building LLVM..."
tg_post_msg "<b>$LLVM_NAME: Building LLVM. . .</b>"
./build-llvm.py \
    --vendor-string "$LLVM_NAME" \
    --assertions \
    --build-stage1-only \
    --build-target distribution \
    --check-targets clang lld llvm \
    --install-folder "$install" \
    --install-target distribution \
    --projects all \
    --quiet-cmake \
    --shallow-clone \
    --show-build-commands \
    --targets ARM AArch64 X86 \
    --ref "llvmorg-17.0.6" 2>&1 | tee build.log

# Check if the final clang binary exists or not.
for clang in install/bin/clang-1*; do
    if [ ! -f "$clang" ]; then
        err "Building LLVM failed ! Kindly check errors !!"
        tg_post_erlog
        exit 1
    fi
done

# Build binutils
msg "$LLVM_NAME: Building binutils..."
tg_post_msg "<b>$LLVM_NAME: Building Binutils. . .</b>"
./build-binutils.py --install-folder "$install" --show-build-commands --targets arm aarch64 x86_64

# Remove unused products
rm -fr $DIR/install/include
rm -f $DIR/install/lib/*.a install/lib/*.la

# Strip remaining products
for f in $(find $DIR/install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
    strip -s "${f::-1}"
done

# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
for bin in $(find $DIR/install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
    # Remove last character from file output (':')
    bin="${bin::-1}"

    echo "$bin"
    patchelf --set-rpath "$DIR/install/lib" "$bin"
done

# Release Info
pushd $src/llvm-project || exit
llvm_commit="$(git rev-parse HEAD)"
short_llvm_commit="$(cut -c-8 <<<"$llvm_commit")"
popd || exit

llvm_commit_url="https://github.com/llvm/llvm-project/commit/$short_llvm_commit"
binutils_ver="$(echo $src/binutils-* | sed "s/binutils-//g")"
clang_version="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"

tg_post_msg "<b>$LLVM_NAME: Toolchain compilation Finished</b>%0A<b>Clang Version : </b><code>$clang_version</code>%0A<b>LLVM Commit : </b><code>$llvm_commit_url</code>%0A<b>Binutils Version : </b><code>$binutils_ver</code>"

# Push to Gitlab
# Update Git repository
git config --global user.name $GL_USERNAME
git config --global user.email $GL_EMAIL
git clone https://$GL_USERNAME:$GL_TOKEN@$GL_PUSH_REPO_URL rel_repo
pushd $(pwd)/rel_repo || exit
rm -fr ./*
cp -r ../install/* .
git checkout
git add .
git commit -asm "$LLVM_NAME: Bump to $rel_date release

LLVM commit: $llvm_commit_url
Clang Version: $clang_version
Binutils version: $binutils_ver"
git push -f
popd || exit
tg_post_msg "<b>$LLVM_NAME: Toolchain pushed to <code>https://$GL_PUSH_REPO_URL</code></b>"
