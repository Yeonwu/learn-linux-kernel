#!/bin/bash
set -eu

if ! mountpoint -q /sys/kernel/tracing; then
    mount -t tracefs nodev /sys/kernel/tracing
fi

echo 0 > /sys/kernel/tracing/tracing_on
sleep 1
echo "tracing_off" 

echo 0 > /sys/kernel/tracing/events/enable
sleep 1
echo "events disabled"

echo  secondary_start_kernel  > /sys/kernel/tracing/set_ftrace_filter	
sleep 1
echo "set_ftrace_filter init"

echo function > /sys/kernel/tracing/current_tracer
sleep 1
echo "function tracer enabled"

echo 1 > /sys/kernel/tracing/events/sched/sched_wakeup/enable
echo 1 > /sys/kernel/tracing/events/sched/sched_switch/enable

echo 1 > /sys/kernel/tracing/events/irq/irq_handler_entry/enable
echo 1 > /sys/kernel/tracing/events/irq/irq_handler_exit/enable

echo 1 > /sys/kernel/tracing/events/raw_syscalls/enable
echo "event enabled"


echo schedule ttwu_do_wakeup > /sys/kernel/tracing/set_ftrace_filter
sleep 1
echo "set ftrace filter enabled"

echo 1 > /sys/kernel/tracing/options/func_stack_trace
echo 1 > /sys/kernel/tracing/options/sym-offset
echo "function stack trace enabled"

echo 1 > /sys/kernel/tracing/tracing_on
echo "tracing_on"