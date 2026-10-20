SOURCES := ShowMyCopy ShowMyCopyTests

.PHONY: lint format test

lint:
	swiftlint lint --strict --quiet
	xcrun swift-format lint --strict --recursive $(SOURCES)

format:
	xcrun swift-format format --in-place --recursive $(SOURCES)
	swiftlint lint --fix --quiet

test:
	xcodebuild test -project ShowMyCopy.xcodeproj -scheme ShowMyCopy -destination 'platform=macOS,arch=arm64' \
		-testLanguage en -testRegion US -quiet
