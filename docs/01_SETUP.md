# Linux Kernel 공부 환경 세팅

Raspberry Pi 2용 Linux Kernel을 직접 빌드하고, QEMU에서 부팅한 뒤, 커널 내부의 인터럽트 처리 흐름을 ftrace로 확인하기 위한 환경을 만들었다.

현재 환경은 다음과 같이 구성되어 있다.

Host PC: Ubuntu 24.04
Target: Raspberry Pi 2 (`bcm2709`) |
Architecture: ARM 32-bit (`arm`) |
Cross compiler: `arm-linux-gnueabihf-` |
Kernel output: `out/` |
Root filesystem: BusyBox 기반 initramfs |
Emulator: QEMU `raspi2b` |
Trace: ftrace function tracer + IRQ/scheduler events

## 디렉터리 구조

```text
.
├── linux/                  # Linux Kernel source
├── busybox/                # BusyBox source와 빌드 결과
├── rootfs/                 # initramfs에 들어갈 파일
│   ├── init                # init 프로세스
│   └── trace.sh            # ftrace 수집 스크립트
├── out/                    # Kernel 빌드 결과
├── build/                  # initramfs 이미지
├── bin/                    # ARM 빌드 도구 경로
├── .envrc                  # 빌드 환경 변수
├── build_rpi_kernel.sh     # Kernel 빌드
├── build_initramfs.sh      # initramfs 생성
└── run_pi                  # QEMU 실행
```

`linux/`, `busybox/`, `rootfs/`, `out/`은 gitignore 처리했다.

## 1. ARM 빌드 환경 설정

`.envrc`에서 로컬 ARM 도구 경로와 커널 빌드 변수를 설정한다. 호스트 PC는 x86 cpu를 사용하며, 빌드한 커널을 ARM 32 QEMU에서 돌릴 계획이기 때문에 바이너리 유틸리티 앞에 `arm-linux-gnueabihf-` 접두어를 붙여야하나, 매번 사용하기 귀찮기 때문에 `bin`폴더 아래 실행파일들을 만들어 놓고 PATH에 추가한다.

```bash
#!/bin/bash

PATH_add "$PWD/bin"

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
```

direnv를 사용해 저장소 루트에서 환경을 허용했다.

```bash
direnv allow
```

도구 버전은 다음과 같다.

```text
arm-linux-gnueabihf-gcc 13.3.0
qemu-system-arm         8.2.2
```

책에서는 라즈비안 4.19 버전을 사용했으나, 빌드 도구 버전을 맞추기 어려워 [6.18 버전](https://github.com/raspberrypi/linux/tree/rpi-6.18.y)을 사용했다. clone 후 `build_rpi_kernel.sh` 스크립트를 실행해 커널을 빌드할 수 있다.

## 2. BusyBox로 initramfs 만들기

Kernel만 부팅하면 사용할 사용자 공간이 없기 때문에 BusyBox를 넣은 작은 root filesystem을 준비한다.
`rootfs/init`은 가장 먼저 필요한 가상 파일 시스템을 마운트하고 shell을 실행한다.

```sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

exec /bin/sh
```

initramfs 이미지는 다음 명령으로 만든다.

```bash
./build_initramfs.sh
```

스크립트는 `rootfs/` 전체를 `newc` 형식의 cpio archive로 묶은 뒤 gzip으로 압축하여 `build/initramfs.cpio.gz`를 생성한다.

## 3. Raspberry Pi 2용 Kernel 빌드

빌드 출력은 소스 디렉터리와 분리해서 `out/`에 저장한다. 먼저 Raspberry Pi 2에 맞는 기본 설정을 적용한다.

```bash
cd linux
make O=../out \
  ARCH=arm \
  CROSS_COMPILE=arm-linux-gnueabihf- \
  bcm2709_defconfig
```

이후 Kernel image, modules, device tree를 함께 빌드한다.

```bash
make -j"$(nproc)" O=../out \
  ARCH=arm \
  CROSS_COMPILE=arm-linux-gnueabihf- \
  zImage modules dtbs
```

반복해서 실행할 때는 저장소 루트의 스크립트를 사용한다.

```bash
./build_rpi_kernel.sh
```

특정 파일만 다시 전처리하거나 빌드해야 하는 경우에는 인자로 make target을
넘길 수 있다.

```bash
./build_rpi_kernel.sh path/to/file.i
```

빌드 로그는 `rpi_build_log.txt`에 저장한다. 현재 로그에서 다음 결과를
확인했다.

```text
Kernel: arch/arm/boot/Image is ready
Kernel: arch/arm/boot/zImage is ready
```

## 4. QEMU에서 Kernel 부팅하기

빌드된 Kernel, Raspberry Pi 2 device tree, initramfs를 QEMU에 넘긴다.

```bash
./run_pi
```

실제로 실행되는 명령은 다음과 같다.

```bash
qemu-system-arm \
  -M raspi2b \
  -kernel out/arch/arm/boot/zImage \
  -dtb out/arch/arm/boot/dts/broadcom/bcm2709-rpi-2-b.dtb \
  -initrd build/initramfs.cpio.gz \
  -append "console=ttyAMA0 rdinit=/init" \
  -nographic
```

`-nographic`를 사용했기 때문에 QEMU의 serial console이 현재 터미널에 그대로 출력된다. 정상적으로 부팅되면 다음과 같은 initramfs shell이 나온다.

```text
================================
 BusyBox initramfs booted
================================
```

## 5. 인터럽트 정보 출력 지점에 trace_printk 추가

`linux/kernel/irq/proc.c`의 `/proc/interrupts` 출력 경로에
`rpi_get_interrupt_info()`를 추가했다.

```c
noinline void rpi_get_interrupt_info(struct irqaction *action_p) {
    unsigned int irq_num = action_p->irq;
    void *irq_handler = NULL;

    if (action_p->handler)
        irq_handler = (void *)action_p->handler;

    if (irq_handler)
        trace_printk("[%s] %d: %s, irq_handler: %pS\n",
                     current->comm, irq_num, action_p->name, irq_handler);
}
```

`show_interrupts()`에서 IRQ action이 존재할 때 이 함수를 호출한다. 따라서 `/proc/interrupts`를 읽는 순간 현재 프로세스, IRQ 번호, 장치 이름, IRQ handler symbol이 ftrace buffer에 기록된다.

## 6. ftrace로 실행 흐름 확인하기

부팅한 QEMU 안에서 다음을 실행한다.

```bash
./trace.sh
```

initramfs는 `rootfs/`의 내용을 루트(`/`)로 풀기 때문에, QEMU 안에서는 스크립트 경로는 `/trace.sh`이다.

QEMU에서 제공하는 호스트-게스트 공유 폴더는 실시간 공유가 아니기 때문에, 공유 폴더를 만드는 대신 `gzip`으로 압축한 후 `base64`로 인코딩하여 터미널에 출력, 출력 결과를 호스트에서 다시 디코팅/압축해제하였다.

```bash
# 게스트
cat ftrace_log.c | gzip | base64

# 호스트
base64 -d ftrace_log.b64 | gzip -d > trace.txt
```


현재 수집 결과에서는 `cat` 프로세스가 `/proc/interrupts`를 읽는 과정에서 `show_interrupts()`와 `rpi_get_interrupt_info()`를 호출한 stack trace를 확인했다. 또한 mailbox, framebuffer DMA, DMA 등의 IRQ handler 정보가 기록되었다.


## 참고 자료

- [Linux Kernel](https://www.kernel.org/)
- [Raspberry Pi Linux Kernel](https://github.com/raspberrypi/linux/tree/rpi-6.18.y)
- [Raspberry Pi Kernel building guide](https://www.raspberrypi.org/documentation/linux/kernel/building.md)
