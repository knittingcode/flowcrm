abi <abi/4.0>,
profile @NAME@ flags=(enforce,attach_disconnected) {
  file,
  unix,
  network,
  signal,
  ptrace (read, readby, trace, tracedby) peer=@NAME@,
  deny capability,
  deny mount,
  deny umount,
  deny pivot_root,
  deny network vsock,
}
