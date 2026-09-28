CC ?= gcc
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Wpedantic
CPPFLAGS += -D_POSIX_C_SOURCE=200809L -Isrc
LDLIBS += -lcrypto
SRCS := $(wildcard src/*.c)
OBJS := $(SRCS:src/%.c=build/%.o)

.PHONY: all test test-tools clean

all: stegobmp

stegobmp: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

build/%.o: src/%.c $(wildcard src/*.h)
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<

test: stegobmp
	bash tests/run_tests.sh

test-tools:
	bash tests/run_tool_tests.sh

clean:
	rm -rf build stegobmp tests/out
