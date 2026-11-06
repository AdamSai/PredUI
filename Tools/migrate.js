// Copies the saved data of the old standalone addons into PredUI's saved variables.
//
//   node migrate.js            (from anywhere; finds _forever_\WTF on its own)
//
// The game only loads an addon's saved variables from its own file
// (WTF\Account\<account>\SavedVariables\<Addon>.lua), so PredUI can't read
// FlightTimerDB and friends itself. This script builds PredUI.lua from them, for
// every account that has any.
//
// Run it with the game closed, or at least before PredUI's first login: the game
// rewrites PredUI.lua on logout once PredUI is loaded. A PredUI.lua that the game
// has already written is left alone unless you add --force (that would replace
// whatever PredUI has saved since).

const fs = require('fs');
const path = require('path');

const MAP = {
	FlightTimerDB: 'flight',
	CraftTimerDB: 'craft',
	BagValueDB: 'bag',
	IconSearchDB: 'icon',
	LootRoomDB: 'loot',
	MailLedgerDB: 'mail',
};
const FILES = ['FlightTimer', 'CraftTimer', 'BagValue', 'IconSearch', 'LootRoom', 'MailLedger'];
const MARKER = '-- written by PredUI\\Tools\\migrate.js';

const force = process.argv.includes('--force');
const flavorDir = path.resolve(__dirname, '..', '..', '..', '..');   // ...\_forever_
const accountsDir = path.join(flavorDir, 'WTF', 'Account');

// A saved variables file is a list of top-level "Name = value" assignments. Inner
// lines never start with an identifier followed by " = " (keys are bracketed), so
// splitting on those lines is safe.
function readAssignments(file) {
	const out = {};
	const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
	let name = null, buf = [];
	const flush = () => { if (name) out[name] = buf.join('\n').trim(); };
	for (const line of lines) {
		const m = line.match(/^([A-Za-z_]\w*) = (.*)$/);
		if (m) {
			flush();
			name = m[1];
			buf = [m[2]];
		} else if (name) {
			buf.push(line);
		}
	}
	flush();
	return out;
}

let luaparse = null;
try { luaparse = require(path.join(flavorDir, '..', 'AddonCheck', 'node_modules', 'luaparse')); } catch (e) { /* optional check */ }

let wrote = 0;
for (const account of fs.existsSync(accountsDir) ? fs.readdirSync(accountsDir) : []) {
	const svDir = path.join(accountsDir, account, 'SavedVariables');
	if (!fs.existsSync(svDir)) continue;

	const parts = [];
	for (const base of FILES) {
		const file = path.join(svDir, base + '.lua');
		if (!fs.existsSync(file)) continue;
		const vars = readAssignments(file);
		for (const [name, key] of Object.entries(MAP)) {
			if (vars[name] && vars[name] !== 'nil') parts.push({ key, value: vars[name], from: base });
		}
	}
	if (parts.length === 0) continue;

	const target = path.join(svDir, 'PredUI.lua');
	if (fs.existsSync(target) && !force && !fs.readFileSync(target, 'utf8').startsWith(MARKER)) {
		console.log(`${account}: PredUI.lua already has data from the game - skipped (use --force to replace it)`);
		continue;
	}

	let text = MARKER + '\n\nPredUIDB = {\n';
	for (const p of parts) text += `["${p.key}"] = ${p.value},\n`;
	text += '}\n';

	if (luaparse) {
		try { luaparse.parse(text); } catch (e) {
			console.log(`${account}: the result didn't parse (${e.message}) - nothing written`);
			continue;
		}
	}
	if (fs.existsSync(target)) fs.copyFileSync(target, target + '.before-migrate');
	fs.writeFileSync(target, text);
	wrote++;
	console.log(`${account}: wrote PredUI.lua from ${parts.map(p => p.from).join(', ')}`);
}
if (!wrote) console.log('nothing written.');
