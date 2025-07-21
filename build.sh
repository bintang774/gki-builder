#!/usr/bin/env bash
workdir=$(pwd)

# Handle error
set -e
exec > >(tee $workdir/build.log) 2>&1
trap 'error "Failed at line $LINENO [$BASH_COMMAND]"' ERR

# Import config and functions
source $workdir/config.sh
source $workdir/functions.sh

# Set timezone
sudo timedatectl set-timezone "$TIMEZONE"

# Clone kernel source
KSRC="$workdir/ksrc"
log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 $KERNEL_REPO -b $KERNEL_BRANCH $KSRC

cd $KSRC
LINUX_VERSION=$(make kernelversion)
DEFCONFIG_FILE=$(find ./arch/arm64/configs -name "$KERNEL_DEFCONFIG")
cd $workdir

# Set KernelSU Variant
log "Setting KernelSU variant..."
case "$KSU" in
  "Next") VARIANT="KSUN" ;;
  "Suki") VARIANT="SUKISU" ;;
  "None") VARIANT="NKSU" ;;
esac
[[ $KSU_SUSFS == "true" ]] && VARIANT+="+SuSFS"

# Replace Placeholder in zip name
ZIP_NAME=${ZIP_NAME//KVER/$LINUX_VERSION}
ZIP_NAME=${ZIP_NAME//VARIANT/$VARIANT}

# Download Clang
CLANG_DIR="$workdir/clang"
if [[ -z "$CLANG_BRANCH" ]]; then
  log "🔽 Downloading Clang..."
  aria2c -q -c -x16 -s16 -k4M --file-allocation=falloc -o tarball "$CLANG_URL"
  mkdir -p "$CLANG_DIR"
  tar -xf tarball -C "$CLANG_DIR"
  rm tarball

  if [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]] \
    && [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 0 ]]; then
    SINGLE_DIR=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv $SINGLE_DIR/* $CLANG_DIR/
    rm -rf $SINGLE_DIR
  fi
else
  log "🔽 Cloning Clang..."
  git clone --depth=1 -q "$CLANG_URL" -b "$CLANG_BRANCH" "$CLANG_DIR"
fi

export PATH="$CLANG_DIR/bin:$PATH"

# Extract clang version
COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

# Clone GCC if not available
if ! ls $CLANG_DIR/bin | grep -q "aarch64-linux-gnu"; then
  log "🔽 Cloning GCC..."
  git clone --depth=1 -q https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-gnu-9.3 $workdir/gcc
  export PATH="$workdir/gcc/bin:$PATH"
  CROSS_COMPILE_PREFIX="aarch64-linux-"
else
  CROSS_COMPILE_PREFIX="aarch64-linux-gnu-"
fi

cd $KSRC

## KernelSU setup
if ksu_included; then
  # Remove existing KernelSU drivers
  for KSU_PATH in drivers/staging/kernelsu drivers/kernelsu KernelSU; do
    if [[ -d $KSU_PATH ]]; then
      log "KernelSU driver found in $KSU_PATH, Removing..."
      KSU_DIR=$(dirname "$KSU_PATH")

      [[ -f "$KSU_DIR/Kconfig" ]] && sed -i '/kernelsu/d' $KSU_DIR/Kconfig
      [[ -f "$KSU_DIR/Makefile" ]] && sed -i '/kernelsu/d' $KSU_DIR/Makefile

      rm -rf $KSU_PATH
    fi
  done

  # Install kernelsu
  case "$KSU" in
    "Next") install_ksu bintang774/KernelSU-Next $(if susfs_included; then echo "next-susfs"; else echo "next"; fi) ;;
    "Suki") install_ksu SukiSU-Ultra/SukiSU-Ultra $(if susfs_included; then echo "susfs-main"; elif ksu_manual_hook; then echo "nongki"; else echo "main"; fi) ;;
  esac
  config --enable CONFIG_KSU
fi

# SUSFS
if susfs_included; then
  # Kernel-side
  log "Applying kernel-side susfs patches"
  git clone --depth=1 -q https://gitlab.com/simonpunk/susfs4ksu \
    -b gki-android12-5.10 \
    $workdir/susfs
  SUSFS_PATCHES=$workdir/susfs/kernel_patches
  cp -R $SUSFS_PATCHES/fs/* ./fs
  cp -R $SUSFS_PATCHES/include/* ./include
  patch -p1 < $SUSFS_PATCHES/50_add_susfs_in_gki-android12-5.10.patch
  SUSFS_VERSION=$(grep -E '^#define SUSFS_VERSION' ./include/linux/susfs.h | cut -d' ' -f3 | sed 's/"//g')
  config --enable CONFIG_KSU_SUSFS
else
  config --disable CONFIG_KSU_SUSFS
fi

# KSU Manual Hooks
if ksu_manual_hook; then
  # Apply manual hook patch
  log "Applying manual hook patch"
  patch -p1 < $workdir/kernel-patches/manual-hook.patch
  config --enable CONFIG_KSU_MANUAL_HOOK
  config --disable CONFIG_KSU_KPROBES_HOOK
  config --disable CONFIG_KSU_SUSFS_SUS_SU # Conflicts with manual hook
fi

# Enable KPM Supports for SukiSU
if [[ $KSU == "Suki" ]]; then
  config --enable CONFIG_KPM
fi

# set localversion
if [[ $TODO == "kernel" ]]; then
  LATEST_COMMIT_HASH=$(git rev-parse --short HEAD)
  if [[ $STATUS == "BETA" ]]; then
    SUFFIX=$LATEST_COMMIT_HASH
  else
    SUFFIX="release@${LATEST_COMMIT_HASH}"
  fi
  config --set-str CONFIG_LOCALVERSION "-$KERNEL_NAME/$SUFFIX"
fi

# Declare needed variables
export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
export KBUILD_BUILD_TIMESTAMP=$(date)
BUILD_FLAGS="-j$(nproc --all) ARCH=arm64 LLVM=1 LLVM_IAS=1 O=out CROSS_COMPILE=$CROSS_COMPILE_PREFIX"
KERNEL_IMAGE="$KSRC/out/arch/arm64/boot/Image"
KMI_CHECK="$workdir/scripts/KMI_function_symbols_test.py"
MODULE_SYMVERS="$KSRC/out/Module.symvers"

text=$(
  cat << EOF
*==== Krenol CI ====*
🐧 *Linux Version*: $LINUX_VERSION
📅 *Build Date*: $KBUILD_BUILD_TIMESTAMP
📛 *KernelSU*: ${KSU}$(ksu_included && echo " | $KSU_VERSION")
ඞ *SuSFS*: $(susfs_included && echo "$SUSFS_VERSION" || echo "None")
🔰 *Compiler*: $COMPILER_STRING
EOF
)
MESSAGE_ID=$(send_msg "$text" 2>&1 | jq -r .result.message_id)

## Build GKI
log "Generating config..."
make $BUILD_FLAGS $KERNEL_DEFCONFIG

# Upload defconfig if we are doing defconfig
if [[ $TODO == "defconfig" ]]; then
  log "Uploading defconfig..."
  upload_file $KSRC/out/.config
  exit 0
fi

# Build the actual kernel
log "Building kernel..."
make $BUILD_FLAGS Image modules

# Check KMI Function symbol
$KMI_CHECK "$KSRC/android/abi_gki_aarch64.xml" "$MODULE_SYMVERS"

## Post-compiling stuff
cd $workdir

# Patch the kernel Image for KPM Supports
if [[ $KSU == "Suki" ]]; then
  tempdir=$(mktemp -d) && cd $tempdir

  # Setup patching tool
  LATEST_SUKISU_PATCH=$(curl -s "https://api.github.com/repos/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest" | grep "browser_download_url" | grep "patch_linux" | cut -d '"' -f 4)
  curl -Ls "$LATEST_SUKISU_PATCH" -o patch_linux
  chmod a+x ./patch_linux

  # Patch the kernel image
  cp $KERNEL_IMAGE ./Image
  sudo ./patch_linux
  mv oImage Image
  KERNEL_IMAGE=$(pwd)/Image

  cd -
fi

# Clone AnyKernel
log "Cloning anykernel from $(simplify_gh_url "$ANYKERNEL_REPO")"
git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel

# Set kernel string in anykernel
if [[ $STATUS == "BETA" ]]; then
  BUILD_DATE=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%Y%m%d-%H%M")
  ZIP_NAME=${ZIP_NAME//BUILD_DATE/$BUILD_DATE}
  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${LINUX_VERSION} (${BUILD_DATE}) ${VARIANT}/g" \
    $workdir/anykernel/anykernel.sh
else
  ZIP_NAME=${ZIP_NAME//-BUILD_DATE/}
  sed -i \
    "s/kernel.string=.*/kernel.string=${KERNEL_NAME} ${LINUX_VERSION} ${VARIANT}/g" \
    $workdir/anykernel/anykernel.sh
fi

# Zip the anykernel
cd anykernel
log "Zipping anykernel..."
cp $KERNEL_IMAGE .
zip -r9 $workdir/$ZIP_NAME ./*
cd -

if [[ $BUILD_BOOTIMG == "true" ]]; then
  AOSP_MIRROR=https://android.googlesource.com
  AOSP_BRANCH=main-kernel-build-2024
  log "Cloning build tools..."
  git clone -q --depth=1 $AOSP_MIRROR/kernel/prebuilts/build-tools -b $AOSP_BRANCH build-tools
  log "Cloning mkbootimg..."
  git clone -q --depth=1 $AOSP_MIRROR/platform/system/tools/mkbootimg -b $AOSP_BRANCH mkbootimg

  AVBTOOL="$workdir/build-tools/linux-x86/bin/avbtool"
  MKBOOTIMG="$workdir/mkbootimg/mkbootimg.py"
  UNPACK_BOOTIMG="$workdir/mkbootimg/unpack_bootimg.py"
  BOOT_SIGN_KEY_PATH="$workdir/key/key.pem"
  BOOTIMG_NAME="${ZIP_NAME%.zip}-boot-dummy1.img"

  generate_bootimg() {
    local kernel="$1"
    local output="$2"

    # Create boot image
    log "Creating $output"
    $MKBOOTIMG --header_version 4 \
      --kernel "$kernel" \
      --output "$output" \
      --ramdisk out/ramdisk \
      --os_version 12.0.0 \
      --os_patch_level "2099-12"

    sleep 0.5

    # Sign the boot image
    log "Signing $output"
    $AVBTOOL add_hash_footer \
      --partition_name boot \
      --partition_size $((64 * 1024 * 1024)) \
      --image "$output" \
      --algorithm SHA256_RSA2048 \
      --key $BOOT_SIGN_KEY_PATH
  }

  tempdir=$(mktemp -d) && cd $tempdir
  cp $KERNEL_IMAGE .
  gzip -n -f -9 -c Image > Image.gz
  lz4 -l -12 --favor-decSpeed Image Image.lz4

  log "Downloading ramdisk..."
  wget -qO gki.zip https://dl.google.com/android/gki/gki-certified-boot-android12-5.10-2023-01_r1.zip
  unzip -q gki.zip && rm gki.zip
  $UNPACK_BOOTIMG --boot_img=boot-5.10.img && rm boot-5.10.img

  for format in raw lz4 gz; do
    kernel="./Image"
    [[ $format != "raw" ]] && kernel+=".$format"

    _output="${BOOTIMG_NAME/dummy1/$format}"
    generate_bootimg "$kernel" "$_output"

    mv "$_output" $workdir
  done
  cd $workdir
fi

if [[ $STATUS != "BETA" ]]; then
  echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> $GITHUB_ENV
  mkdir -p $workdir/artifacts
  mv $workdir/*.zip $workdir/*.img $workdir/artifacts
fi

if [[ $LAST_BUILD == "true" && $STATUS != "BETA" ]]; then
  (
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "SUSFS_VERSION=$(curl -s https://gitlab.com/simonpunk/susfs4ksu/raw/gki-android12-5.10/kernel_patches/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g')"
    echo "KSU_NEXT_VERSION=$(gh api repos/KernelSU-Next/KernelSU-Next/tags --jq '.[0].name')"
    echo "SUKISU_VERSION=$(gh api repos/SukiSU-Ultra/SukiSU-Ultra/tags --jq '.[0].name')"
    echo "KERNEL_NAME=$KERNEL_NAME"
    echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")"
  ) >> $workdir/artifacts/info.txt
fi

if [[ $STATUS == "BETA" ]]; then
  reply_file "$MESSAGE_ID" "$workdir/$ZIP_NAME"
  reply_file "$MESSAGE_ID" "$workdir/build.log"
else
  reply_msg "$MESSAGE_ID" "✅ Build Succeeded"
fi

exit 0
