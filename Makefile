APP_NAME := Fringe
APP_BUNDLE := build/$(APP_NAME).app

.PHONY: app debug run stop test lint install clean

app:
	@./Scripts/build-app.sh

test:
	@swift test

lint:
	@swiftlint lint --strict

debug:
	@CONFIGURATION=debug ./Scripts/build-app.sh

run: app
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@open $(APP_BUNDLE)

stop:
	@pkill -x $(APP_NAME) 2>/dev/null || true

install: app
	@rm -rf /Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) /Applications/
	@echo "Installed /Applications/$(APP_NAME).app"

clean: stop
	@rm -rf .build build
