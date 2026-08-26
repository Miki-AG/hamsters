#!/bin/bash
# ==============================================================================
# 🐹 HAMSTER HABITAT - Minimalist Master Fleet Dashboard
# ==============================================================================
# - Single-file, zero-dependency master controller for all local Hamsters.
# - Decoupled state management via ~/Library/Application Support/Hamsters/<ID>/state.txt
# - Start/Stop individual Hamster workers or entire fleet in parallel.
# - Independent Open Window actions to inspect settings or GUI on demand.
# - Real-time monitoring of live queue counts, status badges, and backends.
# ==============================================================================

export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$HOME/.gemini/bin:$HOME/.codex/bin:$HOME/.claude/bin:$HOME/bin:$PATH"

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# ------------------------------------------------------------------------------
# Auto-Dismiss Terminal Window on launch
# ------------------------------------------------------------------------------
if [ "$1" != "--gui-worker" ]; then
    nohup "$SCRIPT_PATH" --gui-worker >/dev/null 2>&1 &
    osascript -e '
    tell application "Terminal"
        if (count of windows) > 0 then
            close front window
        end if
    end tell' 2>/dev/null &
    exit 0
fi

# ------------------------------------------------------------------------------
# Launch Habitat GUI
# ------------------------------------------------------------------------------
exec /usr/bin/osascript -l JavaScript - "$SCRIPT_PATH" << 'EOF'
function run(argv) {
    ObjC.import("Cocoa");

    const scriptPath = argv[0];
    const fm = $.NSFileManager.defaultManager;
    const userHome = "/Users/" + $.NSUserName().js;
    const baseStorage = userHome + "/Library/Application Support/Hamsters";

    function makeDir(path) {
        if (!path) return;
        if (!fm.fileExistsAtPath(path)) {
            fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(path, true, $(), $());
        }
    }

    function listDir(path) {
        if (!path || !fm.fileExistsAtPath(path)) return [];
        const contents = fm.contentsOfDirectoryAtPathError(path, $());
        if (contents && !contents.isNil()) {
            const arr = [];
            const count = contents.count;
            for (let i = 0; i < count; i++) {
                arr.push(contents.objectAtIndex(i).js);
            }
            return arr;
        }
        return [];
    }

    function readJSON(file) {
        if (!fm.fileExistsAtPath(file)) return null;
        try {
            const str = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, $());
            return JSON.parse(ObjC.unwrap(str));
        } catch (e) {
            return null;
        }
    }

    function readText(file) {
        if (!fm.fileExistsAtPath(file)) return "";
        try {
            return ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, $())).trim();
        } catch (e) {
            return "";
        }
    }

    function writeText(file, text) {
        const nsStr = $.NSString.stringWithString(text);
        nsStr.writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, $());
    }

    function isProcessRunning(pid) {
        if (!pid) return false;
        return ($.kill(parseInt(pid, 10), 0) === 0);
    }

    // App & Window Setup
    const app = $.NSApplication.sharedApplication;
    app.setActivationPolicy($.NSApplicationActivationPolicyRegular);
    app.finishLaunching;

    // Menu Bar Setup
    const menubar = $.NSMenu.alloc.init;
    const appMenuItem = $.NSMenuItem.alloc.init;
    menubar.addItem(appMenuItem);
    const appMenu = $.NSMenu.alloc.init;
    appMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent("Quit Habitat", "terminate:", "q"));
    appMenuItem.setSubmenu(appMenu);
    app.setMainMenu(menubar);

    const winWidth = 720;
    const winHeight = 540;
    const win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
        $.NSMakeRect(200, 200, winWidth, winHeight),
        $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable | $.NSWindowStyleMaskMiniaturizable | $.NSWindowStyleMaskResizable,
        $.NSBackingStoreBuffered,
        false
    );

    win.setTitle("🐹 Hamster Habitat");
    win.setReleasedWhenClosed(false);
    win.center;

    const contentView = win.contentView;

    // UI Helpers
    function createLabel(text, x, y, w, h, isBold, size, parent) {
        const label = $.NSTextField.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
        label.setStringValue(text || "");
        label.setBezeled(false);
        label.setDrawsBackground(false);
        label.setEditable(false);
        label.setSelectable(false);
        if (isBold) {
            label.setFont($.NSFont.boldSystemFontOfSize(size || 13));
        } else if (size) {
            label.setFont($.NSFont.systemFontOfSize(size));
        }
        (parent || contentView).addSubview(label);
        return label;
    }

    function createButton(title, x, y, w, h, parent) {
        const btn = $.NSButton.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
        btn.setTitle(title);
        btn.setBezelStyle($.NSBezelStyleRounded);
        (parent || contentView).addSubview(btn);
        return btn;
    }

    // Top Header
    createLabel("🐹 Hamster Habitat", 20, winHeight - 40, 220, 26, true, 18, contentView);
    const summaryLabel = createLabel("Loading workers…", 210, winHeight - 37, 220, 20, false, 12, contentView);
    summaryLabel.setTextColor($.NSColor.secondaryLabelColor);

    // Fleet Actions in Header
    const btnStartAll = createButton("▶ Start All", winWidth - 300, winHeight - 42, 90, 28, contentView);
    const btnStopAll = createButton("⏹ Stop All", winWidth - 205, winHeight - 42, 90, 28, contentView);
    const btnBreed = createButton("✨ Breed", winWidth - 110, winHeight - 42, 90, 28, contentView);
    btnBreed.setFont($.NSFont.boldSystemFontOfSize(12));

    // Scrollable Hamster Cards List
    const scrollList = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(15, 48, winWidth - 30, winHeight - 98));
    scrollList.setHasVerticalScroller(true);
    scrollList.setHasHorizontalScroller(false);
    scrollList.setAutohidesScrollers(true);
    scrollList.setBorderType($.NSBezelBorder);
    scrollList.setAutoresizingMask($.NSViewWidthSizable | $.NSViewHeightSizable);
    contentView.addSubview(scrollList);

    const listContainer = $.NSView.alloc.initWithFrame(scrollList.contentView.bounds);
    scrollList.setDocumentView(listContainer);

    // Footer
    const footerLabel = createLabel("Worker state is managed via state.txt. Windows can be opened on demand.", 20, 15, 480, 20, false, 11, contentView);
    footerLabel.setTextColor($.NSColor.secondaryLabelColor);

    const btnOpenAllHome = createButton("🏠 Open Hamsters Folder", winWidth - 200, 11, 185, 28, contentView);

    // -------------------------------------------------------------------------
    // Habitat State Engine
    // -------------------------------------------------------------------------
    let cachedHamsters = [];

    function scanHamsters() {
        makeDir(baseStorage);
        const dirs = listDir(baseStorage);
        const list = [];

        for (let id of dirs) {
            if (id.startsWith(".")) continue;
            const hDir = baseStorage + "/" + id;
            const cfgFile = hDir + "/config.json";
            const pidFile = hDir + "/app.pid";
            const locFile = hDir + "/location.txt";
            const stateFile = hDir + "/state.txt";

            const cfg = readJSON(cfgFile) || {};
            const stateStr = readText(stateFile);
            const isWorkerRunning = (stateStr === "RUNNING");

            let isProcessAlive = false;
            let pid = null;

            if (fm.fileExistsAtPath(pidFile)) {
                try {
                    const pStr = readText(pidFile);
                    pid = pStr;
                    isProcessAlive = isProcessRunning(pStr);
                } catch (e) {}
            }

            let scriptLoc = null;
            if (fm.fileExistsAtPath(locFile)) {
                scriptLoc = readText(locFile);
            }

            const homeDir = cfg.homeFolder || (userHome + "/Hamsters/" + (cfg.name || id).replace(/\s+/g, "_"));
            const inDir = cfg.inputFolder || (homeDir + "/inbox");
            const outDir = cfg.outputFolder || (homeDir + "/outbox");

            const inCount = listDir(inDir).filter(n => !n.startsWith(".") && !n.endsWith(".hamster_claim") && !n.endsWith(".tmp")).length;
            const outCount = listDir(outDir).filter(n => !n.startsWith(".")).length;

            list.push({
                id: id,
                name: cfg.name || ("Hamster " + id.replace("hamster-", "")),
                agent: cfg.agent || "gemini",
                homeFolder: homeDir,
                inputFolder: inDir,
                outputFolder: outDir,
                scriptPath: scriptLoc,
                isWorkerRunning: isWorkerRunning,
                isProcessAlive: isProcessAlive,
                pid: pid,
                inCount: inCount,
                outCount: outCount,
                dir: hDir,
                stateFile: stateFile
            });
        }

        list.sort((a, b) => a.name.localeCompare(b.name));
        return list;
    }

    function ensureHamsterRunning(h, autostart) {
        if (h.isProcessAlive) return;
        const targetScript = (h.scriptPath && fm.fileExistsAtPath(h.scriptPath)) ? h.scriptPath : (scriptPath.substring(0, scriptPath.lastIndexOf("/")) + "/" + h.id + ".command");
        if (fm.fileExistsAtPath(targetScript)) {
            const task = $.NSTask.alloc.init;
            task.setLaunchPath("/bin/zsh");
            const cmd = "nohup " + JSON.stringify(targetScript) + " --gui-worker " + (autostart ? "--autostart" : "") + " >/dev/null 2>&1 &";
            task.setArguments($([ "-c", cmd ]));
            task.launch;
        }
    }

    function renderHamsters() {
        const hamsters = scanHamsters();
        cachedHamsters = hamsters;

        let totalIn = 0;
        let totalOut = 0;
        let activeWorkers = 0;

        hamsters.forEach(h => {
            totalIn += h.inCount;
            totalOut += h.outCount;
            if (h.isWorkerRunning) activeWorkers++;
        });

        summaryLabel.setStringValue(hamsters.length + " Hamsters (" + activeWorkers + " processing) • 📥 " + totalIn + " • 📤 " + totalOut);

        // Clear subviews
        const subviews = listContainer.subviews;
        const subCount = subviews.count;
        for (let i = subCount - 1; i >= 0; i--) {
            subviews.objectAtIndex(i).removeFromSuperview;
        }

        const cardH = 58;
        const spacing = 6;
        const totalHeight = Math.max(scrollList.contentView.bounds.size.height, hamsters.length * (cardH + spacing) + 10);
        const listW = scrollList.contentView.bounds.size.width;

        listContainer.setFrame($.NSMakeRect(0, 0, listW, totalHeight));

        if (hamsters.length === 0) {
            const emptyLabel = createLabel("No Hamsters found. Click '✨ Breed' to create your first worker!", 20, totalHeight / 2 - 10, listW - 40, 24, false, 13, listContainer);
            emptyLabel.setAlignment($.NSTextAlignmentCenter);
            emptyLabel.setTextColor($.NSColor.secondaryLabelColor);
            return;
        }

        for (let i = 0; i < hamsters.length; i++) {
            const h = hamsters[i];
            const y = totalHeight - ((i + 1) * (cardH + spacing));

            const card = $.NSBox.alloc.initWithFrame($.NSMakeRect(10, y, listW - 20, cardH));
            card.setBoxType($.NSBoxCustom);
            card.setBorderType($.NSLineBorder);
            card.setBorderWidth(1.0);
            card.setBorderColor($.NSColor.separatorColor);
            card.setCornerRadius(8.0);
            card.setFillColor($.NSColor.controlBackgroundColor);
            listContainer.addSubview(card);

            // Status Indicator & Name
            const statusDot = h.isWorkerRunning ? "🟢" : "⚪️";
            createLabel(statusDot + " " + h.name, 12, 30, 210, 20, true, 13, card);

            // Backend & Queue Counts
            const badgeText = h.agent.toUpperCase() + "  •  📥 " + h.inCount + " in queue  •  📤 " + h.outCount + " finished";
            const badgeLabel = createLabel(badgeText, 12, 10, 270, 18, false, 11, card);
            badgeLabel.setTextColor($.NSColor.secondaryLabelColor);

            // Worker Play/Stop Button
            const toggleTitle = h.isWorkerRunning ? "⏹ Stop" : "▶ Start";
            const btnToggle = createButton(toggleTitle, listW - 295, 14, 80, 28, card);
            btnToggle.setFont($.NSFont.boldSystemFontOfSize(11));
            btnToggle.setTarget(coordinator);
            btnToggle.setAction("onCardToggleWorker:");
            btnToggle.setTag(i);

            // Action Buttons
            const btnOpenHome = createButton("📂 Home", listW - 205, 14, 75, 28, card);
            btnOpenHome.setFont($.NSFont.systemFontOfSize(11));
            btnOpenHome.setTarget(coordinator);
            btnOpenHome.setAction("onCardOpenHome:");
            btnOpenHome.setTag(i);

            const btnOpenWindow = createButton("🖥 Window", listW - 120, 14, 85, 28, card);
            btnOpenWindow.setFont($.NSFont.systemFontOfSize(11));
            btnOpenWindow.setTarget(coordinator);
            btnOpenWindow.setAction("onCardOpenWindow:");
            btnOpenWindow.setTag(i);
        }
    }

    // -------------------------------------------------------------------------
    // Habitat Coordinator
    // -------------------------------------------------------------------------
    ObjC.registerSubclass({
        name: "HabitatCoordinatorV2",
        methods: {
            "onStartAll:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    cachedHamsters.forEach(h => {
                        writeText(h.stateFile, "RUNNING");
                        ensureHamsterRunning(h, true);
                    });
                    renderHamsters();
                }
            },
            "onStopAll:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    cachedHamsters.forEach(h => {
                        writeText(h.stateFile, "STOPPED");
                    });
                    renderHamsters();
                }
            },
            "onBreed:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const currentDir = scriptPath.substring(0, scriptPath.lastIndexOf("/"));
                    const canonicalHamster = currentDir + "/hamster.command";
                    if (fm.fileExistsAtPath(canonicalHamster)) {
                        $.NSWorkspace.sharedWorkspace.openFile(canonicalHamster);
                        setTimeout(renderHamsters, 600);
                    } else {
                        summaryLabel.setStringValue("⚠️ hamster.command not found in current folder.");
                    }
                }
            },
            "onOpenAllHome:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const rootHome = userHome + "/Hamsters";
                    makeDir(rootHome);
                    $.NSWorkspace.sharedWorkspace.openFile(rootHome);
                }
            },
            "onCardToggleWorker:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const idx = sender.tag;
                    const h = cachedHamsters[idx];
                    if (h) {
                        const nextState = h.isWorkerRunning ? "STOPPED" : "RUNNING";
                        writeText(h.stateFile, nextState);
                        if (nextState === "RUNNING") {
                            ensureHamsterRunning(h, true);
                        }
                        renderHamsters();
                    }
                }
            },
            "onCardOpenHome:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const idx = sender.tag;
                    const h = cachedHamsters[idx];
                    if (h && h.homeFolder) {
                        makeDir(h.homeFolder);
                        $.NSWorkspace.sharedWorkspace.openFile(h.homeFolder);
                    }
                }
            },
            "onCardOpenWindow:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const idx = sender.tag;
                    const h = cachedHamsters[idx];
                    if (h) {
                        if (h.scriptPath && fm.fileExistsAtPath(h.scriptPath)) {
                            $.NSWorkspace.sharedWorkspace.openFile(h.scriptPath);
                        } else {
                            const currentDir = scriptPath.substring(0, scriptPath.lastIndexOf("/"));
                            const fallback = currentDir + "/" + h.id + ".command";
                            if (fm.fileExistsAtPath(fallback)) {
                                $.NSWorkspace.sharedWorkspace.openFile(fallback);
                            }
                        }
                    }
                }
            },
            "onTimerTick:": {
                types: ["void", ["id"]],
                implementation: function(timer) {
                    renderHamsters();
                }
            },
            "applicationShouldHandleReopen:hasVisibleWindows:": {
                types: ["bool", ["id", "bool"]],
                implementation: function(sender, flag) {
                    win.makeKeyAndOrderFront(null);
                    win.orderFrontRegardless;
                    app.activateIgnoringOtherApps(true);
                    return true;
                }
            },
            "windowWillClose:": {
                types: ["void", ["id"]],
                implementation: function(notification) {
                    app.terminate(null);
                }
            }
        }
    });

    const coordinator = $.HabitatCoordinatorV2.alloc.init;
    app.setDelegate(coordinator);
    win.setDelegate(coordinator);

    btnStartAll.setTarget(coordinator);
    btnStartAll.setAction("onStartAll:");

    btnStopAll.setTarget(coordinator);
    btnStopAll.setAction("onStopAll:");

    btnBreed.setTarget(coordinator);
    btnBreed.setAction("onBreed:");

    btnOpenAllHome.setTarget(coordinator);
    btnOpenAllHome.setAction("onOpenAllHome:");

    // Initial render
    renderHamsters();

    // 1.0s live heartbeat timer
    const timer = $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(
        1.0, coordinator, "onTimerTick:", null, true
    );
    $.NSRunLoop.currentRunLoop.addTimerForMode(timer, $.NSRunLoopCommonModes);

    // Show Window
    win.makeKeyAndOrderFront(null);
    win.orderFrontRegardless;
    app.activateIgnoringOtherApps(true);

    // Start Native Cocoa Run Loop
    app.run;
}
EOF
