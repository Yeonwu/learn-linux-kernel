# swapper, init 프로세스

책에서는 swapper PID 0, init PID 1이라고 설명했지만 실제 확인된 프로세스 이름은 systemd, PID 0인 프로세스는 보이지 않았다.

```
S   UID   PID  PPID  C PRI  NI   RSS    SZ WCHAN  TTY          TIME CMD
S     0     1     0  3  80   0  8036  7856 -      ?        00:00:10 systemd
```

init 프로세스는 리눅스에서 유저 공간 프로세스의 부모 역할을 수행하며, 배포판마다 이름이 다르다고한다. 일반적으로는 init이지만, 라즈비안에서는 systemd라고 부른다.

swapper 프로세스는 왜 ps 명령어로 확인할 수 없을까? PPID를 확인해보면, systemd와 kthreadd의 부모 프로세스가 swapper, 즉 PID 0번 임을 확인할 수 있다.
```
S   UID   PID  PPID  C PRI  NI   RSS    SZ WCHAN  TTY          TIME CMD
S     0     1     0  3  80   0  8036  7856 -      ?        00:00:10 systemd
S     0     2     0  0  80   0     0     0 -      ?        00:00:00 kthreadd
```

swapper 프로세스는 일반 프로세스가 아닌 커널이 정적으로 갖고 시작하는 최초의 프로세스이기 때문이다. 정상적인 PID allocator, /proc에 등록되지 않기 때문에 ps로 확인이 불가능하다.

# `kernel_clone()`

리눅스는 속도 최적화를 위해 매번 새롭게 프로세스를 만드는 대신, 부모 프로세스의 자료구조를 복사하여 사용한다. 이 때 사용하는 함수가 kernel_clone 함수이다.

선언부는 다음과 같다. `pid_t` 타입을 리턴하며, `struct kernel_clone_args`를 인자로 받는다.

```c
pid_t kernel_clone(struct kernel_clone_args *args)
```

`pid_t` 타입은 선언을 타고 계속 들어가다보면 `int`형이고, 인자 타입은 다음과 같다.

중요한 것 몇 가지만 살펴보면,

flags: linux/include/uapi/linux/sched.h에 정의된 매크로를 사용해 bit wise flag로 사용한다.
stack: 초기 user stack pointer
stack_size: user stack 크기

```c
struct kernel_clone_args {
	u64 flags;
	int __user *pidfd;
	int __user *child_tid;
	int __user *parent_tid;
	const char *name;
	int exit_signal;
	u32 kthread:1;
	u32 io_thread:1;
	u32 user_worker:1;
	u32 no_files:1;
	unsigned long stack;
	unsigned long stack_size;
	unsigned long tls;
	pid_t *set_tid;
	/* Number of elements in *set_tid */
	size_t set_tid_size;
	int cgroup;
	int idle;
	int (*fn)(void *);
	void *fn_arg;
	struct cgroup *cgrp;
	struct css_set *cset;
	unsigned int kill_seq;
};
```

## 왜 `ptd_t` 선언을 저렇게 복잡하게 했을까?

내부 타입과 외부 공개 타입을 구분하기 위해서이다. 우리가 c 프로그램을 짤 때는 고려하지 않지만, 라이브러리는 외부에 어떤 걸 어떻게 노출할지를 생각해야한다.

아래와 같이 2단계를 거쳐 선언한다.

사용자 프로그램이 libc 헤더와 Linux UAPI 헤더를 동시에 포함할 경우 충돌을 막기 위해서다. 양쪽 모두 `pid_t` 타입을 내부적으로 사용한다.
만약 둘 다 이 타입을 외부에 노출한다면, 동시에 include할 때 문제가 생긴다.

```c
// linux/include/linux/types.h
typedef __kernel_pid_t		pid_t;

// linux/include/uapi/asm-generic/posix_types.h
typedef int		__kernel_pid_t;
```

따라서 외부에 노출되는 부분에는 다음과 같이 겹치지 않게 정의하여 사용한다: `__kernel_pid_t`는 커널에서 정의된 pid 타입, `__pid_t`는 glibc에서 정의된 pid 타입이다.
이후 외부 코드와 함께 컴파일 되지 않는 내부 코드에서는 읽기 편하게 다시 `pid_t`로 정의하여 사용한다.

그럼 glibc는 왜 내부 pid 타입과 외부 pid 타입을 따로 두었을까? 내부적으로는 항상 pid 타입에 접근해서 사용하면서, `pid_t`는 사용자가 정해진 헤더를 include했을 경우에만 공개되도록 하기 위해서이다.
내부 타입이 존재하기 않는다면, 내부 파일에서 `pid_t`를 사용하는 순간 사용자가 정해진 헤더가 아닌 해당 파일을 include해도 `pid_t`에 접근하게 된다.

```c
/* glibc 내부 어떤 다른 헤더 */
typedef int pid_t;

struct internal_info {
    pid_t owner;
};

/* 사용자 프로그램 */
#include <어떤_다른_헤더.h>

pid_t pid;  /* 우연히 컴파일됨 */
```

## user process 생성 시 흐름

1. 유저 공간에서 `fork()` 호출 > 시스템 콜 발생
2. 커널 공간에서 `sys_clone()` 호출
3. `sys_clone()`이 `kernel_clone()` 호출

즉, 커널은 유저 프로세스 생성, 유저 스레드 생성 둘 다 `kernel_clone()`을 사용해 처리한다.

pid 206인 bash에서 pid 608인 프로세스를 복사했으며, 이후 로그를 보면 raspbian_proc pid가 608임을 확인할 수 있다.

```log
...
            bash-206     [003] ..... 20003.681933: copy_process+0xc/0x16a8 <-kernel_clone+0xac/0x388
            bash-206     [003] ..... 20003.681938: <stack trace>
 => copy_process+0x10/0x16a8
 => kernel_clone+0xac/0x388
 => sys_clone+0x78/0x9c
 => ret_fast_syscall+0x0/0x54
            bash-206     [003] ..... 20003.683043: sched_process_fork: comm=bash pid=206 child_comm=bash child_pid=608
...
raspbian_proc-608     [001] dns.. 20003.691808: sched_wakeup: comm=kworker/1:0 pid=592 prio=120 target_cpu=001
```

## user process 종료 시 흐름

두 가지 방법이 있다. 외부에서 종료 시그널을 받아 종료, 스스로 exit()을 호출하여 종료.

외부 시그널 종료 시:
```log
...
   raspbian_proc-608     [003] d.... 20038.872959: signal_deliver: sig=9 errno=0 code=0 sa_handler=0 sa_flags=0
   raspbian_proc-608     [003] ..... 20038.873096: do_exit+0xc/0xa24 <-do_group_exit+0x40/0x8c
   raspbian_proc-608     [003] ..... 20038.873124: <stack trace>
 => do_exit+0x10/0xa24
 => do_group_exit+0x40/0x8c
 => get_signal+0x92c/0x978
 => do_work_pending+0x22c/0x4dc
 => slow_work_pending+0xc/0x24
   raspbian_proc-608     [003] ..... 20038.873171: sched_process_exit: comm=raspbian_proc pid=608 prio=120 group_dead=true
   raspbian_proc-608     [003] dn... 20038.873821: signal_generate: sig=17 errno=0 code=2 comm=bash pid=206 grp=1 res=0
   raspbian_proc-608     [003] d.... 20038.873886: sched_switch: prev_comm=raspbian_proc prev_pid=608 prev_prio=120 prev_state=Z ==> next_comm=swapper/3 next_pid=0 next_prio=120
 ```

sig=9 (종료 시그널)을 받은 다음 do_exit으로 종료된다. 이후 부모 프로세스에세 종료를 알리는 sig=17을 생성한다.

스스로 exit() 호출하여 종료 시:
``` log
   rpi_proc_exit-398     [003] .....  2118.418095: do_exit+0xc/0xa24 <-do_group_exit+0x40/0x8c
   rpi_proc_exit-398     [003] .....  2118.418134: <stack trace>
 => do_exit+0x10/0xa24
 => do_group_exit+0x40/0x8c
 => pid_child_should_wake+0x0/0x68
   rpi_proc_exit-398     [003] .....  2118.418304: sched_process_exit: comm=rpi_proc_exit pid=398 prio=120 group_dead=true
   rpi_proc_exit-398     [003] dn...  2118.418998: signal_generate: sig=17 errno=0 code=1 comm=bash pid=265 grp=1 res=0
```
직접 종료 후 sig=17을 생성한다.

## `pid_child_should_wake+0x0/0x68`의 해석, 콜스택 주소 읽는 방법
콜스택 함수 포맷 설명: 함수명+오프셋/함수크기
예시) do_exit+0x10/0xa24는, 전체 크기가 0xa24바이트인 do_exit() 함수에서, 시작 주소로부터 0x10바이트 떨어진 위치라는 뜻.

어셈블리 명령어 `bl`로 함수 실행 시, 스택에 return address는 호출 주소가 아닌 호출 후 복귀할 주소를 기록한다. 이는 당연한데, 호출 주소로 복귀하게 된다면 무한 루프에 빠지기 때문이다.

32bit 아키텍처에서, 명령어 크기는 4byte이므로, 스택에는 호출 지점 +0x4 주소가 저장된다. 

ftrace가 콜스택을 생성할 때는 스택에 저장된 값을 기준으로 함수명, 오프셋, 함수크기를 보여주게 되는데, 따라서 함수 오프셋이 0x0일 경우 해당 함수가 아닌, 해당 함수 시작 주소 전이 호출되었다고 보아야한다.

일괄적으로 -0x4하여 보여주지 않는 이유는 스택에 저장된 주소가 항상 return address는 아니기 때문이다. 다양한 출처가 있으며, 심지어 Thumb 모드에서는 명령어 크기가 2byte이기 때문에 -0x2하여 보아야 한다.

따라서 함수 오프셋이 0x0일 경우, 해당 함수가 실행된 것이 아닐 가능성이 크다. 

objdump를 사용해 확인해보면, pid_child_should_wake 전, __se_sys_exit_group에서 `bl`을 통해 do_group_exit이 호출되었음을 확인할 수 있다.

```
❯ objdump -d --start-address=0x8012d510 --stop-address=0x8012d524 out/vmlinux

out/vmlinux:     file format elf32-littlearm


Disassembly of section .text:

8012d510 <__se_sys_exit_group+0x8>:
8012d510:       ebffb36e        bl      8011a2d0 <__gnu_mcount_nc>
8012d514:       e1a00400        lsl     r0, r0, #8
8012d518:       e2000cff        and     r0, r0, #65280  @ 0xff00
8012d51c:       ebffffd6        bl      8012d47c <do_group_exit>

8012d520 <pid_child_should_wake>:
8012d520:       e52de004        push    {lr}            @ (str lr, [sp, #-4]!)
```
