# 인터럽트 전체 흐름

**Top Half**
1. 인터럽트 발생
2. 프로세스 실행 중단, IRQ 인터럽트에 해당하는 익셉션 벡터로 점프. (하드웨어 구현)
3. 익셉션 벡터에 들어있는 명령어: 인터럽트 벡터로 점프. (이 단계부터 소프트웨어 구현)
4. 인터럽트 벡터: 유저모드/커널모드에 맞는 IRQ 핸들러로 점프.
3. 해당하는 IRQ handler 실행
4. 프로세스로 복귀

**Bottom Half**
오래 걸리는 작업들은 IRQ handler에서 바로 실행하는 대신 지연 처리.

## ftrace + 코드 분석 + qemu gdb로 커널 디버깅

### ftrace 로그
```
...
          <idle>-0       [001] d.h..   535.658387: irq_handler_entry: irq=89 name=dwc_otg
          <idle>-0       [001] d.h..   535.658392: dwc_otg_common_irq+0x8/0x20 <-__handle_irq_event_percpu+0x84/0x2b4
          <idle>-0       [001] d.h..   535.658414: <stack trace>
 => dwc_otg_common_irq+0xc/0x20
 => __handle_irq_event_percpu+0x84/0x2b4
 => handle_irq_event+0x48/0x90
 => handle_level_irq+0xe8/0x194
 => handle_irq_desc+0x58/0x88
 => handle_irq_desc+0x58/0x88
 => generic_handle_arch_irq+0x34/0x44
 => call_with_stack+0x18/0x20
 => __irq_svc+0x98/0xb0
 => default_idle_call+0x38/0xa0
 => do_idle+0xbc/0x130
 => cpu_startup_entry+0x30/0x34
 => secondary_start_kernel+0x120/0x128
 => 0x10d0a0
 ...
```

idle 실행 중 인터럽트 발생, irq=89, 이름은 dwc_otg.
```
 => call_with_stack+0x18/0x20
 => __irq_svc+0x98/0xb0
 => default_idle_call+0x38/0xa0
```
 default_idle_call 호출 중 인터럽트 발생, __irq_svc 호출됨.

### __irq_svc
```
❯ egrep -nr "__irq_svc"
arch/arm/kernel/entry-armv.S:226:__irq_svc:
arch/arm/kernel/entry-armv.S:241:ENDPROC(__irq_svc)
arch/arm/kernel/entry-armv.S:957:	.long	__irq_svc			@  3  (SVC_26 / SVC_32)
```
인터럽트 벡터 위치는 CPU 아키텍처마다 다르므로 arch 경로에 들어가 있음을 확인할 수 있음.
```
// linux/arch/arm/kernel/entry-armv.S:226-241

__irq_svc:
	svc_entry
	irq_handler from_user=0

#ifdef CONFIG_PREEMPTION
	ldr	r8, [tsk, #TI_PREEMPT]		@ get preempt count
	ldr	r0, [tsk, #TI_FLAGS]		@ get flags
	teq	r8, #0				@ if preempt count != 0
	movne	r0, #0				@ force flags to 0
	tst	r0, #_TIF_NEED_RESCHED
	blne	svc_preempt
#endif

	svc_exit r5, irq = 1			@ return from exception
 UNWIND(.fnend		)
ENDPROC(__irq_svc)
```
__irq_svc가 호출되는 과정은 다음과 같음.
1. cpu에서 인터럽트 발생 시, 익셉션 벡터 베이스 주소로 점프한다.
2. irq 익셉션 벡터 베이스 주소에는, vector_irq 라벨 주소로 점프하는 명령이 들어있으므로, 해당 주소로 점프 한다.
3. vector_irq 라벨 주소에서 실행을 이어가다가 알맞은 handler(__irq_svc or _irq_usr)로 점프한다.

__irq_svc는 크게 3개 단계로 실행됨.
svc_entry: 인터럽트 종료 후 복귀하기 위해, 기존 컨텍스트를 저장하는 매크로
irq_handler: IRQ 스택으로 바꾸고 C 함수로 호출하는 매크로
svc_exit: 인터럽트 종료 후 기존 컨텍스트로 복귀하는 매크로

### svc_entry
```
// linux/arch/arm/kernel/entry-armv.S:161-215

		.macro	svc_entry, stack_hole=0, trace=1, uaccess=1, overflow_check=1

	// 스택에 svc register가 요구하는 만큼 자리를 확보함
	sub	sp, sp, #(SVC_REGS_SIZE + \stack_hole)

	// 자리 확보하면 오버플로우 발생하는지 확인
	.if	\overflow_check
	do_overflow_check (SVC_REGS_SIZE + \stack_hole)
	.endif

	// STore Multiple Increment Before
	// 레지스터 여러개를 스택에 한번에 저장하며, 저장 시작 전 sp+4 수행, 따라서 sp+0 지점은 비어있게 됨.
	// stmin    sp! 와 같이 느낌표를 붙이면 저장 후 sp가 업데이트 되나, 여기서는 붙이지 않았기 때문에 sp 변화는 없음.
 	stmib	sp, {r1 - r12}

	ldmia	r0, {r3 - r5}
	add	r7, sp, #S_SP		@ here for interlock avoidance
	mov	r6, #-1			@  ""  ""      ""       ""
	add	r2, sp, #(SVC_REGS_SIZE + \stack_hole)
 SPFIX(	addne	r2, r2, #4	)
	str	r3, [sp]		@ save the "real" r0 copied
					@ from the exception stack

	mov	r3, lr

	stmia	r7, {r2 - r6}

	get_thread_info tsk
	uaccess_entry tsk, r0, r1, r2, \uaccess

	.endm
```

### irq_handler

IRQ 스택 - CPU 별로 1개 씩 할당된 스택.
사용 이유 - 인터럽트가 발생했을 때, 해당 프로세스의 커널 스택을 그대로 사용하게 될 경우, 스택 오버플로우에 취약함.
CPU 마다 1개만 있는 이유 - 어차피 인터럽트는 CPU 당 1개씩. 인터럽트 핸들러와 soft irq는 선점/스케쥴링되지 않으므로, 따로 저장해둘 이유가 없다.

IRQ 스택 사용 시 한 가지 검사할 경우가 존재한다. soft irq 또한 IRQ 스택을 사용하므로, soft irq 사용 중 하드웨어 인터럽트가 들어올 수 있다.
이 경우, soft irq가 사용 중이던 내용은 그대로 두고, 그 위에 이어서 사용한다. 이를 위해 간단하게 sp가 IRQ 스택 범위에 포함되는지 검사하게 된다.

```
// linux/arch/arm/kernel/entry-armv.S:42-59

	.macro	irq_handler, from_user:req
	mov	r1, sp
	ldr_this_cpu r2, irq_stack_ptr, r2, r3
	.if	\from_user == 0
	@
	@ If we took the interrupt while running in the kernel, we may already
	@ be using the IRQ stack, so revert to the original value in that case.
	@
	subs	r3, r2, r1		@ SP above bottom of IRQ stack?
	rsbscs	r3, r3, #THREAD_SIZE	@ ... and below the top?
#ifdef CONFIG_VMAP_STACK
	ldr_va	r3, high_memory, cc	@ End of the linear region
	cmpcc	r3, r1			@ Stack pointer was below it?
#endif
	bcc	0f			@ If not, switch to the IRQ stack
	mov	r0, r1
	bl	generic_handle_arch_irq
	b	1f
0:
	.endif

	mov_l	r0, generic_handle_arch_irq
	bl	call_with_stack
1:
	.endm
```

앞선 ftrace 로그에서는 call_with_stack이 호출되었으므로, IRQ 스택 사용 중이 아니었음을 알 수 있다. idle 상태에서 인터럽트가 일어난 것이니 당연하겠지만.

### generic_handle_arch_irq

handle_arch_irq 함수는 커널 최초 실행 시 초기화된 함수 포인터 handle_arch_irq를 실행한다. 아키텍처 상관 없이 커널 빌드 하나로 사용할 수 있도록 하기 위함.

``` c
// linux/kernel/irq/handle.c
void (*handle_arch_irq)(struct pt_regs *) __ro_after_init;

int __init set_handle_irq(void (*handle_irq)(struct pt_regs *))
{
	if (handle_arch_irq)
		return -EBUSY;

	handle_arch_irq = handle_irq;
	return 0;
}

asmlinkage void noinstr generic_handle_arch_irq(struct pt_regs *regs)
{
	struct pt_regs *old_regs;

	irq_enter();
	old_regs = set_irq_regs(regs);
	handle_arch_irq(regs);
	set_irq_regs(old_regs);
	irq_exit();
}
```

gdb로 따라가본 결과, bcm2836_arm_irqchip_handle_irq로 등록되어있음을 확인했음. set_handle_irq로 bcm2836_arm_irqchip_handle_irq를 등록해주고 있었음.

```c
// linux/drivers/irqchip/irq-bcm2836.c

static int __init bcm2836_arm_irqchip_l1_intc_of_init(struct device_node *node,
						      struct device_node *parent)
{
	...
	set_handle_irq(bcm2836_arm_irqchip_handle_irq);
	return 0;
}

__exception_irq_entry bcm2836_arm_irqchip_handle_irq(struct pt_regs *regs)
{
	int cpu = smp_processor_id();
	u32 stat;

	stat = readl_relaxed(intc.base + LOCAL_IRQ_PENDING0 + 4 * cpu);
	if (stat) {
		u32 hwirq = ffs(stat) - 1;

		generic_handle_domain_irq(intc.domain, hwirq);
	}
}
```

bcm2836_arm_irqchip_handle_irq에서는 generic_handle_domain_irq로 호출이 이어지는데, irq_resolve_mapping 함수를 통해 hwirq 번호를 domain에 맞게 리눅스 irq 디스크립터로 변환,
handle_irq_desc 함수로 넘겨 처리한다.

```c
// linux/kernel/irq/irqdesc.c
// struct irq_domain - Hardware interrupt number translation object
int generic_handle_domain_irq(struct irq_domain *domain, unsigned int hwirq)
{
	return handle_irq_desc(irq_resolve_mapping(domain, hwirq));
}


int handle_irq_desc(struct irq_desc *desc)
{
	struct irq_data *data;

	if (!desc)
		return -EINVAL;

	data = irq_desc_get_irq_data(desc);
	if (WARN_ON_ONCE(!in_hardirq() && irqd_is_handle_enforce_irqctx(data)))
		return -EPERM;

	generic_handle_irq_desc(desc);
	return 0;
}
```

#### 꼬리 호출 최적화

```
 => handle_irq_desc+0x58/0x88
 => generic_handle_arch_irq+0x34/0x44
```

콜스택에서 handle_arch_irq, bcm2836_arm_irqchip_handle_irq, generic_handle_domain_irq가 찍히지 않고 넘어갔던 이유는 꼬리 호출 최적화 때문이다.
만약 어떤 함수가 특정 함수를 호출하고 이후에 별다른 동작을 하지 않는다면, 스택을 만드는 대신에 그냥 이어가면서 실행하게 한다. 굳이 리턴해서 할 작업이 없기 때문이다.
이 경우, 스택에 리턴 주소가 남지 않지 때문에 ftrace가 콜스택을 만들 때 보이지 않게 된다.

### handle_irq_desc

```
 => handle_irq_desc+0x58/0x88
 => handle_irq_desc+0x58/0x88
```

ftrace 콜스택에는 handle_irq_desc가 2번 있다. 실재 코드 흐름을 따라가보면, bcm2836_chained_handle_irq를 통해 handle_irq_desc가 다시 한번 호출되게 된다.

```c
static inline void generic_handle_irq_desc(struct irq_desc *desc)
{
	desc->handle_irq(desc);
}
// gdb로 실행 함수 확인
static void bcm2836_chained_handle_irq(struct irq_desc *desc)
{
	u32 hwirq;

	hwirq = get_next_armctrl_hwirq();
	if (hwirq != ~0)
		generic_handle_domain_irq(intc.domain, hwirq);
}

int generic_handle_domain_irq(struct irq_domain *domain, unsigned int hwirq)
{
	return handle_irq_desc(irq_resolve_mapping(domain, hwirq));
}
```

gdb로 확인해보면:
```
(gdb) b handle_irq_desc
(gdb) c
(gdb) p desc->handle_irq
$11 = (irq_flow_handler_t) 0x807d0474 <bcm2836_chained_handle_irq>
(gdb) c
(gdb) p desc->handle_irq
$12 = (irq_flow_handler_t) 0x801a8ff4 <handle_level_irq>
```

이유는 인터럽트 컨트롤러 구조 때문이다. CPU에 IRQ 핀 개수는 제한이 있는데, 인터럽트 소스는 굉장히 많다. 따라서 중간에 인터럽트 신호들을 모아서 CPU IRQ 핀으로 보내주고, 어느 소스에서 신호가 왔는지 저장해둘 장치가 필요하다. 이 역할을 인터럽트 컨트롤러에서 하는데, 인터럽트 컨트롤러 또한 1개만 있는 것이 아니라, 계층을 이루면서 연결되어 있다. 따라서 이를 읽어오기 위해 재귀적으로, 인터럽트 컨트롤러마다 등록된 핸들러를 호출한다.

라즈베리파이는 아래와 같은 방식으로 인터럽트를 처리하게 된다. 위 ftrace 로그의 경우, armctrl 컨트롤러에 연결된 장치 중 하나가 신호를 보냈고, 이 신호는 L1 -> CPU IRQ 핀으로 이어진다. 핸들러 실행은 역순으로, CPU 코어가 L1의 핸들러를 호출하면, L1의 핸들러는 armctrl의 hwirq를 읽어와서 그에 해당하는 핸들러를 최종적으로 호출하게 된다.

```
USB ────┐
UART ───┤
SD ─────┼──▶ [armctrl] ──▶ 선 1개 ──▶ [L1 입력 8번] ─┐
DMA ────┤                                         │
...  ───┘                                         │
                       코어0 타이머 ──▶ [L1 입력 0~3] ┼──▶ 코어0 IRQ 핀
                       mailbox   ──▶ [L1 입력 4~7] ┘
```

개발자 입장에서는 굉장히 간편하다. 해당 인터럽트 핸들러만 짜 놓으면, 그 위/아래에서 무엇을 호출하는지는 신경쓰지 않아도 괜찮기 때문이다.
아키텍처에 따라 IRQ 핀만 있는게 아니라, 인터럽트 번호를 같이 보내주기도 한다. 해당 경우에도 커널은 번호에 해당하는 핸들러를 호출하기 때문에, 공통 코드는 동일하게 된다.