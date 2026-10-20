'use strict';

// All peer, grant, availability and publishing behavior here is a design simulation.
// Imported files stay in this browser tab. This prototype has no transport adapter.
const icons = {
  vault: '<path d="M5 4h14v16H5zM8 4V2h8v2M9 10l3 5 3-5M8 20v2m8-2v2"/>',
  library: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M8 9v11"/>',
  people: '<circle cx="9" cy="8" r="3"/><path d="M3 20v-2a6 6 0 0112 0v2m1-15a3 3 0 010 6m2 3a5 5 0 013 4v2"/>',
  activity: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
  settings: '<path d="M10 3h4l1 3 3 1 3 3v4l-3 3-3 1-1 3h-4l-1-3-3-1-3-3v-4l3-3 3-1z"/><circle cx="12" cy="12" r="3"/>',
  folder: '<path d="M3 7V5a2 2 0 012-2h5l2 3h7a2 2 0 012 2v11H3z"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  arrow: '<path d="M4 12h16m-6-6 6 6-6 6"/>',
  back: '<path d="M20 12H4m6-6-6 6 6 6"/>',
  shield: '<path d="M12 2l8 4v6c0 5-8 10-8 10S4 17 4 12V6z"/><path d="M8 12l3 3 5-6"/>',
  lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V6a4 4 0 018 0v4"/>',
  search: '<circle cx="10" cy="10" r="6"/><path d="M15 15l5 5"/>',
  grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.1M3 12h.1M3 18h.1"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8" cy="8" r="1"/><path d="M3 17l6-6 4 4 3-3 5 5"/>',
  video: '<rect x="3" y="5" width="13" height="14" rx="2"/><path d="M16 10l5-3v10l-5-3"/>',
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  monitor: '<rect x="3" y="3" width="18" height="13" rx="2"/><path d="M12 16v5m-5 0h10"/>',
  phone: '<rect x="6" y="2" width="12" height="20" rx="2"/><path d="M10 18h4"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/>',
  moon: '<path d="M21 13a9 9 0 11-10-10 7 7 0 0010 10z"/>',
  close: '<path d="M6 6l12 12M6 18L18 6"/>',
  check: '<path d="M5 12l4 4L19 6"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v6m0-10h.01"/>',
  network: '<path d="M3 8a14 14 0 0118 0M6 12a9 9 0 0112 0M9 16a4 4 0 016 0m-3 4h.01"/>',
  warning: '<path d="M12 3L2 21h20zM12 9v5m0 3h.01"/>',
  download: '<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',
  stop: '<rect x="5" y="5" width="14" height="14" rx="2"/>',
  play: '<path d="M8 4l13 8-13 8z"/>',
  logout: '<path d="M10 3H4v18h6m4-14 5 5-5 5M8 12h13"/>',
  zoom: '<circle cx="10" cy="10" r="6"/><path d="M15 15l6 6M7 10h6m-3-3v6"/>',
  chevron: '<path d="M9 5l7 7-7 7"/>',
};
const icon = name => `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${icons[name] || icons.info}</svg>`;
const escapeHtml = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fixtures = [
  {id:'lake', name:'A quiet morning', src:'assets/lake.jpg', type:'photo', collection:'Alpine days', size: 'Illustrative photo', date:'2026-06-18'},
  {id:'film', name:'The long way home', src:'assets/lake-study.mp4', poster:'assets/lake.jpg', type:'video', collection:'Alpine days', size:'Silent study · 12 sec', date:'2026-06-18'},
  {id:'forest', name:'Into the evergreens', src:'assets/forest.jpg', type:'photo', collection:'Slow weekends', size:'Illustrative photo', date:'2026-06-12'},
  {id:'alpine', name:'Somewhere in the mountains', src:'assets/alpine.jpg', type:'photo', collection:'Alpine days', size:'Illustrative photo', date:'2026-06-11'},
  {id:'coast', name:'The last light', src:'assets/coast.jpg', type:'photo', collection:'Coastal notes', size:'Illustrative photo', date:'2026-05-24'},
  {id:'forest-detail', name:'A little further', src:'assets/forest.jpg', type:'photo', collection:'Slow weekends', size:'Illustrative photo', date:'2026-05-20'},
];
const storageKey = 'vault.interface-study.v1';
const fresh = () => ({demo:true, perspective:'owner', platform:'windows', route:'library', publishing:false, viewerPublishing:false, listed:false, viewerListed:false, access:'pending', verified:false, viewerVerified:false, transport:'connected', permission:true, collection:'all', filter:'all', query:'', sort:'newest', view:'grid', theme:'light', remembered:false, cache:192, downloads:[], contact:'Sam Chen', uplink:14, positions:{}});
let state = fresh();
try { const saved = JSON.parse(localStorage.getItem(storageKey)); if (saved && saved.version === 1) state = {...state, ...saved.state}; } catch { /* Storage is optional for the study. */ }
const valid = {perspective:['owner','viewer'],platform:['windows','android'],route:['library','people','activity','settings','remote','discover'],access:['not-requested','pending','approved','denied','revoked','expired','blocked'],transport:['idle','connected','interrupted','disconnected','no-route']};
for (const [key, values] of Object.entries(valid)) if (!values.includes(state[key])) state[key] = fresh()[key];
let uploads = [];
let openItem = null;
let toastTimer;
let lastFocus;
const app = document.getElementById('app');
const dialog = document.getElementById('dialog');
const own = () => state.perspective === 'owner';
const peerName = () => own() ? (state.contact || 'Sam Chen') : 'Alex Morgan';
const peerDevice = () => state.platform === 'windows' ? 'Android' : 'Windows';
const currentName = () => own() ? 'Alex Morgan' : (state.contact || 'Sam Chen');
const currentDevice = () => state.platform === 'windows' ? 'Windows' : 'Android';
const pending = () => own() && state.access === 'pending' && Boolean(state.contact);
const ownMedia = () => [...(state.demo && own() ? fixtures : []), ...uploads.filter(item => item.owner === state.perspective)];
const remoteMedia = () => fixtures.filter(item => item.collection === 'Alpine days');
const currentPublishing = () => own() ? state.publishing : state.viewerPublishing;
function setPublishing(value) {
  if (own()) state.publishing = value;
  else state.viewerPublishing = value;
}
const currentListed = () => own() ? state.listed : state.viewerListed;
const currentVerified = () => own() ? state.verified : state.viewerVerified;
function setListed(value) {
  if (own()) state.listed = value;
  else state.viewerListed = value;
}
function setVerified(value) {
  if (own()) state.verified = value;
  else state.viewerVerified = value;
}
const readableRemote = () => state.demo && !own() && state.access === 'approved' && state.publishing && state.transport === 'connected' && state.permission;
function persist() { try { localStorage.setItem(storageKey, JSON.stringify({version:1,state})); } catch { /* Private browsing may disable persistence. */ } }
function commit() { persist(); render(); }
function toast(message) { const element = document.getElementById('toast'); element.textContent = message; element.classList.add('visible'); clearTimeout(toastTimer); toastTimer = setTimeout(() => element.classList.remove('visible'), 4200); }
function button(label, action, kind = '', glyph = '', extra = '') { return `<button type="button" class="button ${kind}" data-action="${action}" ${extra}>${glyph ? icon(glyph) : ''}${label}</button>`; }
function tag(label, tone = '', glyph = '') { return `<span class="tag ${tone}">${glyph ? icon(glyph) : ''}${escapeHtml(label)}</span>`; }
function navButtons() { return [['library','library','My Library'],['people','people','People'],['activity','activity','Activity'],['settings','settings','Settings']].map(([route,glyph,label]) => `<button type="button" class="nav-button ${state.route === route || (route === 'people' && ['remote','discover'].includes(state.route)) ? 'active' : ''}" data-action="navigate" data-route="${route}" ${state.route === route ? 'aria-current="page"' : ''}>${icon(glyph)}<span>${label}</span>${route === 'activity' && pending() ? '<span class="nav-count" aria-label="1 pending request">1</span>' : ''}</button>`).join(''); }
function sidebar() {
  return `<aside class="sidebar"><div class="brand"><span class="brand-mark">${icon('vault')}</span><div><div class="brand-name">vault</div><div class="brand-tag">YOUR MOMENTS, YOURS.</div></div></div><nav class="nav" aria-label="Main navigation">${navButtons()}</nav><div class="sidebar-caption eyebrow">${state.demo && own() ? 'Your collections' : 'On this device'}</div>${state.demo && own() ? ['Alpine days','Slow weekends','Coastal notes'].map(name => `<button class="source-link" data-action="collection" data-collection="${name}">${icon('folder')}${name}</button>`).join('') : `<button class="source-link" data-action="import-folder">${icon('plus')}Add a folder</button>`}<div class="sidebar-bottom"><div class="publication-mini"><span class="status"><i class="status-dot ${currentPublishing() ? 'green' : ''}"></i><strong>${currentPublishing() ? 'Publishing · simulated' : 'Private by default'}</strong></span><p>${currentPublishing() ? 'Only approved people can request your files. Keep this device available.' : 'Your files stay with you. You decide who gets to see them.'}</p><button data-action="${currentPublishing() ? 'stop-publish' : 'publish'}">${currentPublishing() ? 'Stop publishing' : 'Manage sharing'}${icon('arrow')}</button></div><button class="identity" data-action="identity" aria-label="View local sample identity"><span class="avatar">${own() ? 'AM' : 'SC'}</span><div><strong>${escapeHtml(currentName())}</strong><p>This device · ${currentDevice()}</p></div>${icon('chevron')}</button></div></aside>`;
}
function render() {
  document.documentElement.dataset.theme = state.theme;
  const labels = {library:'My Library',people:'People',activity:'Activity',settings:'Settings',remote:"Alex’s library",discover:'Discover'};
  app.innerHTML = `<div class="app-shell">${sidebar()}<div class="workspace"><header class="topbar"><div class="breadcrumb">${icon('library')}<span>Personal space</span><span aria-hidden="true">/</span><span>${labels[state.route]}</span></div><div class="topbar-right"><span class="device-pill">${icon(state.platform === 'windows' ? 'monitor' : 'phone')}${currentDevice()} study</span><button class="round-button" data-action="theme" aria-label="Switch to ${state.theme === 'light' ? 'dark' : 'light'} theme">${icon(state.theme === 'light' ? 'moon' : 'sun')}</button></div></header><main id="main" class="page" tabindex="-1">${page()}</main></div><nav class="bottom-nav" aria-label="Mobile navigation">${navButtons()}</nav></div>`;
}
function page() {
  if (state.route === 'people') return peoplePage();
  if (state.route === 'activity') return activityPage();
  if (state.route === 'settings') return settingsPage();
  if (state.route === 'discover') return discoveryPage();
  if (state.route === 'remote') return remotePage();
  return libraryPage();
}
function heading(eyebrow, title, description, actions='') { return `<div class="page-heading"><div><div class="eyebrow">${eyebrow}</div><h1>${title}</h1><p>${description}</p></div>${actions ? `<div class="heading-actions">${actions}</div>` : ''}</div>`; }
function footer() { return `<footer class="page-footer"><span>${icon('lock')}Local-first. Shared on your terms.</span><span>Interface study · no network delivery</span></footer>`; }
function mediaCard(item, remote=false) {
  return `<button class="media-card" data-action="open-media" data-id="${escapeHtml(item.id)}" data-remote="${remote}" aria-label="${item.type === 'video' ? 'Play' : 'View'} ${escapeHtml(item.name)}"><div class="media-image">${item.type === 'video' && !item.poster ? '<div class="media-block">' + icon('video') + '</div>' : `<img src="${escapeHtml(item.poster || item.src)}" alt="" loading="lazy">`}<span class="media-type">${icon(item.type === 'video' ? 'video' : 'image')}${item.type === 'video' ? 'VIDEO' : 'PHOTO'}</span>${item.type === 'video' ? '<span class="media-duration">' + (item.id === 'film' ? '0:12' : 'Local file') + '</span>' : ''}</div><div class="media-title"><strong>${escapeHtml(item.name)}</strong>${icon('more')}</div><div class="media-description"><span>${escapeHtml(item.collection)}</span><span>${escapeHtml(item.size)}</span></div></button>`;
}
function mediaBrowser(items, remote=false) {
  const photos = items.filter(item => item.type === 'photo').length;
  const videos = items.length - photos;
  let filtered = items.filter(item => (state.collection === 'all' || remote || item.collection === state.collection) && (state.filter === 'all' || item.type === state.filter) && item.name.toLowerCase().includes(state.query.toLowerCase()));
  if (state.sort === 'name') filtered.sort((a,b) => a.name.localeCompare(b.name));
  else filtered.sort((a,b) => b.date.localeCompare(a.date));
  return `<div class="toolbar"><div class="tabs" role="group" aria-label="Media type">${[['all','All moments',items.length],['photo','Photos',photos],['video','Videos',videos]].map(([filter,label,count]) => `<button class="tab ${state.filter === filter ? 'active' : ''}" data-action="filter" data-filter="${filter}" aria-pressed="${state.filter === filter}">${label}<span>${count}</span></button>`).join('')}</div><div class="toolbar-controls"><label class="search">${icon('search')}<input type="search" id="media-search" placeholder="Find a moment…" value="${escapeHtml(state.query)}" aria-label="Search loaded media"></label><select class="select" id="media-sort" aria-label="Sort media"><option value="newest" ${state.sort === 'newest' ? 'selected' : ''}>Newest first</option><option value="name" ${state.sort === 'name' ? 'selected' : ''}>Name A–Z</option></select><div class="view-switch" role="group" aria-label="Media layout"><button class="${state.view === 'grid' ? 'active' : ''}" data-action="layout" data-view="grid" aria-label="Grid layout" aria-pressed="${state.view === 'grid'}">${icon('grid')}</button><button class="${state.view === 'list' ? 'active' : ''}" data-action="layout" data-view="list" aria-label="List layout" aria-pressed="${state.view === 'list'}">${icon('list')}</button></div></div></div><div class="section-meta"><strong>${state.collection !== 'all' && !remote ? escapeHtml(state.collection) : 'A few things worth keeping'}</strong><span>${filtered.length} ${filtered.length === 1 ? 'moment' : 'moments'}${state.demo ? ' · illustrative content' : ' · this browser tab'}</span></div><div class="media-grid ${state.view === 'list' ? 'list' : ''}" id="media-results">${filtered.length ? filtered.map(item => mediaCard(item,remote)).join('') : '<div class="note">No moments match these filters. Clear the search or choose All moments.</div>'}</div>`;
}
function libraryPage() {
  const items = ownMedia();
  const count = items.length;
  return `${heading('A place for what matters','Your life. Your library.', 'Not in someone else’s cloud. Right here, with you.',button('Add folder','import-folder','','plus'))}<div class="library-intro"><div class="intro-copy"><span class="intro-icon">${icon('shield')}</span><div><h2>A little more personal.</h2><p>Keep your originals close. Let the right people in.<br>No uploads. No public library by accident.</p></div></div><div class="intro-action"><span class="status"><i class="status-dot ${currentPublishing() ? 'green' : ''}"></i>${currentPublishing() ? 'Publishing · simulated' : 'Not publishing'}</span><p>Nothing is being shared by this prototype.</p><button class="text-button" data-action="${currentPublishing() ? 'stop-publish' : 'publish'}">${currentPublishing() ? 'Stop publishing' : 'Review sharing'}${icon('arrow')}</button></div></div>${!state.permission && own() ? banner('Folder permission needed','Your originals have not been deleted. Choose the folder again to restore access.','warning','restore-permission','Restore access') : ''}${count ? `${state.demo && own() ? `<div class="collection-label"><h2>Little collections, big memories</h2><span>Walkthrough library</span></div><div class="collections">${[['Alpine days','lake','3 moments'],['Slow weekends','forest','2 moments'],['Coastal notes','coast','1 moment']].map(([name,photo,sub]) => `<button class="collection ${state.collection === name ? 'selected' : ''}" data-action="collection" data-collection="${name}" aria-pressed="${state.collection === name}"><img src="assets/${photo}.jpg" alt="" loading="lazy"><span class="collection-content">${icon('folder')}<span><strong>${name}</strong><small>${sub}</small></span></span></button>`).join('')}</div>` : ''}${state.collection !== 'all' ? '<button class="back-button" data-action="all-collections">' + icon('back') + 'All collections</button>' : ''}${mediaBrowser(items)}` : `<div class="empty"><div class="intro-icon">${icon('folder')}</div><div class="eyebrow">START WITH SOMETHING YOURS</div><h2>Your moments belong here.</h2><p>Choose photos or videos from this device. Adding files does not publish them. Just here to look around? Connect to someone instead.</p><div class="heading-actions">${button('Choose files','import-files','primary','plus')}${button('Connect to someone','go-people','','people')}</div></div>`}${pending() ? `<div class="banner" style=""><div><strong>Sam would like a look around.</strong><p>A sample access request is waiting for your decision.</p></div>${button('Review request','review','','arrow')}</div>` : ''}${footer()}`;
}
function banner(title, description, tone='', action='', label='') { return `<div class="banner ${tone}">${icon(tone === 'error' || tone === 'warning' ? 'warning' : 'info')}<div><strong>${escapeHtml(title)}</strong><p>${escapeHtml(description)}</p></div>${action ? button(label,action,'small') : ''}</div>`; }
function accessTag() { const tones = {approved:'green',pending:'amber',revoked:'red',blocked:'red',expired:'amber'}; return tag({approved:'Access approved',pending:'Awaiting approval','not-requested':'No access grant',denied:'Request denied',revoked:'Access revoked',expired:'Access expired',blocked:'Blocked'}[state.access],tones[state.access] || ''); }
function sessionTag() { return tag({connected:'Direct session · simulated',idle:'Not connected',disconnected:'Disconnected by you',interrupted:'Connection interrupted','no-route':'No direct route'}[state.transport],state.transport === 'connected' ? 'green' : state.transport === 'no-route' ? 'amber' : '', 'network'); }
function peerActions() {
  if (!state.contact && own()) return button('Add person','add-person','primary','plus');
  if (state.access === 'blocked') return button('Review block','review-block','','shield');
  if (state.transport !== 'connected') return button('Connect','connect','primary','network');
  if (own()) return `${state.access === 'pending' ? button('Review request','review','primary') : state.access === 'approved' ? button('Manage access','manage-access','','shield') : button('Access details','manage-access','','shield')}${button('Disconnect','disconnect','','logout')}`;
  return `${state.access === 'approved' ? button('Open library','open-remote','primary','arrow') : ['not-requested','denied','revoked','expired'].includes(state.access) ? button('Request access','request','primary','shield') : '<span class="tag amber">Request sent</span>'}${button('Disconnect','disconnect','','logout')}`;
}
function peoplePage() {
  return `${heading('A smaller circle, a better connection','Good company.', 'A contact is a person. A connection is a path. Access is your decision.',button('Add person','add-person','','plus'))}${state.transport === 'no-route' ? banner('No direct route established','An identity or invite cannot repair an unreachable network. Try again together on a different permitted network.','warning','connect','Retry') : state.transport === 'interrupted' ? banner('Connection interrupted','Keep your place. When both devices are available, reconnect deliberately in this study.','','connect','Reconnect') : ''}<div class="split"><div class="stack"><section class="panel"><div class="panel-heading"><h2>Your people</h2><span class="demo-pill">${state.demo ? 'Fictional contact' : 'Local study contact'}</span></div>${state.contact || !own() ? `<div class="person-row"><span class="avatar ochre">${own() ? 'SC' : 'AM'}</span><div class="person-copy"><h3>${escapeHtml(peerName())}</h3><p>${peerDevice()} · ${currentVerified() ? 'Identity compared by you' : 'Not manually verified'}</p><div class="person-statuses">${currentVerified() ? tag('Verified by you','green','shield') : tag('Compare identity','','shield')}${sessionTag()}${accessTag()}</div></div><div class="person-actions">${peerActions()}</div></div><div class="panel-body"><button class="text-button" data-action="verify">${icon('shield')}${currentVerified() ? 'View identity comparison' : 'Verify this person'}${icon('arrow')}</button><p class="explanation">${own() ? 'Approving Sam lets this identity request only the scope you choose. It does not make your library public.' : 'Alex’s filenames and thumbnails stay private until access is approved. Being connected is not permission to browse.'}</p></div>` : '<div class="panel-body"><p class="explanation">No contacts yet. Add a person without publishing a library or joining a public directory.</p></div>'}</section><section class="panel"><div class="panel-heading"><h2>Looking a little further?</h2>${icon('people')}</div><div class="panel-body"><p class="explanation">Explore an optional public directory. Results are partial, and being listed is a separate choice.</p><button class="text-button" data-action="discover">Explore discovery ${icon('arrow')}</button></div></section></div><aside class="panel"><div class="panel-heading"><h2>Connections, without the guesswork</h2></div><div class="panel-body"><div class="intro-icon">${icon('network')}</div><h3>One person is enough.</h3><p class="explanation">You don’t need a crowd of peers. Just the right person, permission, and a direct connection.</p><div class="section-divider"></div><p class="note">Prototype: identities and connections are simulated. No real key exchange, broker, relay or media delivery runs here.</p><button class="text-button" data-action="manual">How manual connection works ${icon('arrow')}</button></div></aside></div>${footer()}`;
}
function remotePage() {
  const status = state.access !== 'approved' ? ['revoked','expired','blocked'].includes(state.access) ? 'Access has ended.' : 'A little patience. A little permission.' : !state.permission ? 'The source needs attention.' : !state.publishing ? 'Alex is not publishing.' : 'Alex is unavailable right now.';
  return `<button class="back-button" data-action="go-people">${icon('back')}Back to People</button>${heading('SHARED WITH YOU',"Alex’s library.",readableRemote() ? 'Alpine days · browse, play and save · sample approval' : 'Private content stays private until you have current access.',accessTag())}${readableRemote() ? `${banner('An approved little window','This illustrative collection is visible because the study grant is approved and the owner is publishing.','','remote-details','Access details')}${mediaBrowser(remoteMedia(),true)}` : `<div class="empty"><div class="intro-icon">${icon('lock')}</div><h2>${status}</h2><p>${state.access !== 'approved' ? 'No private filenames, counts or thumbnails are shown. Received copies cannot be recalled when access ends.' : !state.permission ? 'The owner needs to restore permission to read this folder.' : !state.publishing ? 'New bytes are available only while the owner is publishing and reachable.' : 'Your place is preserved. There is no cloud copy to fetch from.'}</p><div class="heading-actions">${state.transport !== 'connected' ? button('Connect','connect','primary','network') : ['not-requested','denied','expired','revoked'].includes(state.access) ? button('Request access','request','primary','shield') : button('Back to People','go-people','','back')}</div></div>`}${footer()}`;
}
function activityPage() {
  return `${heading('THE THINGS HAPPENING BETWEEN US','A little activity.', 'Requests, sessions and saved moments. Nothing happening behind your back.')}${pending() ? `<section class="panel"><div class="panel-heading"><h2>Needs your decision</h2>${tag('1 request','amber')}</div><div class="request"><div class="request-header"><span class="avatar ochre">SC</span><div><h3>${escapeHtml(peerName())} would like access</h3><p>${peerDevice()} · ${currentVerified() ? 'Identity compared by you' : 'Identity not manually verified'}</p></div>${tag('Pending','amber')}</div><p class="explanation">Requested sample scope: Alpine days. Actions: browse, play and save. No private content has been shown to the viewer.</p><div class="request-actions">${button('Review request','review','primary','shield')}${button('Deny','deny','','close')}</div></div></section>` : `<section class="panel"><div class="panel-heading"><h2>Access decisions</h2>${accessTag()}</div><div class="panel-body"><p class="explanation">${state.access === 'approved' ? 'Sam is approved for Alpine days. Only future delivery can be stopped; already received copies remain possible.' : state.access === 'revoked' ? 'Sam’s approval was revoked. New delivery is stopped. Previously received copies have not been deleted.' : 'No access requests need a decision right now.'}</p>${state.access === 'approved' ? button('Manage access','manage-access','','shield') : ''}</div></section>`}<div class="settings-section"></div><section class="panel"><div class="panel-heading"><h2>Connection</h2><span class="demo-pill">Simulated</span></div><div class="person-row"><span class="avatar ${own() ? 'ochre' : ''}">${own() ? 'SC' : 'AM'}</span><div class="person-copy"><h3>${escapeHtml(peerName())}</h3><p>${own() ? 'Incoming viewer' : 'Outgoing viewer'} · ${peerDevice()}</p><div class="person-statuses">${sessionTag()}${accessTag()}</div></div><div class="person-actions">${state.transport === 'connected' ? button('Disconnect','disconnect','','logout') : button('Connect','connect','primary','network')}</div></div><div class="panel-body"><p class="note">No real transfer rate or byte counter is shown: this study does not send data. An intentional disconnect will not reconnect automatically, including after reload.</p></div></section><div class="settings-section"></div><section class="panel"><div class="panel-heading"><h2>Saved in this browser session</h2>${tag(`${state.downloads.length} ${state.downloads.length === 1 ? 'file' : 'files'}`)}</div>${state.downloads.length ? state.downloads.map(item => `<div class="download-row">${icon('download')}<div class="download-copy"><strong>${escapeHtml(item.name)}</strong><p>Browser download requested · check your browser for save outcome</p></div>${tag('Local file')}</div>`).join('') : '<div class="panel-body"><p class="explanation">No downloads requested. Saved files are separate from temporary playback cache. The browser, not Vault, manages these destinations.</p></div>'}</section>${footer()}`;
}
function settingsPage() {
  return `${heading('MAKE YOURSELF AT HOME','On your terms.', 'A few clear controls. No account behind the curtain.')}<div class="split"><div><section class="settings-section"><h2>Identity & appearance</h2><div class="panel"><div class="setting-row"><div><h3>${escapeHtml(currentName())}</h3><p>Device-local identity layout. This study does not create cryptographic keys or a recovery secret.</p></div>${button('View identity','identity','small')}</div><div class="setting-row"><div><h3>Dark appearance</h3><p>A little easier on the eyes after sunset.</p></div><button class="switch" role="switch" aria-checked="${state.theme === 'dark'}" aria-label="Dark appearance" data-action="theme"></button></div></div></section><section class="settings-section"><h2>Sharing & access</h2><div class="panel"><div class="setting-row"><div><h3>Publish selected library</h3><p>${currentPublishing() ? 'Sample publication active. No actual files are shared.' : 'Off. Adding a folder never starts publication.'}</p></div>${button(currentPublishing() ? 'Stop' : 'Review',currentPublishing() ? 'stop-publish' : 'publish','small')}</div><div class="setting-row"><div><h3>Public directory listing</h3><p>Separate from publication. Name, tags, coarse counts, stable identity and presence may become public.</p></div><button class="switch" role="switch" aria-checked="${currentListed()}" aria-label="Public directory listing" data-action="listing"></button></div><div class="setting-row"><div><h3>Remembered approvals</h3><p>${state.remembered ? 'A sample rule exists for Sam. Review or revoke it.' : 'No automatic approvals. Each new identity needs your decision.'}</p></div>${button('Review','manage-access','small')}</div></div></section><section class="settings-section"><h2>Storage</h2><div class="panel"><div class="panel-body"><div class="collection-label"><h3>Playback cache</h3><span>${state.cache} MB / 512 MB · illustrative</span></div><div class="storage-bar" aria-hidden="true"><span class="${state.cache ? 'storage-cache' : ''}"></span><span class="storage-metadata"></span><span class="storage-free"></span></div><div class="storage-legend"><span><i class="storage-key"></i>Temporary cache</span><span><i class="storage-key ochre"></i>Metadata</span><span><i class="storage-key gray"></i>Remaining budget</span></div><p class="explanation">Illustrative storage accounting, not a device measurement. Saved downloads live outside this cache; clearing it never deletes originals or exported files.</p>${button('Clear sample cache','clear-cache','small')}</div></div></section><section class="settings-section"><h2>Bandwidth & diagnostics</h2><div class="panel"><div class="setting-row"><div><h3>Uplink cap</h3><p>Design value: <output id="uplink-value">${state.uplink}</output> Mbps. This study sends no network traffic.</p></div><input class="setting-range" id="uplink" type="range" min="1" max="50" value="${state.uplink}" aria-label="Illustrative uplink cap in Mbps"></div><div class="setting-row"><div><h3>Local diagnostics</h3><p>Export this study’s simulated state only. No media, file paths or secrets.</p></div>${button('Export','diagnostics','small','download')}</div></div></section></div><aside class="stack"><div class="panel"><div class="panel-heading"><h2>Local doesn't mean always online.</h2></div><div class="panel-body"><span class="intro-icon">${icon('monitor')}</span><p class="explanation">An owner must be publishing, able to read their sources and directly reachable to serve new bytes. Android availability and Windows tray behavior remain native implementation work.</p><div class="section-divider"></div><p class="note">No telemetry. No operated backend. No TURN. No promise to erase someone else’s received copy.</p></div></div></aside></div>${footer()}`;
}
function discoveryPage() {
  return `<button class="back-button" data-action="go-people">${icon('back')}Back to People</button>${heading('OPTIONAL, NOT UNIVERSAL','A world, not a directory.', 'Public discovery is best effort. These are illustrative states, not live search results.')}${banner('Only public metadata belongs here','No private filenames, posters, paths or access lists. Results cover a limited shared endpoint, not everyone using Vault.')}<div class="discover-grid"><div class="panel discover-card"><span class="avatar">AM</span><h3>Alex Morgan</h3><p>Outdoors · travel · sample public profile</p>${tag('Recently announced · not proven reachable')}<div class="section-divider"></div>${button('View sample contact','go-people','','arrow')}</div><div class="panel discover-card"><span class="intro-icon">${icon('shield')}</span><h3>Looking is not listing.</h3><p>You can explore discovery without advertising yourself. Review exactly what becomes public before opting in.</p>${button(currentListed() ? 'Review public listing' : 'Review listing choice','listing','','shield')}</div></div>${footer()}`;
}
function showDialog(title, body, className='') {
  lastFocus = document.activeElement;
  if (dialog.open) closeDialog();
  dialog.className = className;
  dialog.innerHTML = `<div class="dialog-head"><h2 id="dialog-title">${title}</h2><button class="round-button" data-action="close-dialog" aria-label="Close dialog">${icon('close')}</button></div><div class="dialog-body">${body}</div>`;
  dialog.showModal();
}
function rememberPlayback() {
  const video = dialog.querySelector('video');
  if (video && openItem) {
    state.positions[`${state.perspective}:${openItem.item.id}`] = video.currentTime;
    video.pause();
    persist();
  }
}
function closeDialog() { rememberPlayback(); dialog.close(); }
function facts(rows) { return `<dl class="detail-facts">${rows.map(([key,value])=>`<div class="fact"><dt>${key}</dt><dd>${value}</dd></div>`).join('')}</dl>`; }
function review() {
  if (!own()) { toast('Switch to Alex’s owner perspective to review this request.'); return; }
  if (state.access !== 'pending') { toast('This request has already been handled.'); return; }
  showDialog('Let Sam in?', `<p>Review the exact scope before approving this fictional request. Connection is not approval.</p><div class="request-header"><span class="avatar ochre">SC</span><div><h3>${escapeHtml(peerName())}</h3><p>${currentVerified() ? 'Identity compared by you' : 'Not manually verified'}</p></div>${currentVerified() ? tag('Verified','green','shield') : tag('Unverified','amber')}</div>${facts([['Collection','Alpine days'],['Actions','Browse, play and save'],['Expiry','1 hour after approval · illustrative']])}${!currentVerified() ? '<button class="text-button" data-action="verify">Compare identity before deciding ' + icon('arrow') + '</button>' : ''}<label class="check-row"><input id="remember-rule" type="checkbox" ${state.remembered ? 'checked' : ''}><span>Remember this approval for this contact<small>Same identity and scope only. A future new key needs fresh approval. Policy is illustrative, not a frozen grant schema.</small></span></label><div class="note">Sam may keep received, saved or captured content. Revoking access stops future delivery; it cannot recall those copies.</div><div class="dialog-actions">${button('Block','block','danger')}${button('Deny','deny')}${button('Approve access','approve','primary','check')}</div>`);
}
function publish() {
  const items = ownMedia();
  if (!items.length) { showDialog('Start with a source.', '<p>Choose local media before reviewing publication. No files are sent by the study.</p><div class="dialog-actions">' + button('Choose files','import-files','primary','plus') + '</div>'); return; }
  if (!state.permission) { showDialog('Restore source access first.', '<p>The owner cannot serve new bytes while source permission is lost. This state is simulated.</p><div class="dialog-actions">' + button('Restore sample access','restore-permission','primary') + '</div>'); return; }
  showDialog('Share a little. Keep control.', `<p>Start a publication simulation. Your files are not uploaded or sent anywhere by this interface study.</p>${facts([['Selected source',state.demo && own() ? 'Alpine days · sample collection' : 'Selected files in this tab'],['People allowed',state.access === 'approved' ? escapeHtml(peerName()) : 'No approved viewers yet'],['Public listing',currentListed() ? 'On · separately chosen' : 'Off'],['Availability','Owner awake, publishing and reachable']])}<label class="check-row"><input type="checkbox" id="copy-ack"><span>I understand received copies cannot be recalled.<small>This applies to saved, buffered and captured content.</small></span></label><div class="dialog-actions">${button('Keep private','close-dialog')}${button('Start publishing simulation','confirm-publish','primary','shield')}</div>`);
}
function manageAccess() {
  showDialog('Access, not ownership.', `<p>${escapeHtml(peerName())} · ${escapeHtml(state.access)}. Changing access affects future delivery, not files already received.</p>${facts([['Identity',currentVerified() ? 'Compared by you' : 'Not manually verified'],['Scope','Alpine days · illustrative'],['Actions','Browse, play and save'],['Remembered rule',state.remembered ? 'Yes · sample rule' : 'No']])}<div class="dialog-actions">${state.access === 'approved' && own() ? button('Revoke access','revoke','danger','stop') : ''}${own() && state.access !== 'blocked' ? button('Block identity','block','danger') : ''}${button('Done','close-dialog','primary')}</div>`);
}
function scenario() {
  showDialog('Behind the interface.', `<p>Walkthrough controls, outside the product UI. Every connection and authorization state is simulated. Local file viewing and the bundled silent video use the browser for real.</p><div class="eyebrow">Perspective · not a permanent user role</div><div class="scenario-segment">${button('Alex · owner','perspective',own() ? 'selected' : '','','data-perspective="owner"')}${button('Sam · viewer','perspective',!own() ? 'selected' : '','','data-perspective="viewer"')}</div><div class="eyebrow">Platform presentation</div><div class="scenario-segment">${button('Windows','platform',state.platform === 'windows' ? 'selected' : '','monitor','data-platform="windows"')}${button('Android','platform',state.platform === 'android' ? 'selected' : '','phone','data-platform="android"')}</div><div class="eyebrow">Explore a state</div><div class="scenario-options">${button('Access request','sample-request','','people')}${button('No direct route','no-route','','network')}${button('Network interruption','interrupt','','warning')}${button('Source permission lost','lose-permission','','folder')}${button('Revoke approval','sample-revoke','','stop')}${button('Restore connection','restore-network','','check')}</div><p class="note">Suggested journey: publish as Alex → Sam requests → Alex approves → Sam browses and seeks → interrupt → explicitly reconnect → revoke. Use the perspective controls to move between both sides.</p><div class="dialog-actions">${button('Start empty','reset-empty')}${button('Reload sample library','reset-demo','primary')}</div>`);
}
function navigate(route) { if (dialog.open) closeDialog(); state.route = route; state.query = ''; state.filter = 'all'; state.collection = 'all'; commit(); document.getElementById('main').focus({preventScroll:true}); window.scrollTo({top:0,behavior:'instant'}); }
function findItem(id) { return [...fixtures,...uploads].find(item => item.id === id); }
function openMedia(id, remote=false) {
  const item = findItem(id);
  if (!item) return;
  if (remote && (!readableRemote() || !remoteMedia().some(allowed => allowed.id === item.id))) {
    navigate('remote');
    return;
  }
  if (!remote && !state.permission && own()) {
    toast('Restore access to the sample source before viewing.');
    return;
  }
  if (dialog.open) closeDialog();
  openItem = {item,remote};
  lastFocus = document.activeElement;
  dialog.className = 'viewer-dialog';
  const media = item.type === 'video'
    ? `<video id="local-video" src="${escapeHtml(item.src)}" ${item.poster ? 'poster="'+escapeHtml(item.poster)+'"' : ''} controls playsinline preload="metadata"></video>`
    : `<img id="viewer-photo" src="${escapeHtml(item.src)}" alt="${escapeHtml(item.name)}">`;
  dialog.innerHTML = `
    <div class="viewer-head">
      <div><strong id="dialog-title">${escapeHtml(item.name)}</strong>
        <p>${remote ? 'Alex’s Alpine days · approved sample scope' : 'Local browser playback · no upload'}${item.id === 'film' ? ' · 12-second silent still-image study' : ''}</p>
      </div>
      <button class="round-button" data-action="close-dialog" aria-label="Close media">${icon('close')}</button>
    </div>
    <div class="viewer-stage">${media}</div>
    <div class="viewer-bottom">
      <div class="local-badge">${icon(remote ? 'shield' : 'lock')}${remote ? 'Simulated remote session; bytes bundled locally' : 'Only in this browser'}</div>
      <div class="viewer-tools">
        ${item.type === 'photo' ? button('Zoom','zoom','small','zoom') : ''}
        ${button('Previous','previous-media','small','back')}
        ${button('Next','next-media','small','arrow')}
        ${button('Save file','save-file','small','download')}
        ${remote ? button('Session','scenario','small','network') : ''}
      </div>
    </div>`;
  dialog.showModal();
  const video = dialog.querySelector('video');
  if (video) video.addEventListener('loadedmetadata', () => {
    const savedPosition = state.positions[`${state.perspective}:${item.id}`] || 0;
    if (savedPosition > 0 && Number.isFinite(video.duration)) video.currentTime = Math.min(savedPosition, video.duration - 0.1);
  }, {once:true});
  const display = video || dialog.querySelector('img');
  display.addEventListener('error', () => {
    const stage = dialog.querySelector('.viewer-stage');
    if (!stage.contains(display)) return;
    stage.innerHTML = `<div class="media-block">${icon('warning')}<h2>This file could not be opened.</h2><p>The browser may not support this format, or the file may be damaged. Your original has not been changed. You can still save the file.</p></div>`;
  }, {once:true});
}
function refreshOpenMedia() { if (openItem && openItem.remote && !readableRemote()) { const video = dialog.querySelector('video'); if (video) video.pause(); closeDialog(); navigate('remote'); } }
function downloadFile(item) {
  if (openItem?.remote && !readableRemote()) { refreshOpenMedia(); return; }
  const anchor = document.createElement('a'); anchor.href = item.src; anchor.download = item.downloadName || item.name + (item.type === 'video' ? '.mp4' : '.jpg'); document.body.append(anchor); anchor.click(); anchor.remove();
  state.downloads.push({name:item.name}); persist(); toast('Browser download requested. Saved copies are outside the playback cache.');
}
function reset(demo) {
  for (const item of uploads) URL.revokeObjectURL(item.src);
  uploads = [];
  state = {...fresh(),demo,contact:demo ? 'Sam Chen' : '',access:demo ? 'pending' : 'not-requested',transport:demo ? 'connected' : 'idle'};
  closeDialog(); commit(); toast(demo ? 'Illustrative walkthrough loaded. Nothing is shared.' : 'Empty start. Choose files or add someone; no account required.');
}
const actions = {
  navigate: element => navigate(element.dataset.route),
  'go-people': () => navigate('people'),
  discover: () => navigate('discover'),
  'open-remote': () => navigate('remote'),
  'all-collections': () => {state.collection='all';commit();},
  collection: element => {state.route='library';state.collection=state.collection === element.dataset.collection ? 'all' : element.dataset.collection;state.query='';commit();},
  filter: element => {state.filter=element.dataset.filter;commit();},
  layout: element => {state.view=element.dataset.view;commit();},
  theme: () => {state.theme=state.theme==='light'?'dark':'light';commit();},
  scenario,
  'close-dialog': closeDialog,
  'import-files': () => {if(dialog.open)closeDialog();document.getElementById('file-picker').click();},
  'import-folder': () => {document.getElementById('folder-picker').click();},
  publish,
  'confirm-publish': () => {if(!document.getElementById('copy-ack')?.checked){toast('Acknowledge the received-copy limit first.');return;}setPublishing(true);closeDialog();commit();toast('Publication simulated. No media leaves this browser.');},
  'stop-publish': () => showDialog('Stop publishing?',`<p>Stop serving all viewers in this study. Approvals remain separate; existing received copies are not erased.</p><div class="dialog-actions">${button('Keep publishing','close-dialog')}${button('Stop publication','confirm-stop','danger','stop')}</div>`),
  'confirm-stop': () => {setPublishing(false);closeDialog();commit();toast('Publication stopped. No automatic restart.');},
  review,
  approve: () => {if(!own() || state.access!=='pending'){closeDialog();toast('This request is no longer pending.');return;}state.remembered=Boolean(document.getElementById('remember-rule')?.checked);state.access='approved';closeDialog();commit();toast('Sample scope approved. Switch to Sam to browse.');},
  deny: () => {state.access='denied';state.remembered=false;if(dialog.open)closeDialog();commit();toast('Request denied. No content was granted.');},
  'manage-access': manageAccess,
  'remote-details': manageAccess,
  revoke: () => showDialog('Stop future delivery?',`<p>Revoke Sam’s sample approval for Alpine days and remove its remembered rule. Cached, saved and captured copies cannot be recalled.</p><div class="dialog-actions">${button('Keep approval','close-dialog')}${button('Revoke access','confirm-revoke','danger','stop')}</div>`),
  'confirm-revoke': () => {state.access='revoked';state.remembered=false;closeDialog();commit();toast('Approval revoked. Future delivery stopped; existing copies remain.');},
  block: () => showDialog('Block this identity?',`<p>Block ${escapeHtml(peerName())} from new access and requests in this simulation. This cannot remove their received copies.</p><div class="dialog-actions">${button('Cancel','close-dialog')}${button('Block identity','confirm-block','danger','shield')}</div>`),
  'confirm-block': () => {state.access='blocked';state.remembered=false;state.transport='disconnected';closeDialog();commit();toast('Identity blocked. Existing copies were not deleted.');},
  'review-block': () => showDialog('This identity is blocked.',`<p>Unblocking allows a new explicit connection and request; it does not restore a revoked grant.</p><div class="dialog-actions">${button('Keep blocked','close-dialog')}${button('Unblock','unblock','primary')}</div>`),
  unblock: () => {state.access='not-requested';closeDialog();commit();},
  request: () => {if(state.transport!=='connected' || state.access==='blocked'){toast('Connect first; blocked identities cannot request access.');return;}state.access='pending';commit();toast('Request simulated. Switch to Alex to review.');},
  disconnect: () => showDialog('Disconnect this session?',`<p>Stop this connection and automatic reconnect until you explicitly connect again. Approval remains a separate decision.</p><div class="dialog-actions">${button('Stay connected','close-dialog')}${button('Disconnect','confirm-disconnect','primary','logout')}</div>`),
  'confirm-disconnect': () => {state.transport='disconnected';closeDialog();commit();toast('Disconnected by you. Reloading will not reconnect.');},
  connect: () => {if(state.access==='blocked'){toast('This identity is blocked. Review the block first.');return;}if(state.transport==='no-route'){showDialog('No direct route established.',`<p>This failure is intentionally selected in Walkthrough controls. In Vault, both devices need a viable direct path; an invite or manual exchange cannot guarantee one.</p><div class="dialog-actions">${button('Close','close-dialog')}${button('Walkthrough controls','scenario','primary')}</div>`);return;}state.transport='connected';commit();toast('Direct session simulated. Access still requires a separate approval.');},
  verify: () => showDialog('Make sure it’s them.',`<p>Compare this illustrative safety code through a trusted channel. A display name is not identity verification.</p><div class="contact-key mono">3419 2806 5174<br>9021 6380 4527</div><p class="note">Layout sample only. This is not a cryptographic fingerprint or scannable contact code. Checking it does not grant media access.</p><div class="dialog-actions">${button('Not now','close-dialog')}${button('Mark compared in study','confirm-verify','primary','shield')}</div>`),
  'confirm-verify': () => {setVerified(true);closeDialog();commit();toast('Sample identity marked compared. Approval is still separate.');},
  identity: () => showDialog('Your identity stays here.',`<p>${escapeHtml(currentName())} · ${currentDevice()}. There is no cloud account to sign into.</p><div class="contact-key mono">LOCAL IDENTITY<br>DESIGN EXAMPLE ONLY</div><p class="note">No key or QR is generated by this study. Backup, rotation and contact encoding must follow the identity ADRs; recovery words and multi-device login are not promised.</p><div class="dialog-actions">${button('Done','close-dialog','primary')}</div>`),
  'add-person': () => showDialog('Start with a person.',`<p>Add a local study contact. This does not discover a device, authenticate a key, connect a session or grant access.</p><form id="contact-form"><label class="field">Name for this contact<input name="contact" id="contact-name" maxlength="60" required placeholder="e.g. Sam Chen" autocomplete="off"></label><p class="note">Production contact import will use the frozen key/QR payload. A name here is only a walkthrough label.</p><div class="dialog-actions">${button('Cancel','close-dialog')}<button class="button primary" type="submit">Add study contact</button></div></form>`),
  manual: () => showDialog('A fallback, not a shortcut.',`<p>Manual signaling exchanges the complete gathered offer and answer, by text or bounded multipart QR. Both peers still need a viable direct route.</p><p class="note">No fake offer, answer or QR is produced here. This design route is explanatory until the real protocol adapter is integrated.</p><div class="dialog-actions">${button('Understood','close-dialog','primary')}</div>`),
  listing: () => showDialog(currentListed()?'Stop listing publicly?':'A deliberate public choice.',`<p>${currentListed() ? 'Stop new announcements. Copies of older announcements may remain with public services or other peers.' : 'Only this metadata may be public: display name, selected tags, coarse counts, stable identity and presence. Never filenames, paths, posters or access lists.'}</p><p class="note">This study only changes a local flag. No directory or public service is contacted.</p><div class="dialog-actions">${button('Cancel','close-dialog')}${button(currentListed()?'Stop listing simulation':'Opt in to listing simulation','confirm-listing','primary')}</div>`),
  'confirm-listing': () => {setListed(!currentListed());closeDialog();commit();toast(currentListed()?'Public listing simulated; no announcement sent.':'Public listing simulation stopped.');},
  'clear-cache': () => {state.cache=0;commit();toast('Illustrative cache cleared. Originals and saved copies are untouched.');},
  diagnostics: () => {const record={study:'Vault interface study',simulated:true,perspective:state.perspective,platform:state.platform,transport:state.transport,access:state.access,publishing:state.publishing};const url=URL.createObjectURL(new Blob([JSON.stringify(record,null,2)],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download='vault-study-diagnostics.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);toast('Study diagnostics exported without media, names, paths or keys.');},
  perspective: element => {state.perspective=element.dataset.perspective;state.platform=own()?'windows':'android';state.route='people';state.collection='all';state.query='';closeDialog();commit();toast(`${own()?'Owner':'Viewer'} perspective. All network behavior is simulated.`);},
  platform: element => {state.platform=element.dataset.platform;persist();render();scenario();},
  'sample-request': () => {state.access='pending';state.contact=state.contact||'Sam Chen';state.route=own()?'activity':'people';closeDialog();commit();},
  'no-route': () => {state.transport='no-route';state.route='people';closeDialog();commit();},
  interrupt: () => {if(state.transport==='disconnected'){toast('User disconnect remains in effect. Explicitly reconnect first.');return;}state.transport='interrupted';state.route=own()?'activity':'remote';closeDialog();commit();},
  'restore-network': () => {if(state.transport==='disconnected'){toast('Disconnected by you. Use Connect explicitly; network recovery cannot override it.');return;}state.transport='connected';closeDialog();commit();toast('Network restored in the study. Approval and publication are unchanged.');},
  'lose-permission': () => {state.permission=false;state.route=own()?'library':'remote';closeDialog();commit();},
  'restore-permission': () => {state.permission=true;if(dialog.open)closeDialog();commit();toast('Source access restored in the simulation.');},
  'sample-revoke': () => {state.access='revoked';state.remembered=false;state.route=own()?'activity':'remote';closeDialog();commit();},
  'reset-demo': () => reset(true),
  'reset-empty': () => reset(false),
  'open-media': element => openMedia(element.dataset.id,element.dataset.remote==='true'),
  zoom: () => {const image=dialog.querySelector('#viewer-photo');if(image)image.classList.toggle('zoomed');},
  'previous-media': () => adjacentMedia(-1),
  'next-media': () => adjacentMedia(1),
  'save-file': () => {if(openItem)downloadFile(openItem.item);},
};
function adjacentMedia(direction) { if(!openItem)return;const items=openItem.remote ? remoteMedia() : ownMedia();const index=items.findIndex(item=>item.id===openItem.item.id);openMedia(items[(index+direction+items.length)%items.length].id,openItem.remote); }
document.addEventListener('click', event => {
  const element = event.target.closest('[data-action]');
  if (!element || element.disabled) return;
  actions[element.dataset.action]?.(element);
});
document.addEventListener('submit', event => {
  if(event.target.id!=='contact-form')return;
  event.preventDefault();
  const name = document.getElementById('contact-name').value.trim();
  if(!name)return;
  state.contact=name;setVerified(false);state.access='not-requested';state.transport='idle';state.route='people';closeDialog();commit();
});
document.addEventListener('input', event => {
  if(event.target.id==='media-search') {
    const position=event.target.selectionStart;
    state.query=event.target.value;persist();render();
    const input=document.getElementById('media-search');input.focus();input.setSelectionRange?.(position,position);
  }
  if(event.target.id==='uplink'){state.uplink=Number(event.target.value);document.getElementById('uplink-value').value=state.uplink;persist();}
});
document.addEventListener('change', event => {
  if(event.target.id==='media-sort'){state.sort=event.target.value;commit();}
  if(['file-picker','folder-picker'].includes(event.target.id)) {
    const files=[...event.target.files].filter(file=>/^(image|video)\//.test(file.type));
    for(const file of files) uploads.push({id:crypto.randomUUID(),name:file.name,downloadName:file.name,src:URL.createObjectURL(file),type:file.type.startsWith('video/')?'video':'photo',collection:'Added in this tab',size:`${(file.size/1048576).toFixed(1)} MB`,date:new Date(file.lastModified).toISOString().slice(0,10),owner:state.perspective});
    state.route='library';state.collection='all';state.query='';state.filter='all';commit();toast(`${files.length} local media ${files.length===1?'file':'files'} added. No upload or publication started.`);event.target.value='';
  }
});
dialog.addEventListener('close',()=>{
  if (dialog.open) return;
  rememberPlayback();
  if(lastFocus?.isConnected)lastFocus.focus({preventScroll:true});
  else document.getElementById('main')?.focus({preventScroll:true});
});
dialog.addEventListener('click',event=>{if(event.target===dialog){const box=dialog.getBoundingClientRect();if(event.clientX<box.left||event.clientX>box.right||event.clientY<box.top||event.clientY>box.bottom)closeDialog();}});
window.addEventListener('pagehide',()=>{for(const item of uploads)URL.revokeObjectURL(item.src);});
render();
