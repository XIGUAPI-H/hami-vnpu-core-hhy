#!/bin/bash
set -u
kubectl delete -f /mnt/local/m00953550/FinalTest/hamiNewVllm.yaml --ignore-not-found=true 2>&1 | head -3
kubectl delete pod probe-npu-props --ignore-not-found=true 2>&1 | head -3
sleep 5
cat > /tmp/probe_pod.yaml <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: probe-npu-props
  namespace: default
  labels:
    app: probe-npu-props
  annotations:
    huawei.com/vnpu-mode: hami-core
spec:
  schedulerName: hami-scheduler
  restartPolicy: Never
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet
  volumes:
    - name: ascend-driver
      hostPath: { path: /usr/local/Ascend/driver }
    - name: ascend-firmware
      hostPath: { path: /usr/local/Ascend/firmware }
    - name: hccn-conf
      hostPath: { path: /etc/hccn.conf }
    - name: dcmi
      hostPath: { path: /usr/local/dcmi }
    - name: ascend-toolbox
      hostPath: { path: /usr/local/Ascend/toolbox }
    - name: npu-smi
      hostPath: { path: /usr/local/bin/npu-smi }
    - name: var-log-npu
      hostPath: { path: /var/log/npu/ }
    - name: davinci-manager
      hostPath: { path: /dev/davinci_manager }
    - name: devmm-svm
      hostPath: { path: /dev/devmm_svm }
    - name: hisi-hdc
      hostPath: { path: /dev/hisi_hdc }
  containers:
    - name: probe
      image: quay.io/ascend/vllm-ascend:v0.13.0rc1
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-c"]
      args:
        - |
          set -u
          echo '=== chip props (no hami hijack) ==='
          python3 -c "
          import torch, torch_npu
          torch.npu.set_device(0)
          p = torch.npu.get_device_properties(0)
          print('total_memory_bytes:', p.total_memory)
          print('total_memory_MiB:', p.total_memory / 1024 / 1024)
          print('props:', p)
          import torch_npu.npu
          free, total = torch_npu.npu.mem_get_info()
          print('mem_get_info free=', free, ' total=', total)
          "
          echo
          echo '=== npu-smi inside pod ==='
          npu-smi info -t usages -i 0 -c 0 2>&1 | grep -E "HBM Cap|HBM Usage"
          echo
          echo '=== aclrtGetMemInfoImpl direct (no LD_PRELOAD interception expected) ==='
          ldconfig -p | grep -E "ascendcl|hccl|cann" | head -10
          echo
          echo 'sleeping for inspection'
          sleep 1800
      env:
        - name: ASCEND_RT_VISIBLE_DEVICES
          value: "0"
      resources:
        limits:
          huawei.com/Ascend910B3: "1"
          huawei.com/Ascend910B3-memory: "16000"
          huawei.com/Ascend910B3-core: "25"
        requests:
          huawei.com/Ascend910B3: "1"
          huawei.com/Ascend910B3-memory: "16000"
          huawei.com/Ascend910B3-core: "25"
      securityContext:
        privileged: true
      volumeMounts:
        - { name: ascend-driver, mountPath: /usr/local/Ascend/driver, readOnly: true }
        - { name: ascend-firmware, mountPath: /usr/local/Ascend/firmware, readOnly: true }
        - { name: hccn-conf, mountPath: /etc/hccn.conf, readOnly: true }
        - { name: dcmi, mountPath: /usr/local/dcmi, readOnly: true }
        - { name: ascend-toolbox, mountPath: /usr/local/Ascend/toolbox, readOnly: true }
        - { name: npu-smi, mountPath: /usr/local/bin/npu-smi, readOnly: true }
        - { name: var-log-npu, mountPath: /var/log/npu, readOnly: true }
        - { name: davinci-manager, mountPath: /dev/davinci_manager }
        - { name: devmm-svm, mountPath: /dev/devmm_svm }
        - { name: hisi-hdc, mountPath: /dev/hisi_hdc }

YAML
kubectl apply -f /tmp/probe_pod.yaml

echo
echo '=== wait for probe pod ==='
for i in +''+; do
  s=+''+
  echo "[t=+''+*3s] phase=+''+"
  if [ "+''+" = "Running" ] || [ "+''+" = "Failed" ] || [ "+''+" = "Succeeded" ]; then break; fi
  sleep 3
done
sleep 25
echo
echo '=== probe pod logs ==='
kubectl logs probe-npu-props 2>&1 | head -80
echo
echo '=== events ==='
kubectl describe pod probe-npu-props 2>/dev/null | tail -30