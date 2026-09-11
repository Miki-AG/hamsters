const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const project = path.resolve(__dirname, '..');
const workerSource = fs.readFileSync(path.join(project, 'main.colony/hamster-founder/hamster.command'), 'utf8');
const colonySource = fs.readFileSync(path.join(project, 'main.colony/colony.command'), 'utf8');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'hamster-colonies-'));
const storage = path.join(root, 'state');
const userHome = path.join(root, 'user');
const original = path.join(root, "main colony's folder.colony");
const copied = path.join(root, 'research.colony');

function section(source, start, end) {
    const offset = source.indexOf(start);
    assert.notEqual(offset, -1, start);
    const limit = source.indexOf(end, offset);
    assert.notEqual(limit, -1, end);
    return source.slice(offset, limit);
}

function native(code) {
    const result = spawnSync('/usr/bin/osascript', ['-l', 'JavaScript', '-'], {
        input: 'ObjC.import("Cocoa");\n' + code,
        encoding: 'utf8',
        timeout: 20000
    });
    assert.equal(result.status, 0, result.stderr || String(result.error));
    return JSON.parse(result.stdout);
}

function colony(folder, action = 'scan') {
    return native(`
        const colonyDir = ${JSON.stringify(folder)};
        const baseStorage = ${JSON.stringify(storage)};
        const userHome = ${JSON.stringify(userHome)};
        const fm = $.NSFileManager.defaultManager;
        ${section(colonySource, '    function makeDir(', '    // App & Window Setup')}
        ${section(colonySource, '    function registerColonyHamsters()', '    function ensureHamsterRunning(')}
        ${action === 'register' ? 'registerColonyHamsters();' : ''}
        JSON.stringify(scanHamsters());
    `);
}

function initialize(worker) {
    const file = fs.readFileSync(worker.scriptPath, 'utf8');
    const init = section(file, 'function run(argv)', '    // App & Window Setup').replace('function run(argv)', 'function initializeWorker(argv)');
    return native(init + `
        saveConfig();
        return config;
    }
    JSON.stringify(initializeWorker(${JSON.stringify([worker.id, worker.runtimeDir || path.join(worker.dir, '.hamster'), worker.scriptPath])}));`);
}

function fleet(folder, method) {
    const start = colonySource.indexOf('"' + method + '":');
    const end = colonySource.indexOf('\n            },', start);
    const action = colonySource.slice(start, end + '\n            },'.length);
    return native(`
        const colonyDir = ${JSON.stringify(folder)};
        const baseStorage = ${JSON.stringify(storage)};
        const userHome = ${JSON.stringify(userHome)};
        const fm = $.NSFileManager.defaultManager;
        ${section(colonySource, '    function makeDir(', '    // App & Window Setup')}
        ${section(colonySource, '    function registerColonyHamsters()', '    function ensureHamsterRunning(')}
        const cachedHamsters = scanHamsters();
        function ensureHamsterRunning() {}
        function renderHamsters() {}
        const actions = {${action}};
        actions[${JSON.stringify(method)}].implementation(null);
        JSON.stringify(scanHamsters());
    `);
}

try {
    fs.mkdirSync(original);
    // Redirect only the test copies' storage, keeping the actual registration code intact.
    const testSource = workerSource
        .replace('BASE_STORAGE="$HOME/Library/Application Support/Hamsters"', 'BASE_STORAGE=' + JSON.stringify(storage))
        .replace('const userHome = "/Users/" + $.NSUserName().js;', 'const userHome = ' + JSON.stringify(userHome) + ';');
    for (const [folder, source] of [
        ['hamster-founder', testSource],
        ['hamster-second', testSource.replace(/^HAMSTER_ID=.*$/m, 'HAMSTER_ID="hamster-test-second"')]
    ]) {
        const workerDir = path.join(original, folder);
        fs.mkdirSync(path.join(workerDir, 'skills'), { recursive: true });
        fs.mkdirSync(path.join(workerDir, 'tools'), { recursive: true });
        fs.writeFileSync(path.join(workerDir, 'hamster.command'), source, { mode: 0o755 });
        fs.writeFileSync(path.join(workerDir, 'prompt.md'), 'Test prompt\n');
    }
    fs.copyFileSync(path.join(project, 'main.colony/colony.command'), path.join(original, 'colony.command'));

    const first = colony(original, 'register');
    assert.equal(first.length, 2);
    assert.equal(new Set(first.map(h => h.id)).size, 2);
    for (const h of first) {
        const config = initialize(h);
        assert.equal(h.dir, path.dirname(h.scriptPath));
        assert.equal(h.runtimeDir, path.join(h.dir, '.hamster'));
        assert.equal(config.homeFolder, h.dir);
        assert.equal(config.inputFolder, h.inputFolder);
        assert.equal(config.outputFolder, h.outputFolder);
        assert.equal(config.inputFolder, path.join(h.dir, 'input'));
        assert.equal(config.outputFolder, path.join(h.dir, 'output'));
        assert.deepEqual(config.tools, [path.join(h.dir, 'tools')]);
        assert.deepEqual(config.skills, [path.join(h.dir, 'skills')]);
        for (const asset of ['prompt.md', 'input', 'output', 'skills', 'tools', '.hamster']) {
            assert(fs.existsSync(path.join(h.dir, asset)), asset);
        }
    }
    console.log('PASS first Colony launch registers workers with matching default folders');

    const creationCode = section(colonySource, '    function createColony()', '    function registerColonyHamsters()');
    const creationAction = section(colonySource, '"onBreedColony:":', '"onStartAll:":')
        .replace('$.NSWorkspace.sharedWorkspace.openFile(newScript)', 'openCreatedColony(newScript)');
    const newScripts = native(`
        const colonyDir = ${JSON.stringify(original)};
        const scriptPath = colonyDir + "/colony.command";
        const baseStorage = ${JSON.stringify(storage)};
        const fm = $.NSFileManager.defaultManager;
        ${section(colonySource, '    function makeDir(', '    // App & Window Setup')}
        ${creationCode}
        const opened = [];
        function openCreatedColony(script) { opened.push(script); return true; }
        const actions = {${creationAction}};
        actions["onBreedColony:"].implementation(null);
        actions["onBreedColony:"].implementation(null);
        JSON.stringify(opened);
    `);
    assert.equal(new Set(newScripts).size, 2);
    const newWorkerIds = new Set(first.map(h => h.id));
    for (const script of newScripts) {
        const folder = path.dirname(script);
        assert.equal(path.dirname(folder), root);
        assert.match(path.basename(folder), /^colony-[a-f0-9]{8}\.colony$/);
        const files = fs.readdirSync(folder).sort();
        assert.equal(files.length, 2);
        assert.equal(files[0], 'colony.command');
        assert.match(files[1], /^hamster-[a-f0-9]{8}$/);
        const workerScript = path.join(folder, files[1], 'hamster.command');
        assert.equal(fs.readFileSync(script, 'utf8'), colonySource);
        assert(fs.statSync(script).mode & 0o111);
        assert(fs.statSync(workerScript).mode & 0o111);
        const workers = colony(folder, 'register');
        assert.equal(workers.length, 1);
        assert.equal(path.basename(workers[0].scriptPath), 'hamster.command');
        assert.equal(path.basename(path.dirname(workers[0].scriptPath)), workers[0].id);
        for (const asset of ['prompt.md', 'input', 'output', 'skills', 'tools']) {
            assert(fs.existsSync(path.join(folder, files[1], asset)), asset);
        }
        assert(!newWorkerIds.has(workers[0].id));
        newWorkerIds.add(workers[0].id);
        assert.equal(workers[0].isWorkerRunning, false);
        const config = initialize(workers[0]);
        assert(first.every(h => h.inputFolder !== config.inputFolder && h.outputFolder !== config.outputFolder));
    }
    assert.equal(colony(original).length, 2);
    assert(!fs.readdirSync(root).some(name => name.endsWith('.tmp')));
    console.log('PASS Breed Colony creates separate sibling colonies with one fresh executable worker each');

    const beforeFailure = fs.readdirSync(root).sort();
    const creationFailure = native(`
        const colonyDir = ${JSON.stringify(original)};
        const scriptPath = colonyDir + "/missing.command";
        const baseStorage = ${JSON.stringify(storage)};
        const fm = $.NSFileManager.defaultManager;
        ${section(colonySource, '    function makeDir(', '    // App & Window Setup')}
        ${creationCode}
        let failure = "";
        try { createColony(); } catch (error) { failure = error.message; }
        JSON.stringify(failure);
    `);
    assert.equal(creationFailure, 'Could not copy colony.command.');
    assert.deepEqual(fs.readdirSync(root).sort(), beforeFailure);
    console.log('PASS failed colony creation removes incomplete files');

    fs.cpSync(original, copied, { recursive: true });
    const second = colony(copied, 'register');
    assert.equal(second.length, 2);
    assert(second.every(h => !first.some(old => old.id === h.id)));
    assert(second.every(h => !h.isWorkerRunning));
    for (const h of second) {
        const config = initialize(h);
        assert(first.every(old => old.inputFolder !== config.inputFolder && old.outputFolder !== config.outputFolder));
    }
    assert.deepEqual(colony(original).map(h => h.id), first.map(h => h.id));
    console.log('PASS copied colony has new IDs, separate queues, and no original workers');

    assert.deepEqual(colony(copied, 'register').map(h => h.id), second.map(h => h.id));
    console.log('PASS reopening a colony preserves its registered IDs');

    const breedStart = colonySource.indexOf('"onBreed:":');
    const breedEnd = colonySource.indexOf('"onCardToggleWorker:":', breedStart);
    // Exercise file creation and chmod, replacing only the GUI launch with registration.
    const breedAction = colonySource.slice(breedStart, breedEnd)
        .replace('$.NSWorkspace.sharedWorkspace.openFile(destPath);', 'registerColonyHamsters();');
    const bred = native(`
        const colonyDir = ${JSON.stringify(copied)};
        const scriptPath = colonyDir + "/colony.command";
        const baseStorage = ${JSON.stringify(storage)};
        const userHome = ${JSON.stringify(userHome)};
        const fm = $.NSFileManager.defaultManager;
        ${section(colonySource, '    function makeDir(', '    // App & Window Setup')}
        ${section(colonySource, '    function registerColonyHamsters()', '    function ensureHamsterRunning(')}
        function renderHamsters() {}
        const actions = {${breedAction}};
        actions["onBreed:"].implementation(null);
        JSON.stringify(scanHamsters());
    `);
    assert.equal(bred.length, 3);
    assert.equal(colony(original).length, 2);
    for (const h of bred) {
        assert(fs.statSync(h.scriptPath).mode & 0o111);
        initialize(h);
    }
    console.log('PASS Breed creates an executable worker in its own colony');

    const idNamedColony = path.dirname(newScripts[0]);
    assert(!fs.existsSync(path.join(idNamedColony, 'hamster.command')));
    const descendantScript = native(`
        const colonyDir = ${JSON.stringify(idNamedColony)};
        const scriptPath = colonyDir + "/colony.command";
        const baseStorage = ${JSON.stringify(storage)};
        const fm = $.NSFileManager.defaultManager;
        ${section(colonySource, '    function makeDir(', '    // App & Window Setup')}
        ${creationCode}
        JSON.stringify(createColony());
    `);
    const descendantWorkers = colony(path.dirname(descendantScript), 'register');
    assert.equal(descendantWorkers.length, 1);
    assert.equal(path.basename(descendantWorkers[0].scriptPath), 'hamster.command');
    assert(!newWorkerIds.has(descendantWorkers[0].id));
    console.log('PASS colony with an ID-named worker can breed another colony');

    const additionalWorkers = native(`
        const colonyDir = ${JSON.stringify(idNamedColony)};
        const scriptPath = colonyDir + "/colony.command";
        const baseStorage = ${JSON.stringify(storage)};
        const userHome = ${JSON.stringify(userHome)};
        const fm = $.NSFileManager.defaultManager;
        ${section(colonySource, '    function makeDir(', '    // App & Window Setup')}
        ${section(colonySource, '    function registerColonyHamsters()', '    function ensureHamsterRunning(')}
        function renderHamsters() {}
        const actions = {${breedAction}};
        actions["onBreed:"].implementation(null);
        JSON.stringify(scanHamsters());
    `);
    assert.equal(additionalWorkers.length, 2);
    assert.equal(new Set(additionalWorkers.map(h => h.id)).size, 2);
    for (const h of additionalWorkers) {
        assert.equal(path.basename(h.scriptPath), 'hamster.command');
        assert.equal(path.basename(path.dirname(h.scriptPath)), h.id);
    }
    assert(!fs.existsSync(path.join(idNamedColony, 'hamster.command')));
    console.log('PASS colony with ID-named workers can breed another worker');

    fleet(copied, 'onStartAll:');
    assert(colony(copied).every(h => h.isWorkerRunning));
    assert(colony(original).every(h => !h.isWorkerRunning));
    fleet(original, 'onStopAll:');
    assert(colony(copied).every(h => h.isWorkerRunning));
    fleet(copied, 'onStopAll:');
    assert(colony(copied).every(h => !h.isWorkerRunning));
    console.log('PASS fleet state controls affect only their colony');

    const moved = path.join(root, 'renamed colony');
    fs.renameSync(copied, moved);
    const afterMove = colony(moved, 'register');
    assert.deepEqual(afterMove.map(h => h.id), bred.map(h => h.id));
    assert.deepEqual(afterMove.map(h => h.inputFolder), bred.map(h => h.inputFolder));
    assert.equal(colony(copied).length, 0);
    console.log('PASS moving a colony preserves IDs and configured working folders');

    const moving = afterMove[0];
    const movingDir = path.dirname(moving.scriptPath);
    const targetDir = path.join(original, 'moved-' + moving.id);
    const target = path.join(targetDir, 'hamster.command');
    fs.renameSync(movingDir, targetDir);
    const imported = colony(original, 'register');
    assert(imported.some(h => h.id === moving.id && h.scriptPath === target));
    assert.equal(colony(moved).length, 2);
    console.log('PASS moving one worker changes colony membership without cloning it');

    const unopened = path.join(root, 'unopened');
    const unopenedCopy = path.join(root, 'unopened copy');
    fs.mkdirSync(unopened);
    fs.mkdirSync(path.join(unopened, 'hamster-founder'));
    fs.writeFileSync(path.join(unopened, 'hamster-founder', 'hamster.command'),
        testSource.replace(/^HAMSTER_ID=.*$/m, 'HAMSTER_ID="HAMSTER_ID_PLACEHOLDER"'), { mode: 0o755 });
    fs.cpSync(unopened, unopenedCopy, { recursive: true });
    const unopenedWorkers = colony(unopened, 'register');
    const unopenedCopyWorkers = colony(unopenedCopy, 'register');
    assert.equal(unopenedWorkers.length, 1);
    assert.equal(unopenedCopyWorkers.length, 1);
    assert.notEqual(unopenedWorkers[0].id, unopenedCopyWorkers[0].id);
    console.log('PASS colonies copied before their first launch also get separate identities');
} finally {
    fs.rmSync(root, { recursive: true, force: true });
}
