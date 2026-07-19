watch -n.1 '
for disk in virtio-disk3 virtio-disk2; do
  echo "=== $disk ==="
  for q in 0 1 2 3; do
    out=$(virsh qemu-monitor-command win2k19-test --hmp "info virtio-queue-status /machine/peripheral/$disk/virtio-backend $q" 2>/dev/null)
    [ -z "$out" ] && break
    used=$(echo "$out" | grep -oP "last_avail_idx:\s*\K\d+")
    sig=$(echo "$out" | grep -oP "signalled_used:\s*\K\d+")
    printf "  q%d: inflight=%3d  (avail=%s used=%s)\n" "$q" $((used - sig)) "$used" "$sig"
  done
done'
