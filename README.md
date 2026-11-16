# vehicle-record-batch-processor

## Layout

```
src/       C sources (main.c holds the entry point)
include/   Public headers
tests/     Each tests/*.c is built as its own test binary
build/     Build output (ignored)
```

## Building

```sh
make          # release build -> build/vrbp
make run      # build and run
make test     # build and run every test in tests/
make debug    # -g -O0 with UBSan
make asan     # adds AddressSanitizer (hangs with the current Apple toolchain)
make clean
```
