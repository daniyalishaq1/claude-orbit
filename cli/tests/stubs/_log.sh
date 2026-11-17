# shared by stubs: append one line per call (caller sets $stub_name)
printf "%s %s\n" "$stub_name" "$*" >> "${STUB_LOG:-/dev/null}"
