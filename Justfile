app_name := "quicklog"
bundle := ".build/quicklog.app"
bin := ".build/release/quicklog"

# list recipes
default:
    @just --list

# compile (release)
build:
    swift build -c release

# assemble .build/quicklog.app
bundle: build
    rm -rf {{bundle}}
    mkdir -p {{bundle}}/Contents/MacOS
    cp {{bin}} {{bundle}}/Contents/MacOS/{{app_name}}
    cp Resources/Info.plist {{bundle}}/Contents/Info.plist
    codesign --force --sign - {{bundle}} 2>/dev/null || true
    @echo "built {{bundle}}"

# run in foreground with logs (ctrl-c to quit)
run: bundle
    {{bundle}}/Contents/MacOS/{{app_name}}

# run detached, like a real app launch
start: bundle
    open {{bundle}}

# kill any running instance
stop:
    -pkill -x {{app_name}}

# rebuild + restart detached
restart: stop start

# run storage tests
# Plain executable, not XCTest: XCTest ships with Xcode and this machine has
# Command Line Tools only.
test:
    @swiftc -swift-version 5 -o .build/storage-tests Sources/quicklog/StorageManager.swift Tests/main.swift
    @.build/storage-tests

# copy to /Applications
install: bundle
    rm -rf /Applications/{{app_name}}.app
    cp -R {{bundle}} /Applications/{{app_name}}.app
    @echo "installed /Applications/{{app_name}}.app"

# open the storage folder
data:
    open ~/Library/Application\ Support/quicklog

# tail today's markdown file
today:
    @cat ~/Library/Application\ Support/quicklog/$(date +%F).md 2>/dev/null || echo "no entries today"

# delete all journal data (asks first)
# Stops the app first: the single-instance lock lives in that folder, and
# deleting it under a running instance would let a second one start.
nuke-data: stop
    @read -p "delete ~/Library/Application Support/quicklog? [y/N] " ok && [ "$ok" = "y" ] && rm -rf ~/Library/Application\ Support/quicklog && echo deleted || echo aborted

clean:
    rm -rf .build
