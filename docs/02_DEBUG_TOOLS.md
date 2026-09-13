# 커널 로그를 활용하는 방법

## `printk`

커널 로그에 `printf`와 같은 방식으로 출력하는 함수, 비용이 크기 때문에 자주 호출하는 함수에 포함시키면 위험하다.

## `dump_stack`

커널 로그에 콜 스택을 출력하는 함수. 스택 주소를 조사하는 등 `printk`보다 비용이 크므로, 마찬가지로 위험하다.

# ftrace

특징:
- 함수 필터를 지정하여 콜 스택을 소스코드 수정 없이 확인
- 인터럽트, 스케줄링, 커널 타이머 등 커널의 세부 실행 정보를 확인
- 부하가 거의 없음

이게 어떻게 가능하지...??

사용방법:
ftrace 관련 코드를 포함시켜(옵션 활성화) 커널 소스를 빌드해야함. ftrace 옵션을 키고 빌드 시, `/sys/kernel/tracing` 경로가 생성되며, `tracefs`를 해당 경로에 마운트하여 사용하게 된다.
`/sys/kernel/tracing` 경로 아래 다양한 설정파일 값을 수정하여 원하는 tracer, event, 함수 filter 등을 활성화/비활성화한다.

## ftrace 로그 해석 방법

```
#                              _-----=> irqs-off
#                             / _----=> need-resched
#                            | / _---=> hardirq/softirq
#                            || / _--=> preempt-depth
#                            ||| /     delay
#           TASK-PID   CPU#  ||||    TIMESTAMP  FUNCTION
#              | |       |   ||||       |         |
            bash-1977  [000] .... 17284.993652: sys_close <-system_call_fastpath
```

### 컨텍스트 정보

4개 알파벳으로 구성. 기본은 `.`으로 출력되며, 해당하는 상태일 때 알맞은 알파벳이 출력.

1. `d`: 하드웨어 인터럽트 비활성화 상태.
2. `n`: 현재 프로세스가 선점 스케줄링이 필요한지 여부
3. `h/s`: 현재 코드가 어떤 인터럽트 문맥에서 실행 중인지. `h`이면 인터럽트, `s`이면 Soft IRQ.
4. `0~3`: 선점 비활성화 중첩 정도.

참고: [https://www.kernel.org/doc/html/latest/trace/ftrace.html](https://www.kernel.org/doc/html/latest/trace/ftrace.html)

## ftrace 로그 추출 방법

로그는 커널 내 CPU별 링 버퍼에 저장된다. `/sys/kernel/debug/tracing/trace`로 접근하여 확인 가능하며, 저장을 위해서는 파일을 읽는 동안 새로운 로그가 쌓이는 것을 방지하기 위해 추적을 정지한 다음 저장하는 것이 안전하다.
```
echo 0 > /sys/kernel/debug/tracing/tracing_on
cp /sys/kernel/debug/tracing/trace ./trace.log
```

