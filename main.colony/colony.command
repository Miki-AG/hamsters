#!/bin/bash
# ==============================================================================
# 🐹 HAMSTER COLONY - Minimalist Master Fleet Dashboard
# ==============================================================================
# - Auto-discovers all local Hamsters.
# - Decoupled state: starts/stops workers headlessly without opening windows.
# - Clean, minimalist list: each item shows queue/finished stats, Start/Stop, and Open.
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
# Launch Colony GUI
# ------------------------------------------------------------------------------
exec /usr/bin/osascript -l JavaScript - "$SCRIPT_PATH" << 'EOF'
function run(argv) {
    ObjC.import("Cocoa");

    const scriptPath = argv[0];
    const colonyDir = scriptPath.substring(0, scriptPath.lastIndexOf("/"));
    const colonyName = colonyDir.substring(colonyDir.lastIndexOf("/") + 1);
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

    function isErrorFile(filename) {
        return String(filename).toLowerCase().endsWith(".error");
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

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'";
    }

    function isProcessRunning(pid) {
        if (!pid) return false;
        return ($.kill(parseInt(pid, 10), 0) === 0);
    }

    function workerTemplatePath() {
        const names = listDir(colonyDir).filter(name => name === "hamster.command" || /^hamster-.+\.command$/.test(name)).sort();
        if (names.includes("hamster.command")) return colonyDir + "/hamster.command";
        return names.length > 0 ? colonyDir + "/" + names[0] : null;
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
    appMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent("Quit Colony", "terminate:", "q"));
    appMenuItem.setSubmenu(appMenu);
    app.setMainMenu(menubar);

    const winWidth = 640;
    const winHeight = 500;
    const win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
        $.NSMakeRect(200, 200, winWidth, winHeight),
        $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable | $.NSWindowStyleMaskMiniaturizable,
        $.NSBackingStoreBuffered,
        false
    );

    win.setTitle("🐹 Hamster Colony: " + colonyName);
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
    createLabel("🐹 Hamster Colony", 20, winHeight - 38, 200, 26, true, 17, contentView);
    const summaryLabel = createLabel("Loading workers…", 195, winHeight - 35, 150, 20, false, 11, contentView);
    summaryLabel.setTextColor($.NSColor.secondaryLabelColor);

    // Fleet Actions in Header
    const btnStartAll = createButton("Start All", winWidth - 280, winHeight - 40, 85, 28, contentView);
    const btnStopAll = createButton("⏹ Stop All", winWidth - 190, winHeight - 40, 85, 28, contentView);
    const btnBreed = createButton("✨ Breed", winWidth - 100, winHeight - 40, 85, 28, contentView);
    btnBreed.setFont($.NSFont.boldSystemFontOfSize(12));

    const btnBreedColony = createButton("✨ Breed Colony", 15, 15, 160, 30, contentView);

    // Scrollable Hamster Cards List
    const scrollList = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(15, 60, winWidth - 30, winHeight - 110));
    scrollList.setHasVerticalScroller(true);
    scrollList.setHasHorizontalScroller(false);
    scrollList.setAutohidesScrollers(true);
    scrollList.setBorderType($.NSBezelBorder);
    scrollList.setAutoresizingMask($.NSViewWidthSizable | $.NSViewHeightSizable);
    contentView.addSubview(scrollList);

    const listContainer = $.NSView.alloc.initWithFrame(scrollList.contentView.bounds);
    scrollList.setDocumentView(listContainer);

    // -------------------------------------------------------------------------
    // Colony State Engine
    // -------------------------------------------------------------------------
    let cachedHamsters = [];

    function createColony() {
        const templatePath = workerTemplatePath();
        if (!templatePath) throw new Error("No Hamster script found in this colony.");
        const source = $.NSString.stringWithContentsOfFileEncodingError(templatePath, $.NSUTF8StringEncoding, $());
        if (source.isNil()) throw new Error("Hamster script is unreadable.");
        const template = ObjC.unwrap(source);
        if (!/^HAMSTER_ID="[^"]*"/m.test(template)) throw new Error("Hamster script has no worker ID.");

        const parentDir = colonyDir.substring(0, colonyDir.lastIndexOf("/"));
        let newColonyDir;
        do {
            const id = $.NSUUID.UUID.UUIDString.js.toLowerCase().substring(0, 8);
            newColonyDir = parentDir + "/colony-" + id + ".colony";
        } while (fm.fileExistsAtPath(newColonyDir) || fm.fileExistsAtPath(newColonyDir + ".tmp"));

        let workerId;
        do {
            workerId = "hamster-" + $.NSUUID.UUID.UUIDString.js.toLowerCase().substring(0, 8);
        } while (fm.fileExistsAtPath(baseStorage + "/" + workerId));

        const stagingDir = newColonyDir + ".tmp";
        const workerPath = stagingDir + "/" + workerId + ".command";
        if (!fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(stagingDir, false, $(), $())) {
            throw new Error("Could not create a colony beside this folder.");
        }
        try {
            if (!fm.copyItemAtPathToPathError(scriptPath, stagingDir + "/colony.command", $())) {
                throw new Error("Could not copy colony.command.");
            }
            const code = template.replace(/^HAMSTER_ID="[^"]*"/m, 'HAMSTER_ID="' + workerId + '"');
            if (!$.NSString.stringWithString(code).writeToFileAtomicallyEncodingError(workerPath, true, $.NSUTF8StringEncoding, $())) {
                throw new Error("Could not create the colony's Hamster script.");
            }
            const chmod = $.NSTask.alloc.init;
            chmod.setLaunchPath("/bin/chmod");
            chmod.setArguments($(["+x", stagingDir + "/colony.command", workerPath]));
            chmod.launch;
            chmod.waitUntilExit;
            if (chmod.terminationStatus !== 0) throw new Error("Could not make the colony scripts executable.");
            if (!fm.moveItemAtPathToPathError(stagingDir, newColonyDir, $())) {
                throw new Error("Could not finish creating the colony.");
            }
        } catch (error) {
            fm.removeItemAtPathError(stagingDir, $());
            throw error;
        }
        return newColonyDir + "/colony.command";
    }

    function registerColonyHamsters() {
        for (let name of listDir(colonyDir)) {
            if (name !== "hamster.command" && !/^hamster-.+\.command$/.test(name)) continue;
            const task = $.NSTask.alloc.init;
            task.setLaunchPath("/bin/bash");
            task.setArguments($([colonyDir + "/" + name, "--register"]));
            task.launch;
            task.waitUntilExit;
            if (task.terminationStatus !== 0) {
                throw new Error("Could not register " + name);
            }
        }
    }

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
            const scriptLoc = readText(locFile);
            if (scriptLoc.substring(0, scriptLoc.lastIndexOf("/")) !== colonyDir || !fm.fileExistsAtPath(scriptLoc)) continue;

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

            const homeDir = cfg.homeFolder || (userHome + "/Hamsters/" + (cfg.name || ("Hamster " + id.replace("hamster-", ""))).replace(/\s+/g, "_"));
            const inDir = cfg.inputFolder || (homeDir + "/inbox");
            const outDir = cfg.outputFolder || (homeDir + "/outbox");

            const inCount = listDir(inDir).filter(n => !n.startsWith(".") && !n.endsWith(".hamster_claim") && !n.endsWith(".tmp") && !isErrorFile(n)).length;
            const outItems = listDir(outDir).filter(n => !n.startsWith("."));
            const outCount = outItems.filter(n => !isErrorFile(n)).length;
            const errorCount = outItems.filter(n => isErrorFile(n)).length;

            list.push({
                id: id,
                name: cfg.displayName || cfg.name || ("Hamster " + id.replace("hamster-", "")),
                homeFolder: homeDir,
                inputFolder: inDir,
                outputFolder: outDir,
                scriptPath: scriptLoc,
                isWorkerRunning: isWorkerRunning,
                isProcessAlive: isProcessAlive,
                pid: pid,
                inCount: inCount,
                outCount: outCount,
                errorCount: errorCount,
                dir: hDir,
                stateFile: stateFile
            });
        }

        list.sort((a, b) => a.name.localeCompare(b.name));
        return list;
    }

    function ensureHamsterRunning(h) {
        if (h.isProcessAlive) return;
        const targetScript = (h.scriptPath && fm.fileExistsAtPath(h.scriptPath)) ? h.scriptPath : (scriptPath.substring(0, scriptPath.lastIndexOf("/")) + "/" + h.id + ".command");
        if (fm.fileExistsAtPath(targetScript)) {
            const task = $.NSTask.alloc.init;
            task.setLaunchPath("/bin/zsh");
            const cmd = "nohup " + shellQuote(targetScript) + " --gui-worker --headless >/dev/null 2>&1 &";
            task.setArguments($([ "-c", cmd ]));
            task.launch;
        }
    }

    function renderHamsters() {
        const hamsters = scanHamsters();
        cachedHamsters = hamsters;

        let activeWorkers = 0;

        hamsters.forEach(h => {
            if (h.isWorkerRunning) activeWorkers++;
        });

        summaryLabel.setStringValue(hamsters.length + " Hamsters (" + activeWorkers + " active)");

        // Clear subviews
        const subviews = listContainer.subviews;
        const subCount = subviews.count;
        for (let i = subCount - 1; i >= 0; i--) {
            subviews.objectAtIndex(i).removeFromSuperview;
        }

        const cardH = 74;
        const spacing = 8;
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
            const cardW = listW - 20;

            const card = $.NSBox.alloc.initWithFrame($.NSMakeRect(10, y, cardW, cardH));
            card.setBoxType($.NSBoxCustom);
            card.setBorderType($.NSLineBorder);
            card.setBorderWidth(1.0);
            card.setBorderColor($.NSColor.separatorColor);
            card.setCornerRadius(8.0);
            card.setFillColor($.NSColor.controlBackgroundColor);
            listContainer.addSubview(card);

            // Left Side: In Queue Stat (Icon / Large Number / Subtitle) - Tight Spacing
            createLabel("📥", 16, 19, 28, 36, false, 22, card);
            const inCountLabel = createLabel("" + h.inCount, 46, 17, 36, 40, true, 30, card);
            inCountLabel.setTextColor($.NSColor.systemBlueColor);
            const inSub = createLabel("in queue", 82, 25, 60, 20, false, 11, card);
            inSub.setTextColor($.NSColor.secondaryLabelColor);

            // Left Side: Finished Stat (Icon / Large Number / Subtitle) - Tight Spacing
            createLabel("📤", 155, 19, 28, 36, false, 22, card);
            const outCountLabel = createLabel("" + h.outCount, 185, 17, 36, 40, true, 30, card);
            outCountLabel.setTextColor($.NSColor.systemGreenColor);
            const outSub = createLabel("finished", 221, 25, 60, 20, false, 11, card);
            outSub.setTextColor($.NSColor.secondaryLabelColor);
            const errorSub = createLabel(h.errorCount + " errors", 221, 7, 70, 16, false, 10, card);
            errorSub.setTextColor(h.errorCount > 0 ? $.NSColor.systemRedColor : $.NSColor.secondaryLabelColor);

            // Right Column: Name on Top (12px top margin), Buttons Below (12px bottom margin)
            const statusDot = h.isWorkerRunning ? "🟢" : "⚪️";
            createLabel(statusDot + " " + h.name, cardW - 195, 42, 185, 20, true, 13, card);

            const toggleTitle = h.isWorkerRunning ? "⏹ Stop" : "▶ Start";
            const btnToggle = createButton(toggleTitle, cardW - 195, 12, 88, 26, card);
            btnToggle.setFont($.NSFont.boldSystemFontOfSize(11));
            btnToggle.setTarget(coordinator);
            btnToggle.setAction("onCardToggleWorker:");
            btnToggle.setTag(i);

            const btnOpenWindow = createButton("🖥 Open", cardW - 100, 12, 88, 26, card);
            btnOpenWindow.setFont($.NSFont.systemFontOfSize(11));
            btnOpenWindow.setTarget(coordinator);
            btnOpenWindow.setAction("onCardOpenWindow:");
            btnOpenWindow.setTag(i);
        }
    }

    // -------------------------------------------------------------------------
    // Colony Coordinator
    // -------------------------------------------------------------------------
    ObjC.registerSubclass({
        name: "ColonyCoordinatorV3",
        methods: {
            "onBreedColony:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    try {
                        const newScript = createColony();
                        if (!$.NSWorkspace.sharedWorkspace.openFile(newScript)) {
                            throw new Error("Colony created. Open it at " + newScript);
                        }
                    } catch (error) {
                        const alert = $.NSAlert.alloc.init;
                        alert.setMessageText("Could not open the new colony");
                        alert.setInformativeText(String(error.message || error));
                        alert.runModal;
                    }
                }
            },
            "onStartAll:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    cachedHamsters.forEach(h => {
                        writeText(h.stateFile, "RUNNING");
                        ensureHamsterRunning(h);
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
                    const templatePath = workerTemplatePath();
                    if (templatePath) {
                        const newId = "hamster-" + Math.random().toString(36).substring(2, 10);
                        const destPath = currentDir + "/" + newId + ".command";
                        const source = $.NSString.stringWithContentsOfFileEncodingError(templatePath, $.NSUTF8StringEncoding, $());
                        const code = ObjC.unwrap(source).replace(/HAMSTER_ID="[^"]*"/, 'HAMSTER_ID="' + newId + '"');
                        $.NSString.stringWithString(code).writeToFileAtomicallyEncodingError(destPath, true, $.NSUTF8StringEncoding, $());
                        const chmod = $.NSTask.alloc.init;
                        chmod.setLaunchPath("/bin/chmod");
                        chmod.setArguments($([ "+x", destPath ]));
                        chmod.launch;
                        chmod.waitUntilExit;
                        $.NSWorkspace.sharedWorkspace.openFile(destPath);
                        renderHamsters();
                    } else {
                        summaryLabel.setStringValue("⚠️ No Hamster script found in this colony.");
                    }
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
                            ensureHamsterRunning(h);
                        }
                        renderHamsters();
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

    const coordinator = $.ColonyCoordinatorV3.alloc.init;
    app.setDelegate(coordinator);
    win.setDelegate(coordinator);

    btnStartAll.setTarget(coordinator);
    btnStartAll.setAction("onStartAll:");

    btnStopAll.setTarget(coordinator);
    btnStopAll.setAction("onStopAll:");

    btnBreed.setTarget(coordinator);
    btnBreed.setAction("onBreed:");

    btnBreedColony.setTarget(coordinator);
    btnBreedColony.setAction("onBreedColony:");

    // Initial render
    registerColonyHamsters();
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
