app_name := "quicklog"
bundle := ".build/quicklog.app"
bin := ".build/release/quicklog"

# Sources compiled into the test binary. Not a glob: `QuicklogApp.swift` owns
# `@main`, which collides with `Tests/main.swift`, and the views would drag
# SwiftUI in for nothing. Add a file here when a tested one starts depending on
# it — the link error says which.
test_sources := "Sources/quicklog/String+Blank.swift Sources/quicklog/Storage.swift Sources/quicklog/TaskLine.swift Sources/quicklog/Markdown.swift Tests/main.swift"

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

# A plain executable, not XCTest: XCTest ships with Xcode and this machine has
# Command Line Tools only. `-swift-version 5` matches Package.swift.
#
# (Blank line below on purpose — `just --list` shows only the comment block
# touching the recipe, and shows just its last line.)

# run storage, checkbox and markdown tests
test:
    @swiftc -swift-version 5 -o .build/storage-tests {{test_sources}}
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

# list every unresolved checkbox across all days
todos:
    @grep -rEn -- "[-*+] ?\[ ?\]" ~/Library/Application\ Support/quicklog/*.md 2>/dev/null || echo "no open todos"

# Depends on `stop`: the single-instance lock lives in that folder, and deleting
# it under a running instance would let a second one start.

# delete all journal data (asks first)
nuke-data: stop
    @read -p "delete ~/Library/Application Support/quicklog? [y/N] " ok && [ "$ok" = "y" ] && rm -rf ~/Library/Application\ Support/quicklog && echo deleted || echo aborted

# delete build products (including the bundle and the test binary)
clean:
    rm -rf .build
