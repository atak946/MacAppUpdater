.PHONY: build test run app release clean lint icon

ICON_TMP := build/icon

build:
	swift build

test:
	swift test --parallel

run:
	swift run AppUpdater

app:
	./scripts/build-app.sh

release:
	./scripts/release.sh

lint:
	shellcheck -x scripts/*.sh
	plutil -lint Packaging/*.plist
	swift build -c release -Xswiftc -warnings-as-errors

# Regenerates Packaging/AppIcon.icns from scripts/make-icon.swift.
icon:
	rm -rf $(ICON_TMP) && mkdir -p $(ICON_TMP)/AppIcon.iconset
	swift scripts/make-icon.swift $(ICON_TMP)/icon-1024.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s $(ICON_TMP)/icon-1024.png --out $(ICON_TMP)/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) $(ICON_TMP)/icon-1024.png --out $(ICON_TMP)/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns $(ICON_TMP)/AppIcon.iconset -o Packaging/AppIcon.icns

clean:
	swift package clean
	rm -rf build
