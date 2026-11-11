# Local developer commands. Values in a git-ignored .env file (see .env.example)
# are loaded automatically.
-include .env
export

.PHONY: bootstrap project lock open test lint

bootstrap: ## install tools (once per Mac)
	brew install xcodegen swiftlint
	bundle install

RESOLVED := FrigateApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

project: ## regenerate FrigateApp.xcodeproj from project.yml
	@test -n "$(DEVELOPMENT_TEAM)" || echo "warning: DEVELOPMENT_TEAM is not set (see .env.example); signing will need to be picked in Xcode"
	xcodegen generate
	@mkdir -p $(dir $(RESOLVED)) && cp Package.resolved $(RESOLVED)

lock: ## after changing packages in project.yml or Xcode, save the resolved versions
	cp $(RESOLVED) Package.resolved

open: project ## generate and open in Xcode
	open FrigateApp.xcodeproj

test: ## unit tests on the simulator
	bundle exec fastlane test

lint:
	swiftlint lint
