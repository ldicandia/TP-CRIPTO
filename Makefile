ifeq ($(origin CC),default)
CC = gcc
endif
CFLAGS ?= -std=c11 -O2 -Wall -Wextra -Wpedantic
CPPFLAGS += -D_POSIX_C_SOURCE=200809L -Iinclude
LDLIBS += -lcrypto
SRCS := $(wildcard src/*.c)
OBJS := $(SRCS:src/%.c=build/%.o)

.PHONY: all test test-tools clean report

all: stegobmp

stegobmp: $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $(OBJS) $(LDLIBS)

build/%.o: src/%.c $(wildcard include/*.h)
	mkdir -p build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<

test: stegobmp
	bash tests/run_tests.sh

test-tools:
	bash tests/run_tool_tests.sh

# Informe (LaTeX): mide con ./stegobmp y las herramientas de tools/, compila el PDF y lo valida.
report: stegobmp
	python3 informe/scripts/medir_q2.py
	bash informe/build.sh

clean:
	rm -rf build stegobmp tests/out runs
