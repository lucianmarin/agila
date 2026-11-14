SWIFTC ?= swiftc
SWIFTFLAGS ?= -O

PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /usr/local)
BINDIR ?= $(DESTDIR)$(PREFIX)/bin

TARGET = agila
SRC = agila.swift

.PHONY: all test bench install uninstall clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(SWIFTC) $(SWIFTFLAGS) $(SRC) -o $(TARGET)

test: $(TARGET)
	./$(TARGET) --test

bench: $(TARGET)
	./$(TARGET) --bench

install: $(TARGET)
	install -d "$(BINDIR)"
	install -m 755 $(TARGET) "$(BINDIR)/$(TARGET)"

uninstall:
	rm -f "$(BINDIR)/$(TARGET)"

clean:
	rm -f $(TARGET)
	rm -rf .build *.dSYM
