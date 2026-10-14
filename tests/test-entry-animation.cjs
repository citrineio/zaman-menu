// Exercise the real QML lifecycle and position expression through changing geometry.
const assert = require('node:assert/strict');
const vm = require('node:vm');
const {fixture, source} = require('./menu-controller-regression.cjs');
const position = source.match(/^            x: (offscreenX .*entryProgress)$/m)[1];
const offscreen = source.match(/readonly property real offscreenX: ([^\n]+)/)[1];
let checks = 0;
for (const scale of [0.65, 1, 1.4]) {
  for (const width of [0, 1, 455, 700, 980]) {
    const geometry = {width, root:{px:n=>Math.round(n*scale)}, entryProgress:0};
    vm.createContext(geometry);
    geometry.offscreenX = vm.runInContext(offscreen, geometry);
    assert.ok(vm.runInContext(position, geometry) + width + 5*scale <= 0,
      'panel and shadows must remain entirely outside the left edge at any width');
    geometry.entryProgress = 1;
    assert.equal(vm.runInContext(position, geometry), Math.round(28*scale));
    checks += 2;
  }
}
for (let cycle=0; cycle<50; cycle++) {
  const s = fixture();
  s.menuOpen=false; s.helperIdle=true;
  s.panel.entryProgress=1;
  s.openMenu();
  assert.equal(s.panel.entryProgress,0);
  s.receive(JSON.stringify({type:'ready',foreground:'storefront',storefront:'dukkan',controllers:1}));
  assert.equal(s.entryPhase,'await-frame');
  assert.equal(s.slideIn.starts,0);
  assert.equal(s.writes.filter(x=>x.action==='opened').length,0);
  s.panel.width=0; s.startEntryFrame();
  assert.equal(s.slideIn.starts,0);
  s.panel.width=700; s.overlay.backingWindowVisible=false; s.startEntryFrame();
  assert.equal(s.slideIn.starts,0);
  s.overlay.backingWindowVisible=true; s.startEntryFrame();
  assert.equal(s.slideIn.starts,1);
  assert.equal(s.entryPhase,'sliding');
  assert.equal(s.writes.filter(x=>x.action==='opened').length,1);
  s.startEntryFrame();
  assert.equal(s.slideIn.starts,1,'subsequent frames must not restart animation');
  s.receive(JSON.stringify({type:'input-reset'}));
  assert.equal(s.entryPhase,'sliding','controller recovery must not restart presentation');
  s.closeMenu(); s.startEntryFrame();
  assert.equal(s.entryPhase,'hidden');
  assert.equal(s.panel.entryProgress,0);
  assert.equal(s.slideIn.starts,1,'late frames must not reopen a closed menu');
  checks += 14;
}
const cancelled = fixture();
cancelled.entryPhase='await-frame'; cancelled.closeMenu(); cancelled.startEntryFrame();
assert.equal(cancelled.slideIn.starts,0);
assert.equal(cancelled.writes.filter(x=>x.action==='opened').length,0);
assert.match(source,/target: panel\.Window\.window[\s\S]*?onFrameSwapped\(\)/);
console.log(`PASS: ${checks + 3} entry geometry/lifecycle assertions using actual QML source.`);
