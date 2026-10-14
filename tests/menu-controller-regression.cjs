// Runs the actual shell.qml JavaScript functions; no Qt/device runtime required.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../qml/shell.qml'), 'utf8');
const functions = source.match(/^    function \w+\([^\n]*\) \{[^\n]*\}$|^    function \w+\([^\n]*\) \{[\s\S]*?^    \}/gm);
assert.equal(functions.length, 25, 'all root functions must be exercised from the real source');
let checks = 0;
function fixture(page = '') {
  const state = {root:null, storefrontId:"", storeGeneration:"0", storeGame:false, pendingStoreAction:null, storeAction:{running:false}, storeNotice:"", storeResultReceived:false, menuGeneration:0, menuInstance:'test', sessionAction:'exit-game', exitBusy:false, exitResultReceived:false, exitNotice:'', sessionActionPath:'/test/action.py', exitAction:{running:false}, exitPage:{move:()=>{}, activate:()=>{}}, menuOpen:true, opening:false, ready:true, closing:false, helperIdle:false, lastReadyMs:-1, lastVisibleMs:-1, openStartedMs:0, page, selected:0, mainSelected:0,
    entryPhase:'hidden', firstFrameMs:-1, slideFinishedMs:-1,
    panel:{entryProgress:0, width:700, height:1028}, overlay:{width:1920,height:1080,backingWindowVisible:true},
    slideIn:{starts:0,stop:()=>{},restart:()=>state.slideIn.starts++},
    settingsSelected:0, returnPage:'settings', pressed:{}, heldDirection:0, controllerWarning:'',
    controllerCount:1, controllerDevices:[], foreground:'game', displaySupported:true,
    warnings:[], writes:[], quit:0, actions:[],
    console:{warn:()=>{}, error:()=>{}, info:()=>{}}, Qt:{quit:()=>state.quit++, formatDateTime:()=> '7:00 PM'},
    bridge:{running:true, write:value=>state.writes.push(JSON.parse(value))},
    repeatDelay:{stop:()=>{}, restart:()=>{}}, repeatStep:{stop:()=>{}, start:()=>{}},
    menuList:{positionViewAtIndex:()=>{}}, ListView:{Contain:0},
    bluetoothPageLoader:{item:null}, networkPageLoader:{item:null}, audioPageLoader:{item:null},
    controllersPage:{move:()=>{}, activate:()=>{}},
    displayPage:{receive:()=>state.actions.push('display'), back:()=>state.actions.push('back'),
      activate:()=>{}, horizontal:()=>{}, move:()=>{}},
    mainEntries:[{key:'resume'}, {key:'settings'}], settingsEntries:[{key:'controllers'}]};
  Object.defineProperties(state, {
    listPage:{get:()=>state.page === '' || state.page === 'settings' || state.page === 'storefronts'},
    navigationPage:{get:()=>true}, entries:{get:()=>state.page === 'settings' ? state.settingsEntries : state.mainEntries}
  });
  state.root=state;
  vm.createContext(state); vm.runInContext(functions.join('\n'), state);
  return state;
}
function staysOpen(state, originalPage) {
  assert.equal(state.menuOpen,true); assert.equal(state.closing,false);
  assert.equal(state.quit,0); assert.equal(state.page,originalPage);
  assert.equal(state.writes.filter(x=>x.action === 'close').length,0); checks++;
}
for (const page of ['', 'settings', 'controllers', 'audio', 'network', 'bluetooth', 'display', 'appearance', 'exit', 'reboot', 'shutdown', 'storefronts', 'store-close']) {
  const state = fixture(page);
  state.heldDirection = -1; state.pressed = {ui_up:true};
  for (let i=0; i<20; i++) {
    state.receive(JSON.stringify({type:'input-reset'}));
    state.receive(JSON.stringify({type:'warning', message:'service/ownership/transport/disconnect failure'}));
    state.receive(JSON.stringify({type:'controllers', controllers:0, devices:[]}));
    staysOpen(state,page);
    assert.equal(state.heldDirection,0); assert.equal(Object.keys(state.pressed).length,0);
  }
  for (const event of ['ui_accept','ui_back','ui_cancel','ui_left','ui_right','ui_up','ui_down','ui_guide']) {
    state.input(event,0); staysOpen(state,page);
    for (const value of [NaN, Infinity, -Infinity, '1', null]) {
      state.input(event,value); staysOpen(state,page);
    }
  }
  state.receive(JSON.stringify({type:'controller-recovered'}));
  assert.equal(state.controllerWarning,''); staysOpen(state,page);
}
// Reconnection retains the current page and restores usable navigation.
const recovered = fixture();
recovered.receive(JSON.stringify({type:'input-reset'}));
recovered.receive(JSON.stringify({type:'controllers', controllers:1, devices:[{id:'new'}]}));
recovered.input('ui_down',1); assert.equal(recovered.selected,1); staysOpen(recovered,'');
// Deliberate user close actions are explicitly preserved.
for (const action of [state=>state.input('ui_back',1), state=>state.input('ui_accept',1), state=>state.back()]) {
  const state = fixture(); action(state);
  assert.equal(state.menuOpen,false); assert.equal(state.closing,true);
  assert.equal(state.writes.filter(x=>x.action === 'close').length,1); checks++;
}
console.log(`PASS: ${checks} menu lifecycle/navigation assertions using actual QML functions.`);
module.exports = {fixture, source};
