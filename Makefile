NAME := claude-dictation-pause
LABEL := com.leksat.$(NAME)
BIN := $(HOME)/.local/bin/$(NAME)
PLIST := $(HOME)/Library/LaunchAgents/$(LABEL).plist
DOMAIN := gui/$(shell id -u)

.PHONY: build install uninstall logs

build: .build/$(NAME)

.build/$(NAME): main.swift
	mkdir -p .build
	swiftc -swift-version 6 -O main.swift -o $@

install: build
	mkdir -p $(dir $(BIN)) $(dir $(PLIST))
	launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	install -m 755 .build/$(NAME) $(BIN)
	sed -e 's|@LABEL@|$(LABEL)|g' -e 's|@BIN@|$(BIN)|g' launchd.plist.in > $(PLIST)
	launchctl bootstrap $(DOMAIN) $(PLIST)

uninstall:
	launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -f $(PLIST) $(BIN)

logs:
	log stream --style compact --predicate 'subsystem == "$(LABEL)"'
