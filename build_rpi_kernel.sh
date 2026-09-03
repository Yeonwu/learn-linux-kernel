#!/bin/bash

set -euo pipefail

echo "configure build output path"

KERNEL_TOP_PATH="$( cd "$(dirname "$0")" ; pwd -P )"
OUTPUT="$KERNEL_TOP_PATH/out"
echo "$OUTPUT"

KERNEL=kernel7
BUILD_LOG="$KERNEL_TOP_PATH/rpi_build_log.txt"

PREPROCESS_FILE="${1:-}"

if [[ -n "$PREPROCESS_FILE" ]]; then
	echo "build preprocessed file: $PREPROCESS_FILE"
fi

echo "move kernel source"
cd linux

echo "make defconfig"
make O=$OUTPUT \
	ARCH=$ARCH \
	CROSS_COMPILE=$CROSS_COMPILE \
	bcm2709_defconfig

echo "kernel build"
if [[ -z "$PREPROCESS_FILE" ]]; then
	make -j"$(nproc)" O="$OUTPUT" \
		ARCH=$ARCH \
		CROSS_COMPILE=$CROSS_COMPILE \
		zImage modules dtbs 2>&1 | tee "$BUILD_LOG"
else
	make "$PREPROCESS_FILE" -j"$(nproc)" O="$OUTPUT" \
		ARCH=$ARCH \
		CROSS_COMPILE=$CROSS_COMPILE \
		zImage modules dtbs 2>&1 | tee "$BUILD_LOG"
fi