APP = build/Build/Products/Release/Pasteruperer.app
XCODEBUILD = xcodebuild -project Pasteruperer.xcodeproj -scheme Pasteruperer -derivedDataPath build

.PHONY: project build test run install clean

project:
	xcodegen generate

build: project
	$(XCODEBUILD) -configuration Release build

test: project
	$(XCODEBUILD) test

run: build
	open $(APP)

install: build
	rm -rf /Applications/Pasteruperer.app
	cp -R $(APP) /Applications/
	open /Applications/Pasteruperer.app

clean:
	rm -rf build Pasteruperer.xcodeproj
