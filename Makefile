SOURCES := ShowMyCopy ShowMyCopyTests

.PHONY: lint format test security security-selftest build-release

lint:
	swiftlint lint --strict --quiet
	xcrun swift-format lint --strict --recursive $(SOURCES)
	./scripts/check_security.sh
	python3 scripts/check_translations.py

format:
	xcrun swift-format format --in-place --recursive $(SOURCES)
	swiftlint lint --fix --quiet

test:
	xcodebuild test -project ShowMyCopy.xcodeproj -scheme ShowMyCopy -destination 'platform=macOS,arch=arm64' \
		-testLanguage en -testRegion US -quiet

# Proves every check in check_security.py can fail (fixtures, fake codesign); runs on Linux too.
security-selftest:
	python3 -I scripts/test_check_security.py

security: build-release
	./scripts/check_security.sh build/Build/Products/Release/ShowMyCopy.app

build-release:
	xcodebuild build -project ShowMyCopy.xcodeproj -scheme ShowMyCopy -configuration Release \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath build CODE_SIGN_IDENTITY=- -quiet
