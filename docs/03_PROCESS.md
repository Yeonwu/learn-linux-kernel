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

# kthread_create

## 커널 스레드 생성 과정

kthread_create_list를 조작할 때는 락을 걸고 진행한다.

1. kthread_create_on_node가 kthread_create_list에 커널 스레드 생성 요청을 추가한 다음, kthreadd를 깨운다.
2. 깨어난 kthreadd가 kthread_create_list에서 각 요청에 대해 create_kthread를 호출한다.
3. create_kthread가 kernel_thread를 호출해 커널 스레드를 생성한다.
4. kernel_thread는 kernel_clone을 호출해 프로세스를 생성한다.
5. kernel_clone은 copy_process를 통해 부모 프로세스 리소스를 복사한다.
6. 이후 wake_up_new_task를 통해 생성한 프로세스를 깨운다(run queue에 추가한다).

## 왜 커널 "프로세스"가 아니라 커널 "스레드"라고 부를까?

프로세스의 정의를 생각해보면 이유를 알 수 있다. 프로세스 > 독립된 메모리 주소 공간 + 실행 컨텍스트.
커널 스레드는 독립된 메모리 공간을 갖지 않고, 커널 공간의 메모리를 다 같이 공유하며 실행된다.



## likely, unlikey

```c
void __noreturn do_exit(long code)
{
	...
		kthread = tsk_is_kthread(tsk);
	if (unlikely(kthread))
		kthread_do_exit(kthread, code);
}
```

```c
# define likely(x)	__builtin_expect(!!(x), 1)
# define unlikely(x)	__builtin_expect(!!(x), 0)
```

자주 등장하는 매크로이므로 의미를 알아두면 좋을 것 같다. 뜻은 단어 그대로, 해당 조건이 True/False일 확률이 매우 높다는 뜻이다.
__builtin_expect(expr, expected_value)는 GCC 내장 함수로, "이 조건식의 결과는 보통 expected_value일 것" 이라고 컴파일러에게 알려준다.
컴파일러는 그에 맞게 기본 경로를 최적화한다.

```
# include <stdio.h>

# define likely(x)      __builtin_expect(!!(x), 1)
# define unlikely(x)    __builtin_expect(!!(x), 0)

void aaa() {
    printf("aaaa\n");
}

void bbb() {
    printf("bbbb\n");
}

int main() {
    int i;
    scanf("%d", &i);
    if (unlikely(i))
        aaa();
    else
        bbb();
    return 0;
}
```

```
pi@rpi-qemu:~$ gcc -O2 -S -o expect.s ./expect.c
pi@rpi-qemu:~$ cat expect.s

...
.LC0:
	.ascii	"aaaa\000"
...
.LC1:
	.ascii	"bbbb\000"
...
main:
...
	bl	__isoc99_scanf(PLT)
	ldr	r3, [sp, #4]
	cbnz	r3, .L12  // Compare and Branch if Non-Zero, 즉 i가 0이 아니라면 브랜치.
	ldr	r0, .L13+4
...
.L12:
	ldr	r0, .L13+8
...
.L13:
	.word	.LC2-(.LPIC2+4)
	.word	.LC1-(.LPIC4+4)
	.word	.LC0-(.LPIC3+4)
```

unlikely 대신 likely 사용했을 경우 / 아예 사용하지 않았을 경우

```
main:
...
	bl	__isoc99_scanf(PLT)
	ldr	r3, [sp, #4]
	cbz	r3, .L9 // Compare and Branch if Zero, 즉 i가 1이라면 브랜치.
...
```

## ERR_PTR

리턴하는 값이 pointer 형식일 때, 에러를 뜻하는 음수 값을 포인터 형식으로 감싸서 리턴한다.
함수 호출자는 IS_ERR 매크로를 사용해서 에러 여부를 확인해야 한다.

```c

struct task_struct *some_function()
	...
	if (!create) 
		return ERR_PTR(-ENOMEM);
...

struct task_struct *foo = some_function();
if (IS_ERR(foo))
	// handle error
```

## kthread_create > kthread_create_on_node

왜 kthread_create을 #define으로 한번 감싸면서 kthread_create_on_node의 node 인자를 NUMA_NO_NODE로 고정했을까?

```c
// linux/include/linux/kthread.h:45-46
#define kthread_create(threadfn, data, namefmt, arg...) \
	kthread_create_on_node(threadfn, data, NUMA_NO_NODE, namefmt, ##arg)
```

NUMA는 Non-Uniform Memory Access의 약자로, NUMA node는 cpu와 메모리로 구성된다. 이 때, 같은 node 안의 메모리에 접근이 빠르고, 다른 node 메모리 접근은 느리다.
사용자가 해당 커널 스레드가 특정 node에서만 실행되는 것을 알고 있다면, 해당 node에 할당해 최적화가 가능하다. 대부분의 경우 그렇지 않으므로 기본 인자로 NO_NODE를 준 것이다.

# process 종료 과정

## do_exit

### 중복 종료 호출 확인 - 확인 책임이 do_exit()에서 각 호출 경로별로 분산됨.
수행하는 이유 - do_exit의 작업은 대부분 free 작업, 해당 작업을 중복 수행하게 되면 문제가 생김.

스레드가 종료되는 경로는 크게 4가지.

1. 스스로 exit 호출
2. 스레드 그룹에 대해 exit_group 호출
3. 시그널(SIGKILL 등)
4. oops/fault 등 커널 버그

하나하나 따져보자.

1. 스스로 exit() 호출: 중복 호출이 구조적으로 불가능함. do_exit은 리턴하지 않으므로, 스레드 실행 흐름으로 돌아와서 중복 호출할 수 없음.
2. 스레드 그룹에서 do_group_exit 호출: 케이스를 나눠서 생각해보면 됌. 같은 그룹에 속한 스레드 1, 2가 있다고 가정.

- 스레드 1과 2에서 동시에 do_exit_group 호출:
같은 그룹 내 다른 스레드를 전부 종료하는 함수: zap_other_threads()는 SIGNAL_GROUP_EXIT가 활성화 되어 있지 않은 최초 1회에만 호출됨.
```c
// linux/kernel/exit.c:1106
void __noreturn
do_group_exit(int exit_code)
{
	...
	spin_lock_irq(&sighand->siglock);
	if (sig->flags & SIGNAL_GROUP_EXIT)
		/* Another thread got here before we took the lock.  */
		exit_code = sig->group_exit_code;
	else if (sig->group_exec_task)
		exit_code = 0;
	else {
		sig->group_exit_code = exit_code;
		sig->flags = SIGNAL_GROUP_EXIT;
		zap_other_threads(current);
	}
	spin_unlock_irq(&sighand->siglock);
	...
}
```

- 스레드 1에서 do_exit 호출, 종료 전 스레드 2에서 do_exit_group 호출.
zap_other_threads는 exit_state인 스레드는 종료하지 않음.
``` c
// linux/kernel/signal.c:1337-1357
int zap_other_threads(struct task_struct *p)
{
...
	for_other_threads(p, t) {
		task_clear_jobctl_pending(t, JOBCTL_PENDING_MASK);
		count++;

		/* Don't bother with already dead threads */
		if (t->exit_state)
			continue;
		sigaddset(&t->pending.signal, SIGKILL);
		signal_wake_up(t, 1);
	}
...
}
```
t->exit_state은 do_exit에서 exit_notify 호출 시 값이 들어감.

3. 시그널
PF_EXITING 플래그가 켜져있으면 시그널을 보내지 않음. 애초에 do_exit은 no return이므로 스레드가 시그널을 받는 것도 불가능함.
```c
// linux/kernel/signal.c:286-287
if (unlikely(fatal_signal_pending(task) || (task->flags & PF_EXITING)))
	return false;
```

4. oops/fault
oops 발생 시 커널은 make_task_dead 함수를 통해 스레드를 종료함.
해당 함수에서는 다음과 같이 처리하여 do_exit이 중복 호출되지 않게 처리함.

```c
// linux/kernel/exit.c:1073-1082
if (unlikely(tsk->flags & PF_EXITING)) {
	pr_alert("Fixing recursive fault but reboot is needed!\n");
	futex_exit_recursive(tsk);
	tsk->exit_state = EXIT_DEAD;
	refcount_inc(&tsk->rcu_users);
	preempt_disable();
	do_task_dead();
}

do_exit(signr);
```

# task_struct

## container_of

왜 사용하나? 설계상, 만약 구조체 전체 정보가 필요하다면 그걸 받아야하고, 특정 필드만 필요하면 해당 필드를 넘기는게 맞지 않을까?

```c

struct list_head {
	struct list_head *next, *prev;
};

struct task_struct {
	...
	struct list_head		tasks;
	...
}
```

커널에서 특정 구조체를 손쉽게 리스트로 만들 수 있기 때문이다. 위와 같이 list_head 필드를 넣어두고, 연결해 놓으면, 나중에 container_of로 가져다 사용할 수 있다.
이러한 구현의 장점은 리스트 관련 코드의 추상화, 재사용이다. 다음과 같은 순회 상황을 생각해보자.

```c
struct list_head *pos;
list_for_each(pos, &task_list) {
   ...
}
```
만약 list_head를 사용하지 않고, task_struct 자체에 struct task_struct *prev, *next를 필드로 두었다면 list_for_each를 재사용 할 수 없었을 것이다.
리스트 관련 코드는 리스트 로직만 관리하고, 해당 주소에 어떤 타입이 오는지는 상관하지 않는다.

## thread_info

하드웨어 의존적인 아키텍처 별 추가 정보들을 저장한다. (선점 조건, 시그널, 레지스터 저장/로딩, 인터럽트 컨텍스트 여부)

### thread_info에서 task_struct를 어떻게 참조하나?

참조할 필요가 없다. 타입만 바꿔주면 된다.

```c
// linux/include/linux/sched.h:815-822
struct task_struct {
#ifdef CONFIG_THREAD_INFO_IN_TASK
	/*
	 * For reasons of header soup (see current_thread_info()), this
	 * must be the first element of task_struct.
	 */
	struct thread_info		thread_info;
#endif
...
}
```

위와 같이 thread_info는 task_struct의 첫번째 element로 들어가 있기 때문에,
```c
// linux/arch/arm/include/asm/thread_info.h:84-87
static inline struct task_struct *thread_task(struct thread_info* ti)
{
	return (struct task_struct *)ti;
}
```
포인터로 타입만 바꿔주면 된다.

### `CONFIG_THREAD_INFO_IN_TASK`

이전 커널에서는 프로세스 스택 최상단에 thread_info를 저장하고, thread_info에 task_struct 주소를 저장했다.
이런 설계에는 장점(stack 시작 주소 = current)도 있었지만, 단점(stack overflow에 취약)도 있었기 때문에, 현재는 구조를 변경하였다.

지금 구현에서는 어디에 저장되어 있을까?

### 커널 메모리 레이아웃

커널을 메모리를 다음과 같이 관리한다:

```
// linux/Documentation/arch/arm/memory.rst
=============== =============== ===============================================
Start		End		Use
=============== =============== ===============================================
ffff8000	ffffffff	copy_user_page / clear_user_page use.
				For SA11xx and Xscale, this is used to
				setup a minicache mapping.

ffff4000	ffffffff	cache aliasing on ARMv6 and later CPUs.

ffff1000	ffff7fff	Reserved.
				Platforms must not use this address range.

ffff0000	ffff0fff	CPU vector page.
				The CPU vectors are mapped here if the
				CPU supports vector relocation (control
				register V bit.)

fffe0000	fffeffff	XScale cache flush area.  This is used
				in proc-xscale.S to flush the whole data
				cache. (XScale does not have TCM.)

fffe8000	fffeffff	DTCM mapping area for platforms with
				DTCM mounted inside the CPU.

fffe0000	fffe7fff	ITCM mapping area for platforms with
				ITCM mounted inside the CPU.

ffc80000	ffefffff	Fixmap mapping region.  Addresses provided
				by fix_to_virt() will be located here.

ffc00000	ffc7ffff	Guard region

ff800000	ffbfffff	Permanent, fixed read-only mapping of the
				firmware provided DT blob

fee00000	feffffff	Mapping of PCI I/O space. This is a static
				mapping within the vmalloc space.

VMALLOC_START	VMALLOC_END-1	vmalloc() / ioremap() space.
				Memory returned by vmalloc/ioremap will
				be dynamically placed in this region.
				Machine specific static mappings are also
				located here through iotable_init().
				VMALLOC_START is based upon the value
				of the high_memory variable, and VMALLOC_END
				is equal to 0xff800000.

PAGE_OFFSET	high_memory-1	Kernel direct-mapped RAM region.
				This maps the platforms RAM, and typically
				maps all platform RAM in a 1:1 relationship.

PKMAP_BASE	PAGE_OFFSET-1	Permanent kernel mappings
				One way of mapping HIGHMEM pages into kernel
				space.

MODULES_VADDR	MODULES_END-1	Kernel module space
				Kernel modules inserted via insmod are
				placed here using dynamic mappings.

TASK_SIZE	MODULES_VADDR-1	KASAn shadow memory when KASan is in use.
				The range from MODULES_VADDR to the top
				of the memory is shadowed here with 1 bit
				per byte of memory.

00001000	TASK_SIZE-1	User space mappings
				Per-thread mappings are placed here via
				the mmap() system call.

00000000	00000fff	CPU vector page / null pointer trap
				CPUs which do not support vector remapping
				place their vector page here.  NULL pointer
				dereferences by both the kernel and user
				space are also caught via this mapping.
=============== =============== ===============================================
```

...
- vmalloc 영역: 흩어진 물리 페이지를 가상 주소로 연속이 되게 할당.
- highmem/lowmem 영역: 물리 주소가 연속이 되도록 할당. 부팅 시 매핑, 이후 변경 없음.
...

task_struct는 크기가 고정되어 있는 작은 구조체이며, 운영체제가 자주 접근하기 때문에 lowmem 영역에 할당한다.
커널 스택은 반대로 크기가 크고, overflow 위험이 있어 guard page가 필요하기 때문에 vmalloc 영역에 할당한다.

alloc_task_struct_node 함수를 따라가보면, slab_alloc_node를 통해 메모리를 할당받고 있음을 확인할 수 있다.

### slab
lowmem에서도 기본 할당 크기는 page 단위임. task_struct 하나만 담으면 공간 낭비가 심하기 때문에, 할당받은 페이지를 캐시로 들고,
이를 쪼개서 할당해주는 것이 slab.

쪼개는 크기는 용도별로 미리 다양하게 정의해놓았음. slab 1개는 같은 사이즈의 slab object들로 쪼개서, slab freelist에서 관리함.
slab object는 단순하게 사이즈 별로 자르고, 그 안에 다음 object의 시작 주소를 저장해놓은 형식임.

cpu가 메모리 할당을 요구할 경우, 해당 cpu의 freelist에 slab freelist를 가져옴. cpu가 object를 해제할 경우, cpu freelist가 아닌 slab freelist로 반환됨.

```c
static struct task_struct *dup_task_struct(struct task_struct *orig, int node)
{
	...
	tsk = alloc_task_struct_node(node);
	...
}

// fork_init()에서 초기화됨.
static struct kmem_cache *task_struct_cachep;

static inline struct task_struct *alloc_task_struct_node(int node)
{
	return kmem_cache_alloc_node(task_struct_cachep, GFP_KERNEL, node);
}

// alloc_hooks는 메모리 할당 통계 집계를 위해 감싸놓은 매크로임.
#define kmem_cache_alloc_node(...)	alloc_hooks(kmem_cache_alloc_node_noprof(__VA_ARGS__))

void *kmem_cache_alloc_node_noprof(struct kmem_cache *s, gfp_t gfpflags, int node)
{
	void *ret = slab_alloc_node(s, NULL, gfpflags, node, _RET_IP_, s->object_size);

	trace_kmem_cache_alloc(_RET_IP_, ret, s, gfpflags, node);

	return ret;
}

static __fastpath_inline void *slab_alloc_node(struct kmem_cache *s, struct list_lru *lru,
		gfp_t gfpflags, int node, unsigned long addr, size_t orig_size)
{
	void *object;
	...
	if (!object)
		object = __slab_alloc_node(s, gfpflags, node, addr, orig_size);
	...
	return object;
}

static __always_inline void *__slab_alloc_node(struct kmem_cache *s,
		gfp_t gfpflags, int node, unsigned long addr, size_t orig_size)
{
	struct kmem_cache_cpu *c;
	struct slab *slab;
	unsigned long tid;
	void *object;

	c = raw_cpu_ptr(s->cpu_slab);

	// linked queue라고 생각하면 됌. head에서 pop해서 할당받아 사용.
	object = c->freelist;
	
	if (!USE_LOCKLESS_FAST_PATH() ||
	    unlikely(!object || !slab || !node_match(slab, node))) {
		// 현재 slab에 남은 공간이 없을 경우 예외처리
		// try slab freelist에서 가져오기
		// if fails, 새로운 slab 생성
		object = __slab_alloc(s, gfpflags, node, addr, c, orig_size);
	} else {
		void *next_object = get_freepointer_safe(s, object);
		...
	}

	return object;
}
```

# current 매크로

사용한 빌드 설정 기준으로, 특정 레지스터에 현재 task_struct의 주소를 넣어두며, current 매크로 또한 해당 레지스터의 값을 읽어오는 것으로 작성되어 있음.

```c
// linux/arch/arm/include/asm/current.h:17-59
static __always_inline __attribute_const__ struct task_struct *get_current(void)
{
	struct task_struct *cur;
	asm("0:	mrc p15, 0, %0, c13, c0, 3			\n\t"
	    : "=r"(cur));
	return cur;
}
```
