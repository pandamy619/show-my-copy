SOURCES := ShowMyCopy ShowMyCopyTests

.PHONY: lint format test security build-release

lint:
	swiftlint lint --strict --quiet
	xcrun swift-format lint --strict --recursive $(SOURCES)
	./scripts/check_security.sh

format:
	xcrun swift-format format --in-place --recursive $(SOURCES)
	swiftlint lint --fix --quiet

test:
	xcodebuild test -project ShowMyCopy.xcodeproj -scheme ShowMyCopy -destination 'platform=macOS,arch=arm64' \
		-testLanguage en -testRegion US -quiet

security: build-release
	./scripts/check_security.sh build/Build/Products/Release/ShowMyCopy.app

build-release:
	xcodebuild build -project ShowMyCopy.xcodeproj -scheme ShowMyCopy -configuration Release \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath build CODE_SIGN_IDENTITY=- -quiet
