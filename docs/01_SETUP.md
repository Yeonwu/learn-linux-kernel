# Linux Kernel 공부 환경 세팅

Raspberry Pi 2용 Linux Kernel을 직접 빌드하고, QEMU에서 Debian 사용자 공간과 함께 부팅한 뒤, 커널 내부의 인터럽트 처리 흐름을 ftrace로 확인하기 위한 환경을 만들었다.

처음에는 BusyBox 기반의 작은 initramfs를 사용했다. 그러나 이후 실습에서는 `systemd`, `ps`, `ssh`, 컴파일러와 각종 디버깅 도구 등 다양한 사용자 프로그램이 필요했다. 필요한 기능을 매번 BusyBox에 추가하는 대신 패키지 관리자를 사용할 수 있도록 사용자 공간을 Debian으로 변경했다. 커널은 이 저장소에서 직접 빌드한 것을 사용하고, 사용자 공간만 Debian root filesystem을 사용한다.

현재 환경은 다음과 같이 구성되어 있다.

Host PC: Ubuntu 24.04
Target: Raspberry Pi 2 (`bcm2709`) |
Architecture: ARM 32-bit (`arm`) |
Cross compiler: `arm-linux-gnueabihf-` |
Kernel output: `out/` |
Root filesystem: Debian ARMHF (`build/rootfs.ext4`) |
Emulator: QEMU `raspi2b` |
Trace: ftrace function tracer + IRQ/scheduler events

## 디렉터리 구조

```text
.
├── linux/                  # Linux Kernel source
├── out/                    # Kernel 빌드 결과
├── build/
│   └── rootfs.ext4         # Debian ARMHF root filesystem 이미지
├── bin/                    # ARM 빌드 도구 경로
├── qemu-share/             # 게스트에서 사용할 실습 스크립트와 로그
├── scripts/
│   ├── boot                # QEMU 실행
│   └── update_kernel       # Kernel 빌드와 module 설치
├── .envrc                  # 빌드 환경 변수
└── docs/                   # 실습 문서
```

`linux/`, `out/`, `build/`, `qemu-share/` 등 소스와 빌드 결과 및 실습 로그는 gitignore 처리했다.

## 1. ARM 빌드 환경 설정

`.envrc`에서 로컬 ARM 도구 경로와 커널 빌드 변수를 설정한다. 호스트 PC는 x86 cpu를 사용하며, 빌드한 커널을 ARM 32 QEMU에서 돌릴 계획이기 때문에 바이너리 유틸리티 앞에 `arm-linux-gnueabihf-` 접두어를 붙여야하나, 매번 사용하기 귀찮기 때문에 `bin`폴더 아래 실행파일들을 만들어 놓고 PATH에 추가한다.

```bash
#!/bin/bash

PATH_add "$PWD/bin"
PATH_add "$PWD/scripts"

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

책에서는 라즈비안 4.19 버전을 사용했으나, 빌드 도구 버전을 맞추기 어려워 [6.18 버전](https://github.com/raspberrypi/linux/tree/rpi-6.18.y)을 사용했다. clone 후 `update_kernel` 스크립트를 실행해 커널을 빌드할 수 있다.

## 2. Debian 사용자 공간 준비하기

Kernel만으로는 셸이나 일반 명령을 실행할 수 없으므로 별도의 사용자 공간이 필요하다. RMHF용 Debian root filesystem을 ext4 이미지로 준비하여 다음 경로에 둔다.

```text
build/rootfs.ext4
```

QEMU는 이 이미지를 SD 장치로 연결하고, 직접 빌드한 Kernel은 `/dev/mmcblk0`을 root filesystem으로 마운트한다. Debian의 init system이 PID 1로 시작되며, 가상 파일 시스템 마운트와 서비스 시작도 Debian 환경에서 처리한다.

따라서 실습에 필요한 사용자 프로그램은 게스트 Debian 안에서 `apt`로 설치할 수 있다.

```bash
sudo apt update
sudo apt install <필요한-패키지>
```

이미지 안의 Kernel module은 빌드한 Kernel 버전과 일치해야 한다. 저장소 루트에서 `update_kernel`을 실행하면 `rootfs.ext4`를 임시 마운트하고, Kernel을 빌드한 뒤 `modules_install`로 module을 이미지의 `/lib/modules/` 아래에 설치한다.

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

반복해서 실행할 때는 저장소 루트에서 `update_kernel`을 사용한다.

```bash
update_kernel
```

빌드 로그는 `rpi_build_log.txt`에 저장한다.

## 4. QEMU에서 Kernel 부팅하기

빌드된 Kernel과 Raspberry Pi 2 device tree를 사용하고, Debian ext4 이미지를 SD 장치로 연결하여 QEMU를 실행한다.

```bash
boot
```

실제로 실행되는 명령은 다음과 같다.

```bash
qemu-system-arm \
  -M raspi2b \
  -kernel out/arch/arm/boot/zImage \
  -dtb out/arch/arm/boot/dts/broadcom/bcm2709-rpi-2-b.dtb \
  -drive "file=build/rootfs.ext4,format=raw,if=sd" \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device usb-net,netdev=net0 \
  -append "console=ttyAMA0 root=/dev/mmcblk0 rootfstype=ext4 rw rootwait dwc_otg.lpm_enable=0 dwc_otg.fiq_fsm_enable=0" \
  -nographic
```

각 옵션의 역할은 다음과 같다.

- `-drive ...if=sd`: `rootfs.ext4`를 Raspberry Pi의 SD 장치로 연결한다.
- `root=/dev/mmcblk0`: 연결한 ext4 이미지를 root filesystem으로 사용한다.
- `-nographic`: serial console을 현재 터미널에 연결한다. 부팅 후 Debian 로그인 프롬프트에서 실습한다.
- `hostfwd=...2222-:22`: 게스트에서 SSH 서버를 실행하고 있다면 호스트의 `127.0.0.1:2222`를 게스트의 22번 포트로 전달한다.

QEMU 종료는 serial console에서 `Ctrl-a x`를 입력한다.

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

부팅한 QEMU의 Debian 환경에서 root 권한으로 tracefs를 마운트하고 ftrace 설정을 적용한다. 저장소의 `qemu-share/trace.sh`가 이 과정을 자동화한다.

```bash
mount -t tracefs nodev /sys/kernel/tracing
./trace.sh
```

`qemu-share/`는 QEMU에 자동으로 공유되는 디렉터리가 아니다. 스크립트를 사용하려면 serial console에 내용을 붙여 넣거나, 게스트의 SSH 서버와 네트워크가 준비된 경우 호스트의 2222번 포트를 통해 복사한다.

```bash
scp -P 2222 qemu-share/trace.sh <user>@127.0.0.1:~/
scp -P 2222 <user>@127.0.0.1:~/trace.log qemu-share/trace.log
```


현재 수집 결과에서는 `cat` 프로세스가 `/proc/interrupts`를 읽는 과정에서 `show_interrupts()`와 `rpi_get_interrupt_info()`를 호출한 stack trace를 확인했다. 또한 mailbox, framebuffer DMA, DMA 등의 IRQ handler 정보가 기록되었다.


## 참고 자료

- [Linux Kernel](https://www.kernel.org/)
- [Raspberry Pi Linux Kernel](https://github.com/raspberrypi/linux/tree/rpi-6.18.y)
- [Raspberry Pi Kernel building guide](https://www.raspberrypi.org/documentation/linux/kernel/building.md)
