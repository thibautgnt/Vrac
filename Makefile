SIGN_IDENTITY ?= C3542F0B1C830C4B91E42AD38E15C2BD42A8A9D8
DERIVED := .build/release-derived-data
APP := $(DERIVED)/Build/Products/Release/Vrac.app

.PHONY: build test install run release

build:
	xcodebuild -project Radix.xcodeproj -scheme Radix -configuration Release \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED) \
		CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build | grep -E 'error:|BUILD'
	# A stable signature keeps the Full Disk Access grant across rebuilds.
	codesign --force --deep --options runtime --sign $(SIGN_IDENTITY) $(APP)

test:
	swift test

install: build
	-osascript -e 'quit app "Vrac"'
	rm -rf /Applications/Vrac.app
	ditto $(APP) /Applications/Vrac.app
	@echo "Installed /Applications/Vrac.app"

run: install
	open /Applications/Vrac.app

VERSION := $(shell grep -m1 'MARKETING_VERSION' Radix.xcodeproj/project.pbxproj | sed 's/.*= \(.*\);/\1/')

release: build
	rm -f .build/Vrac.zip
	ditto -c -k --keepParent $(APP) .build/Vrac.zip
	gh release create v$(VERSION) .build/Vrac.zip --title "Vrac $(VERSION)" --notes-file docs/release-notes.md
