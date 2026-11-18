CC      ?= cc
CFLAGS  ?= -std=c17 -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Werror -O2
CPPFLAGS += -Iinclude -MMD -MP
LDFLAGS ?=
LDLIBS  ?=

BIN      := validator
BUILD    := build
# Sources are listed explicitly: each program in src/ has its own main().
# LIB_SRC is code shared by the validator and the unit tests.
LIB_SRC  := src/record.c
LIB_OBJ  := $(LIB_SRC:src/%.c=$(BUILD)/%.o)
OBJ      := $(BUILD)/validator.o $(LIB_OBJ)
TEST_SRC := $(wildcard tests/*.c)
TEST_BIN := $(TEST_SRC:tests/%.c=$(BUILD)/tests/%)

.PHONY: all debug asan test clean run

all: $(BUILD)/$(BIN)

DEBUG_CFLAGS := -std=c17 -Wall -Wextra -Wpedantic -Wshadow -Wconversion -Werror -g -O0

debug: CFLAGS := $(DEBUG_CFLAGS) -fsanitize=undefined
debug: LDFLAGS += -fsanitize=undefined
debug: clean all

# AddressSanitizer binaries currently hang at startup with the local Apple toolchain,
# so ASan is opt-in rather than part of `debug`.
asan: CFLAGS := $(DEBUG_CFLAGS) -fsanitize=address,undefined
asan: LDFLAGS += -fsanitize=address,undefined
asan: clean all

$(BUILD)/$(BIN): $(OBJ)
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o $@

$(BUILD)/%.o: src/%.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/tests/%: tests/%.c $(LIB_OBJ) | $(BUILD)/tests
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) $^ $(LDLIBS) -o $@

$(BUILD) $(BUILD)/tests:
	mkdir -p $@

test: $(TEST_BIN)
	@for t in $(TEST_BIN); do echo "== $$t"; $$t || exit 1; done

# Validates one nightly file, e.g. make run FILE=data/inbound/nightly_20240115.dat
run: $(BUILD)/$(BIN)
	@test -n "$(FILE)" || { echo "usage: make run FILE=data/inbound/nightly_YYYYMMDD.dat"; exit 1; }
	./$(BUILD)/$(BIN) "$(FILE)" "$(BUILD)/$(notdir $(FILE:.dat=.clean))" \
		"$(BUILD)/$(notdir $(FILE:.dat=.rej))"

clean:
	rm -rf $(BUILD)

-include $(OBJ:.o=.d)
