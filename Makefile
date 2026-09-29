SWIFTC ?= swiftc
SWIFTFLAGS ?= -O
BUILD := build
COMMON := $(wildcard src/common/*.swift)
TOOLS := ca_agg ca_setout ca_layout ca_multioutcheck ca_chanplay xdr-volume
APP := $(BUILD)/XDR Volume Keys.app

.PHONY: all app check clean

all: $(addprefix $(BUILD)/,$(TOOLS))

$(BUILD)/%: src/%/main.swift $(COMMON)
	@mkdir -p $(BUILD)
	$(SWIFTC) $(SWIFTFLAGS) -module-name $(subst -,_,$*) -o $@ $(COMMON) $<

# The app runs the same binary as the xdr-volume CLI; only the bundle identity differs.
app: $(BUILD)/xdr-volume app/Info.plist
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp app/Info.plist "$(APP)/Contents/Info.plist"
	cp $(BUILD)/xdr-volume "$(APP)/Contents/MacOS/XDR Volume Keys"
	codesign --force --sign - "$(APP)"
	codesign --verify --strict --verbose=2 "$(APP)"

# Hardware-free checks: syntax, plist validity and the media-key decoder.
check: $(BUILD)/xdr-volume
	bash -n install.sh scripts/*.sh
	plutil -lint app/Info.plist launchd/*.plist
	XDR_VOLUME=$(BUILD)/xdr-volume scripts/test_media_key_decode.sh

clean:
	rm -rf $(BUILD)
