#!/bin/bash
echo '===card0 NPU processes detail (start time / cmdline)==='
for pid in 2691174 2691175 2691176 2691177 4064988; do
  echo "--- pid $pid ---"
  ps -o pid,ppid,lstart,etime,rss,cmd -p $pid 2>/dev/null || echo "  (gone)"
done
echo
echo '===all VLLM / pt_main_thread / vllm processes on host==='
ps -eo pid,ppid,etime,rss,cmd 2>/dev/null | grep -iE 'vllm|pt_main_thread|api_server' | grep -v grep | head -40
echo
echo '===containers using NPU (our pod current worker)==='
crictl ps 2>/dev/null | grep -iE 'vllm|ascend' | head
