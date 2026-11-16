CC      ?= cc
CFLAGS  ?= -std=c17 -Wall -Wextra -Wpedantic -Wshadow -Wconversion -O2
CPPFLAGS += -Iinclude -MMD -MP
LDFLAGS ?=
LDLIBS  ?=

BIN      := vrbp
BUILD    := build
SRC      := $(wildcard src/*.c)
OBJ      := $(SRC:src/%.c=$(BUILD)/%.o)
LIB_OBJ  := $(filter-out $(BUILD)/main.o,$(OBJ))
TEST_SRC := $(wildcard tests/*.c)
TEST_BIN := $(TEST_SRC:tests/%.c=$(BUILD)/tests/%)

.PHONY: all debug asan test clean run

all: $(BUILD)/$(BIN)

DEBUG_CFLAGS := -std=c17 -Wall -Wextra -Wpedantic -Wshadow -Wconversion -g -O0

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

run: $(BUILD)/$(BIN)
	./$(BUILD)/$(BIN)

clean:
	rm -rf $(BUILD)

-include $(OBJ:.o=.d)
