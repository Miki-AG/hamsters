const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const project = path.resolve(__dirname, '..');
const workerSource = fs.readFileSync(path.join(project, 'main-colony/hamster.command'), 'utf8');
const habitatSource = fs.readFileSync(path.join(project, 'main-colony/habitat.command'), 'utf8');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'hamster-colonies-'));
const storage = path.join(root, 'state');
const userHome = path.join(root, 'user');
const original = path.join(root, "main colony's folder");
const copied = path.join(root, 'research colony');

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

function habitat(folder, action = 'scan') {
    return native(`
        const colonyDir = ${JSON.stringify(folder)};
        const baseStorage = ${JSON.stringify(storage)};
        const userHome = ${JSON.stringify(userHome)};
        const fm = $.NSFileManager.defaultManager;
        ${section(habitatSource, '    function makeDir(', '    // App & Window Setup')}
        ${section(habitatSource, '    function registerColonyHamsters()', '    function ensureHamsterRunning(')}
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
    JSON.stringify(initializeWorker(${JSON.stringify([worker.id, worker.dir, worker.scriptPath])}));`);
}

function fleet(folder, method) {
    const start = habitatSource.indexOf('"' + method + '":');
    const end = habitatSource.indexOf('\n            },', start);
    const action = habitatSource.slice(start, end + '\n            },'.length);
    return native(`
        const colonyDir = ${JSON.stringify(folder)};
        const baseStorage = ${JSON.stringify(storage)};
        const userHome = ${JSON.stringify(userHome)};
        const fm = $.NSFileManager.defaultManager;
        ${section(habitatSource, '    function makeDir(', '    // App & Window Setup')}
        ${section(habitatSource, '    function registerColonyHamsters()', '    function ensureHamsterRunning(')}
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
    fs.writeFileSync(path.join(original, 'hamster.command'), testSource, { mode: 0o755 });
    fs.writeFileSync(path.join(original, 'hamster-second.command'),
        testSource.replace(/^HAMSTER_ID=.*$/m, 'HAMSTER_ID="hamster-test-second"'), { mode: 0o755 });
    fs.copyFileSync(path.join(project, 'main-colony/habitat.command'), path.join(original, 'habitat.command'));

    const first = habitat(original, 'register');
    assert.equal(first.length, 2);
    assert.equal(new Set(first.map(h => h.id)).size, 2);
    for (const h of first) {
        const config = initialize(h);
        assert.equal(config.inputFolder, h.inputFolder);
        assert.equal(config.outputFolder, h.outputFolder);
    }
    console.log('PASS first Habitat launch registers workers with matching default folders');

    fs.cpSync(original, copied, { recursive: true });
    const second = habitat(copied, 'register');
    assert.equal(second.length, 2);
    assert(second.every(h => !first.some(old => old.id === h.id)));
    assert(second.every(h => !h.isWorkerRunning));
    for (const h of second) {
        const config = initialize(h);
        assert(first.every(old => old.inputFolder !== config.inputFolder && old.outputFolder !== config.outputFolder));
    }
    assert.deepEqual(habitat(original).map(h => h.id), first.map(h => h.id));
    console.log('PASS copied colony has new IDs, separate queues, and no original workers');

    assert.deepEqual(habitat(copied, 'register').map(h => h.id), second.map(h => h.id));
    console.log('PASS reopening a colony preserves its registered IDs');

    const breedStart = habitatSource.indexOf('"onBreed:":');
    const breedEnd = habitatSource.indexOf('"onCardToggleWorker:":', breedStart);
    // Exercise file creation and chmod, replacing only the GUI launch with registration.
    const breedAction = habitatSource.slice(breedStart, breedEnd)
        .replace('$.NSWorkspace.sharedWorkspace.openFile(destPath);', 'registerColonyHamsters();');
    const bred = native(`
        const colonyDir = ${JSON.stringify(copied)};
        const scriptPath = colonyDir + "/habitat.command";
        const baseStorage = ${JSON.stringify(storage)};
        const userHome = ${JSON.stringify(userHome)};
        const fm = $.NSFileManager.defaultManager;
        ${section(habitatSource, '    function makeDir(', '    // App & Window Setup')}
        ${section(habitatSource, '    function registerColonyHamsters()', '    function ensureHamsterRunning(')}
        function renderHamsters() {}
        const actions = {${breedAction}};
        actions["onBreed:"].implementation(null);
        JSON.stringify(scanHamsters());
    `);
    assert.equal(bred.length, 3);
    assert.equal(habitat(original).length, 2);
    for (const h of bred) {
        assert(fs.statSync(h.scriptPath).mode & 0o111);
        initialize(h);
    }
    console.log('PASS Breed creates an executable worker in its own colony');

    fleet(copied, 'onStartAll:');
    assert(habitat(copied).every(h => h.isWorkerRunning));
    assert(habitat(original).every(h => !h.isWorkerRunning));
    fleet(original, 'onStopAll:');
    assert(habitat(copied).every(h => h.isWorkerRunning));
    fleet(copied, 'onStopAll:');
    assert(habitat(copied).every(h => !h.isWorkerRunning));
    console.log('PASS fleet state controls affect only their colony');

    const moved = path.join(root, 'renamed colony');
    fs.renameSync(copied, moved);
    const afterMove = habitat(moved, 'register');
    assert.deepEqual(afterMove.map(h => h.id), bred.map(h => h.id));
    assert.deepEqual(afterMove.map(h => h.inputFolder), bred.map(h => h.inputFolder));
    assert.equal(habitat(copied).length, 0);
    console.log('PASS moving a colony preserves IDs and configured working folders');

    const moving = afterMove[0];
    const target = path.join(original, 'hamster-moved.command');
    fs.renameSync(moving.scriptPath, target);
    const imported = habitat(original, 'register');
    assert(imported.some(h => h.id === moving.id && h.scriptPath === target));
    assert.equal(habitat(moved).length, 2);
    console.log('PASS moving one worker changes colony membership without cloning it');

    const unopened = path.join(root, 'unopened');
    const unopenedCopy = path.join(root, 'unopened copy');
    fs.mkdirSync(unopened);
    fs.writeFileSync(path.join(unopened, 'hamster.command'),
        testSource.replace(/^HAMSTER_ID=.*$/m, 'HAMSTER_ID="HAMSTER_ID_PLACEHOLDER"'), { mode: 0o755 });
    fs.cpSync(unopened, unopenedCopy, { recursive: true });
    const unopenedWorkers = habitat(unopened, 'register');
    const unopenedCopyWorkers = habitat(unopenedCopy, 'register');
    assert.equal(unopenedWorkers.length, 1);
    assert.equal(unopenedCopyWorkers.length, 1);
    assert.notEqual(unopenedWorkers[0].id, unopenedCopyWorkers[0].id);
    console.log('PASS colonies copied before their first launch also get separate identities');
} finally {
    fs.rmSync(root, { recursive: true, force: true });
}
