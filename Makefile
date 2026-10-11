# Local developer commands. Values in a git-ignored .env file (see .env.example)
# are loaded automatically.
-include .env
export

.PHONY: bootstrap project open test lint beta

bootstrap: ## install tools (once per Mac)
	brew install xcodegen swiftlint
	bundle install

project: ## regenerate FrigateApp.xcodeproj from project.yml
	@test -n "$(DEVELOPMENT_TEAM)" || echo "warning: DEVELOPMENT_TEAM is not set (see .env.example); signing will need to be picked in Xcode"
	xcodegen generate

open: project ## generate and open in Xcode
	open FrigateApp.xcodeproj

test: ## unit tests on the simulator
	bundle exec fastlane test

lint:
	swiftlint lint

beta: ## build + upload to TestFlight from this Mac
	bundle exec fastlane beta
