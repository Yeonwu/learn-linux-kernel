#!/bin/bash

mkdir -p /sys/kernel/debug
mount -t debugfs debugfs /sys/kernel/debug

echo 0 > /sys/kernel/debug/tracing/tracing_on
sleep 1
echo "tracing_off" 

echo 0 > /sys/kernel/debug/tracing/events/enable
sleep 1
echo "events disabled"

echo  secondary_start_kernel  > /sys/kernel/debug/tracing/set_ftrace_filter	
sleep 1
echo "set_ftrace_filter init"

echo function > /sys/kernel/debug/tracing/current_tracer
sleep 1
echo "function tracer enabled"

echo 1 > /sys/kernel/debug/tracing/events/sched/sched_switch/enable
echo bcm2835_mbox_irq > /sys/kernel/debug/tracing/set_ftrace_filter
echo 1 > /sys/kernel/debug/tracing/events/irq/irq_handler_exit/enable
sleep 1
echo "event enabled"

echo rpi_get_interrupt_info bcm2835_mmc_irq > /sys/kernel/debug/tracing/set_ftrace_filter
sleep 1
echo "set_ftrace_filter enabled"

echo 1 > /sys/kernel/debug/tracing/options/func_stack_trace
echo 1 > /sys/kernel/debug/tracing/options/sym-offset
echo "function stack trace enabled"

echo 1 > /sys/kernel/debug/tracing/tracing_on
echo "tracing_on"

cat /proc/interrupts

echo 0 > /sys/kernel/debug/tracing/tracing_on
echo "ftrace off"

sleep 3

cp /sys/kernel/debug/tracing/trace . 
mv trace ftrace_log.c
