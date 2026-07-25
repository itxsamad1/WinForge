/*
 * WinForge front end.
 *
 * No build step and no framework on purpose: this has to run on a machine
 * where Node does not exist yet.
 */
(function () {
  'use strict';

  // ---------------------------------------------------------------- state

  var token = readToken();
  var catalog = { apps: [], categories: [], presets: [], isos: [], isoDefaultDir: '' };
  var installedByKey = {};
  var selected = new Set();
  var activeCategory = 'all';
  var searchTerm = '';
  var options = { gitName: '', gitEmail: '', vscodeExtensions: [], cursorExtensions: [] };
  var isoJobs = {}; // key -> { jobId, timer }
  var activityTimer = null;
  var activityOpen = false;

  var job = null;          // { id, steps, logOffsets, expanded, timer }

  var el = {
    search: document.getElementById('search'),
    refresh: document.getElementById('refresh-installed'),
    banners: document.getElementById('banner-area'),
    categoryNav: document.getElementById('category-nav'),
    presetList: document.getElementById('preset-list'),
    appGroups: document.getElementById('app-groups'),
    clearSelection: document.getElementById('clear-selection'),
    deselectAll: document.getElementById('deselect-all'),
    activityBtn: document.getElementById('activity-btn'),
    activityBadge: document.getElementById('activity-badge'),
    activityPanel: document.getElementById('activity-panel'),
    activityList: document.getElementById('activity-list'),
    activityRefresh: document.getElementById('activity-refresh'),
    selectionBar: document.getElementById('selection-bar'),
    selectionCount: document.getElementById('selection-count'),
    selectionLabel: document.getElementById('selection-label'),
    selectionNames: document.getElementById('selection-names'),
    installBtn: document.getElementById('install-btn'),
    configureBtn: document.getElementById('configure-btn'),
    optionsModal: document.getElementById('options-modal'),
    optGitName: document.getElementById('opt-git-name'),
    optGitEmail: document.getElementById('opt-git-email'),
    optVscodeExt: document.getElementById('opt-vscode-ext'),
    optionsClose: document.getElementById('options-close'),
    progressPanel: document.getElementById('progress-panel'),
    progressTitle: document.getElementById('progress-title'),
    progressSub: document.getElementById('progress-sub'),
    progressFill: document.getElementById('progress-fill'),
    progressPercent: document.getElementById('progress-percent'),
    progressPhase: document.getElementById('progress-phase'),
    progressElapsed: document.getElementById('progress-elapsed'),
    progressEta: document.getElementById('progress-eta'),
    progressSteps: document.getElementById('progress-steps'),
    progressSummary: document.getElementById('progress-summary'),
    progressClose: document.getElementById('progress-close')
  };

  var PHASE_LABELS = {
    starting: 'Starting',
    resolving: 'Finding package',
    downloading: 'Downloading',
    verifying: 'Verifying',
    installing: 'Installing',
    done: 'Done'
  };

  // Soft ceiling while a phase has no finer winget updates (avoids 2% → 70% jumps).
  var PHASE_SOFT_CAP = {
    starting: 12,
    resolving: 5,
    downloading: 68,
    verifying: 76,
    installing: 94
  };

  // ---------------------------------------------------------------- helpers

  function readToken() {
    var fromUrl = new URLSearchParams(window.location.search).get('token');
    if (fromUrl) {
      // Survive a manual refresh that drops the query string.
      try { sessionStorage.setItem('winforge-token', fromUrl); } catch (e) { /* private mode */ }
      return fromUrl;
    }
    try { return sessionStorage.getItem('winforge-token') || ''; } catch (e) { return ''; }
  }

  function api(path, init) {
    init = init || {};
    init.headers = Object.assign({ 'X-WinForge-Token': token }, init.headers || {});
    if (init.body != null && typeof init.body !== 'string') {
      init.body = JSON.stringify(init.body);
    }
    if (init.body) { init.headers['Content-Type'] = 'application/json'; }
    return fetch(path, init).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (data) {
        if (!response.ok) {
          var error = new Error(data.error || ('Request failed with status ' + response.status));
          error.detail = data.detail;
          throw error;
        }
        return data;
      });
    });
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function formatDuration(ms) {
    var total = Math.max(0, Math.round(ms / 1000));
    if (total < 60) { return total + 's'; }
    var minutes = Math.floor(total / 60);
    var seconds = total % 60;
    if (minutes < 60) { return minutes + 'm ' + seconds + 's'; }
    var hours = Math.floor(minutes / 60);
    minutes = minutes % 60;
    return hours + 'h ' + minutes + 'm';
  }

  function stepProgressValue(step) {
    if (step.state === 'done' || step.state === 'manual') { return 100; }
    if (step.state === 'failed') { return 100; }
    if (step.state === 'running') {
      var percent = typeof step.percent === 'number' ? step.percent : parseInt(step.percent, 10);
      if (isNaN(percent)) { percent = 8; }

      // When winget only reports milestones, ease the bar forward within the
      // current phase so a long download does not sit on 2% for minutes.
      if (job) {
        if (!job.softProgress) { job.softProgress = {}; }
        var key = step.key || String(step.index);
        var base = percent;
        var phase = step.phase || 'starting';
        var prev = job.softProgress[key];
        if (!prev || prev.base !== base || prev.phase !== phase) {
          job.softProgress[key] = { base: base, phase: phase, since: Date.now(), shown: base };
          prev = job.softProgress[key];
        }
        var cap = PHASE_SOFT_CAP[phase];
        if (typeof cap === 'number' && base < cap) {
          var elapsed = Date.now() - prev.since;
          var crawl = base + (cap - base) * (1 - Math.exp(-elapsed / 75000));
          percent = Math.max(prev.shown || base, Math.min(cap - 1, crawl));
          prev.shown = percent;
        } else {
          prev.shown = base;
          percent = base;
        }
      }

      return Math.max(0, Math.min(99, Math.round(percent)));
    }
    return 0;
  }

  function overallProgress(steps) {
    if (!steps || !steps.length) { return 0; }
    var sum = 0;
    steps.forEach(function (step) { sum += stepProgressValue(step); });
    return Math.round(sum / steps.length);
  }

  function updateProgressMeta(status) {
    var steps = status.steps || [];
    var overall = overallProgress(steps);
    var running = steps.filter(function (step) { return step.state === 'running'; })[0];
    var elapsedMs = job && job.startedAt ? (Date.now() - job.startedAt) : 0;

    if (el.progressPercent) { el.progressPercent.textContent = overall + '%'; }
    if (el.progressFill) { el.progressFill.style.width = overall + '%'; }
    if (el.progressElapsed) { el.progressElapsed.textContent = formatDuration(elapsedMs); }

    if (el.progressPhase) {
      if (running) {
        var phase = PHASE_LABELS[running.phase] || 'Working';
        var detail = running.progressDetail ? ' · ' + running.progressDetail : '';
        var stepPct = stepProgressValue(running);
        el.progressPhase.textContent = phase + ' · ' + running.name + ' · ' + stepPct + '%' + detail;
      } else if (status.state === 'finished' || status.state === 'failed') {
        el.progressPhase.textContent = status.state === 'failed' ? 'Finished with errors' : 'Complete';
      } else {
        el.progressPhase.textContent = 'Preparing';
      }
    }

    if (el.progressEta) {
      if (overall >= 5 && overall < 100 && elapsedMs > 2000) {
        var remaining = elapsedMs * (100 - overall) / overall;
        el.progressEta.textContent = '~' + formatDuration(remaining);
      } else if (overall >= 100) {
        el.progressEta.textContent = 'done';
      } else {
        el.progressEta.textContent = '—';
      }
    }
  }

  function showBanner(message, tone) {
    var div = document.createElement('div');
    div.className = 'banner banner-' + (tone || 'warn');
    div.innerHTML = message;
    el.banners.appendChild(div);
    return div;
  }

  // ---------------------------------------------------------------- activity

  function activityStateClass(state) {
    if (state === 'finished' || state === 'done') { return 'is-ok'; }
    if (state === 'failed') { return 'is-err'; }
    if (state === 'running' || state === 'queued' || state === 'starting' || state === 'awaiting_elevation') {
      return 'is-running';
    }
    return '';
  }

  function activityStateLabel(state) {
    if (state === 'awaiting_elevation') { return 'UAC'; }
    if (state === 'finished') { return 'Done'; }
    if (state === 'failed') { return 'Failed'; }
    if (state === 'running') { return 'Running'; }
    if (state === 'queued' || state === 'starting') { return 'Starting'; }
    return state || '';
  }

  function renderActivity(data) {
    if (!el.activityList) { return; }
    var active = data && typeof data.activeCount === 'number' ? data.activeCount : 0;
    if (el.activityBadge) {
      el.activityBadge.hidden = active <= 0;
      el.activityBadge.textContent = String(active);
    }
    if (el.activityBtn) {
      el.activityBtn.classList.toggle('has-active', active > 0);
    }

    var items = [];
    (data.isos || []).forEach(function (item) { items.push(item); });
    (data.installs || []).forEach(function (item) { items.push(item); });

    if (!items.length) {
      el.activityList.innerHTML = '<p class="activity-empty">Nothing running right now.</p>';
      return;
    }

    el.activityList.innerHTML = items.map(function (item) {
      var pct = typeof item.percent === 'number' ? item.percent : null;
      var msg = item.message || '';
      var speed = (item.kind === 'iso' && item.detail) ? item.detail : '';
      if (item.kind === 'install' && item.detail) {
        msg = msg ? msg : item.detail;
      }
      var bar = pct == null ? '' :
        '<div class="activity-item-bar"><div class="activity-item-fill" style="width:' + Math.max(0, Math.min(100, pct)) + '%"></div></div>';
      var metaClass = 'activity-item-meta ' + activityStateClass(item.state);
      return '<button type="button" class="activity-item" data-kind="' + escapeHtml(item.kind) +
        '" data-job="' + escapeHtml(item.jobId || '') + '" data-key="' + escapeHtml(item.key || '') + '">' +
        '<div class="activity-item-top">' +
        '<span class="activity-item-name">' + escapeHtml(item.name || 'Job') + '</span>' +
        '<span class="' + metaClass + '">' + escapeHtml(activityStateLabel(item.state)) +
        (pct != null ? ' · ' + pct + '%' : '') + '</span></div>' +
        '<div class="activity-item-row">' +
        '<span class="activity-item-msg">' + escapeHtml(msg) + '</span>' +
        (speed ? '<span class="activity-item-speed">' + escapeHtml(speed) + '</span>' : '') +
        '</div>' + bar + '</button>';
    }).join('');
  }

  function loadActivity() {
    return api('/api/activity').then(function (data) {
      renderActivity(data || { installs: [], isos: [], activeCount: 0 });
      return data;
    }).catch(function () { /* best-effort */ });
  }

  function openActivityPanel(open) {
    activityOpen = !!open;
    if (!el.activityPanel || !el.activityBtn) { return; }
    el.activityPanel.hidden = !activityOpen;
    el.activityBtn.setAttribute('aria-expanded', activityOpen ? 'true' : 'false');
    if (activityOpen) { loadActivity(); }
  }

  function scheduleActivityPoll() {
    if (activityTimer) { clearTimeout(activityTimer); }
    activityTimer = setTimeout(function () {
      loadActivity().finally(function () { scheduleActivityPoll(); });
    }, activityOpen ? 1200 : 4000);
  }

  function resumeInstallJob(jobId) {
    if (!jobId) { return; }
    if (job && job.id === jobId && job.timer) {
      el.progressPanel.hidden = false;
      return;
    }
    if (job && job.timer) { clearTimeout(job.timer); }
    job = {
      id: jobId,
      expanded: new Set(),
      logOffsets: {},
      lastState: {},
      timer: null,
      startedAt: Date.now(),
      softProgress: {}
    };
    el.progressPanel.hidden = false;
    el.progressTitle.textContent = 'Installing';
    el.progressSummary.hidden = true;
    el.progressClose.hidden = false;
    pollJob();
  }

  // ---------------------------------------------------------------- loading

  function loadCatalog() {
    return api('/api/catalog').then(function (data) {
      catalog = data;
      if (!data.wingetFound) {
        showBanner('<strong>winget was not found.</strong> Install "App Installer" from the Microsoft Store, then restart WinForge. Nothing can be installed until then.', 'err');
        el.installBtn.disabled = true;
      } else if (data.elevated) {
        showBanner('Running as Administrator — installs will not ask for a UAC prompt.', 'ok');
      }
      renderCategories();
      renderPresets();
      renderApps();
    });
  }

  function loadInstalled(force) {
    return api('/api/installed' + (force ? '?refresh=1' : '')).then(function (data) {
      installedByKey = data.apps || {};
      renderApps();
      // The authoritative winget list arrives ~13s after the first request, so
      // poll once more to pick it up without making the user press Rescan.
      if (!data.wingetCached) { setTimeout(function () { loadInstalled(false); }, 6000); }
    }).catch(function () { /* detection is best-effort */ });
  }

  // ---------------------------------------------------------------- render

  function appsInCategory(categoryId) {
    if (categoryId === 'os') { return catalog.isos || []; }
    return catalog.apps.filter(function (app) { return app.category === categoryId; });
  }

  function renderCategories() {
    var total = catalog.apps.length + (catalog.isos ? catalog.isos.length : 0);
    var html = '<button data-category="all" class="' + (activeCategory === 'all' ? 'active' : '') + '">' +
      '<span>All apps</span><span class="count">' + total + '</span></button>';

    catalog.categories.forEach(function (category) {
      var count = appsInCategory(category.id).length;
      if (!count) { return; }
      html += '<button data-category="' + escapeHtml(category.id) + '" class="' +
        (activeCategory === category.id ? 'active' : '') + '">' +
        '<span>' + escapeHtml(category.name) + '</span><span class="count">' + count + '</span></button>';
    });

    el.categoryNav.innerHTML = html;
  }

  function renderPresets() {
    el.presetList.innerHTML = catalog.presets.map(function (preset) {
      return '<button class="preset-chip" data-preset="' + escapeHtml(preset.key) + '" title="' +
        escapeHtml(preset.description || '') + '">' + escapeHtml(preset.name) +
        '<span class="chip-count">' + preset.apps.length + '</span></button>';
    }).join('');
  }

  function matchesSearch(app) {
    if (!searchTerm) { return true; }
    var haystack = (app.name + ' ' + (app.description || '') + ' ' + (app.id || '') + ' ' + app.key).toLowerCase();
    return searchTerm.split(/\s+/).every(function (word) { return haystack.indexOf(word) !== -1; });
  }

  function matchesIsoSearch(os) {
    if (!searchTerm) { return true; }
    var haystack = (os.name + ' ' + (os.description || '') + ' ' + os.key + ' ' + (os.family || '')).toLowerCase();
    return searchTerm.split(/\s+/).every(function (word) { return haystack.indexOf(word) !== -1; });
  }

  function availableArches(os, editionId) {
    var edition = (os.editions || []).filter(function (ed) { return ed.id === editionId; })[0];
    if (!edition) { return os.architectures || []; }
    if (os.source === 'portal') { return os.architectures || []; }
    var map = edition.architectures || {};
    return (os.architectures || []).filter(function (arch) { return !!map[arch.id]; });
  }

  function renderIsoCard(os) {
    var editions = os.editions || [];
    var defaultEdition = editions[0] ? editions[0].id : '';
    var arches = availableArches(os, defaultEdition);
    var defaultArch = arches[0] ? arches[0].id : '';
    var isPortal = os.source === 'portal';
    var dest = catalog.isoDefaultDir || '';

    var editionOpts = editions.map(function (ed) {
      return '<option value="' + escapeHtml(ed.id) + '">' + escapeHtml(ed.name) + '</option>';
    }).join('');

    var archOpts = arches.map(function (arch) {
      return '<option value="' + escapeHtml(arch.id) + '">' + escapeHtml(arch.name) + '</option>';
    }).join('');

    var note = os.notes ? '<div class="app-note">' + escapeHtml(os.notes) + '</div>' : '';
    var actionLabel = isPortal ? 'Open download page' : 'Download ISO';
    var destBlock = isPortal
      ? '<p class="iso-hint">Microsoft chooses the file on their site after you pick edition / arch there.</p>'
      : '<label class="iso-field">Save to<input type="text" class="iso-dest" value="' + escapeHtml(dest) + '" spellcheck="false"></label>';

    return '<div class="iso-card" data-iso="' + escapeHtml(os.key) + '" data-source="' + escapeHtml(os.source || 'direct') + '">' +
      '<div class="app-name">' + escapeHtml(os.name) + '</div>' +
      '<div class="app-desc">' + escapeHtml(os.description || '') + '</div>' +
      note +
      '<div class="iso-controls">' +
      '<label class="iso-field">Edition<select class="iso-edition">' + editionOpts + '</select></label>' +
      '<label class="iso-field">CPU / arch<select class="iso-arch">' + archOpts + '</select></label>' +
      destBlock +
      '<button type="button" class="primary-btn iso-download">' + actionLabel + '</button>' +
      '<div class="iso-status" hidden><span class="iso-status-msg"></span><span class="iso-status-speed"></span></div>' +
      '<div class="iso-progress" hidden><div class="iso-progress-fill"></div></div>' +
      '</div></div>';
  }

  function renderApps() {
    var visible = catalog.apps.filter(function (app) {
      if (activeCategory === 'os') { return false; }
      if (activeCategory !== 'all' && app.category !== activeCategory) { return false; }
      return matchesSearch(app);
    });

    var visibleIsos = (catalog.isos || []).filter(function (os) {
      if (activeCategory !== 'all' && activeCategory !== 'os') { return false; }
      return matchesIsoSearch(os);
    });

    if (!visible.length && !visibleIsos.length) {
      el.appGroups.innerHTML = '<div class="empty-state">No apps match "' + escapeHtml(searchTerm) + '".</div>';
      return;
    }

    var groups = [];
    if (searchTerm) {
      if (visible.length) {
        groups.push({ id: 'results', name: 'Results', apps: visible, isos: [] });
      }
      if (visibleIsos.length) {
        groups.push({ id: 'os', name: 'Operating Systems', apps: [], isos: visibleIsos });
      }
    } else if (activeCategory === 'os') {
      groups.push({ id: 'os', name: 'Operating Systems', apps: [], isos: visibleIsos });
    } else {
      if (activeCategory === 'all' && visibleIsos.length) {
        groups.push({ id: 'os', name: 'Operating Systems', apps: [], isos: visibleIsos });
      }
      catalog.categories.forEach(function (category) {
        if (category.id === 'os') { return; }
        var apps = visible.filter(function (app) { return app.category === category.id; });
        if (apps.length) { groups.push({ id: category.id, name: category.name, apps: apps, isos: [] }); }
      });
    }

    el.appGroups.innerHTML = groups.map(function (group) {
      var body = (group.isos && group.isos.length)
        ? '<div class="iso-grid">' + group.isos.map(renderIsoCard).join('') + '</div>'
        : '<div class="app-grid">' + group.apps.map(renderCard).join('') + '</div>';
      return '<section class="app-group" id="group-' + escapeHtml(group.id) + '">' +
        '<div class="group-head"><h2>' + escapeHtml(group.name) + '</h2>' +
        '<span class="group-count">' + ((group.isos && group.isos.length) || group.apps.length) + '</span></div>' +
        body + '</section>';
    }).join('');
    restoreIsoJobsFromActivity();
  }

  function attachIsoJobToCard(key, jobId, opts) {
    opts = opts || {};
    var card = el.appGroups.querySelector('.iso-card[data-iso="' + CSS.escape(key) + '"]');
    if (!card) { return; }
    var btn = card.querySelector('.iso-download');
    if (btn) { btn.disabled = true; }
    if (opts.message) { setIsoStatus(card, opts.message); }
    setIsoProgress(card, typeof opts.percent === 'number' ? opts.percent : 1);
    if (isoJobs[key] && isoJobs[key].timer) { clearTimeout(isoJobs[key].timer); }
    isoJobs[key] = { jobId: jobId, timer: null };
    pollIsoJob(card, jobId);
  }

  function restoreIsoJobsFromActivity() {
    api('/api/activity').then(function (data) {
      renderActivity(data || { installs: [], isos: [], activeCount: 0 });
      (data.isos || []).forEach(function (item) {
        if (!item.key || !item.jobId) { return; }
        var active = item.state === 'running' || item.state === 'queued' || item.alive;
        if (!active) { return; }
        if (isoJobs[item.key] && isoJobs[item.key].jobId === item.jobId) { return; }
        attachIsoJobToCard(item.key, item.jobId, {
          message: item.message || 'Downloading…',
          percent: item.percent
        });
      });
    }).catch(function () { /* best-effort */ });
  }

  function refreshIsoArchOptions(card) {
    var key = card.getAttribute('data-iso');
    var os = (catalog.isos || []).filter(function (item) { return item.key === key; })[0];
    if (!os) { return; }
    var editionSel = card.querySelector('.iso-edition');
    var archSel = card.querySelector('.iso-arch');
    if (!editionSel || !archSel) { return; }
    var arches = availableArches(os, editionSel.value);
    var previous = archSel.value;
    archSel.innerHTML = arches.map(function (arch) {
      return '<option value="' + escapeHtml(arch.id) + '">' + escapeHtml(arch.name) + '</option>';
    }).join('');
    if (arches.some(function (arch) { return arch.id === previous; })) {
      archSel.value = previous;
    }
  }

  function setIsoStatus(card, text, tone, speed) {
    var status = card.querySelector('.iso-status');
    if (!status) { return; }
    var msg = status.querySelector('.iso-status-msg');
    var spd = status.querySelector('.iso-status-speed');
    status.hidden = !text;
    if (msg) { msg.textContent = text || ''; }
    else { status.textContent = text || ''; }
    if (spd) {
      spd.textContent = speed || '';
      spd.hidden = !speed;
    }
    status.className = 'iso-status' + (tone ? ' iso-status-' + tone : '');
  }

  function setIsoProgress(card, percent) {
    var bar = card.querySelector('.iso-progress');
    var fill = card.querySelector('.iso-progress-fill');
    if (!bar || !fill) { return; }
    if (percent == null) {
      bar.hidden = true;
      return;
    }
    bar.hidden = false;
    fill.style.width = Math.max(0, Math.min(100, percent)) + '%';
  }

  function pollIsoJob(card, jobId) {
    var key = card.getAttribute('data-iso');
    api('/api/iso/job/' + encodeURIComponent(jobId)).then(function (state) {
      setIsoProgress(card, typeof state.percent === 'number' ? state.percent : 0);
      setIsoStatus(
        card,
        state.message || 'Downloading…',
        state.state === 'failed' ? 'err' : null,
        state.state === 'running' ? (state.speed || '') : ''
      );
      if (state.state === 'finished') {
        setIsoProgress(card, 100);
        setIsoStatus(card, 'Saved to ' + (state.destPath || 'Downloads'), 'ok');
        var btn = card.querySelector('.iso-download');
        if (btn) { btn.disabled = false; }
        if (isoJobs[key] && isoJobs[key].timer) { clearTimeout(isoJobs[key].timer); }
        delete isoJobs[key];
        return;
      }
      if (state.state === 'failed') {
        var failBtn = card.querySelector('.iso-download');
        if (failBtn) { failBtn.disabled = false; }
        if (isoJobs[key] && isoJobs[key].timer) { clearTimeout(isoJobs[key].timer); }
        delete isoJobs[key];
        return;
      }
      isoJobs[key] = { jobId: jobId, timer: setTimeout(function () { pollIsoJob(card, jobId); }, 700) };
    }).catch(function (error) {
      setIsoStatus(card, error.message || 'Lost contact with download', 'err');
      var btn = card.querySelector('.iso-download');
      if (btn) { btn.disabled = false; }
    });
  }

  function startIsoDownload(card) {
    var key = card.getAttribute('data-iso');
    var edition = card.querySelector('.iso-edition');
    var arch = card.querySelector('.iso-arch');
    var dest = card.querySelector('.iso-dest');
    var btn = card.querySelector('.iso-download');
    if (!edition || !arch || !btn) { return; }

    btn.disabled = true;
    setIsoStatus(card, 'Starting…');
    setIsoProgress(card, card.getAttribute('data-source') === 'direct' ? 1 : null);

    var body = {
      key: key,
      edition: edition.value,
      arch: arch.value,
      destDir: dest ? dest.value.trim() : ''
    };

    api('/api/iso/download', { method: 'POST', body: body }).then(function (data) {
      if (data.mode === 'portal') {
        setIsoProgress(card, null);
        setIsoStatus(card, data.message || 'Opened Microsoft download page.', 'ok');
        btn.disabled = false;
        return;
      }
      if (data.reattached) {
        setIsoStatus(card, 'Reconnected to download already in progress…');
      } else {
        setIsoStatus(card, 'Downloading to ' + (data.destDir || '') + '…');
      }
      if (isoJobs[key] && isoJobs[key].timer) { clearTimeout(isoJobs[key].timer); }
      isoJobs[key] = { jobId: data.jobId, timer: null };
      pollIsoJob(card, data.jobId);
      loadActivity();
    }).catch(function (error) {
      setIsoProgress(card, null);
      setIsoStatus(card, error.message || 'Could not start download', 'err');
      btn.disabled = false;
    });
  }

  function renderCard(app) {
    var state = installedByKey[app.key];
    var isInstalled = state && state.installed;
    var classes = ['app-card'];
    if (selected.has(app.key)) { classes.push('selected'); }
    if (isInstalled) { classes.push('installed'); }

    var tag = '';
    if (app.kind === 'manual') { tag = '<span class="app-tag">Manual step</span>'; }
    else if (app.kind === 'script') { tag = '<span class="app-tag">Script</span>'; }

    var note = app.notes ? '<div class="app-note">' + escapeHtml(app.notes) + '</div>' : '';

    return '<div class="' + classes.join(' ') + '" data-key="' + escapeHtml(app.key) + '" role="checkbox" ' +
      'tabindex="0" aria-checked="' + (selected.has(app.key) ? 'true' : 'false') + '">' +
      '<div class="checkbox"></div>' +
      '<div class="app-body">' +
      '<div class="app-name">' + escapeHtml(app.name) + '</div>' +
      '<div class="app-desc">' + escapeHtml(app.description || '') + '</div>' +
      note + tag +
      '</div></div>';
  }

  function renderSelection() {
    var count = selected.size;
    el.selectionBar.hidden = count === 0;
    el.selectionCount.textContent = count;
    el.selectionLabel.textContent = count === 1 ? 'app selected' : 'apps selected';

    var names = catalog.apps
      .filter(function (app) { return selected.has(app.key); })
      .map(function (app) { return app.name; });
    el.selectionNames.textContent = names.length ? names.join(', ') : '';
  }

  function toggleApp(key) {
    if (selected.has(key)) { selected.delete(key); } else { selected.add(key); }
    var card = el.appGroups.querySelector('[data-key="' + CSS.escape(key) + '"]');
    if (card) {
      card.classList.toggle('selected', selected.has(key));
      card.setAttribute('aria-checked', selected.has(key) ? 'true' : 'false');
    }
    renderSelection();
  }

  // ---------------------------------------------------------------- install

  function startInstall() {
    var keys = Array.from(selected);
    if (!keys.length) { return; }

    readOptionsFromForm();
    el.installBtn.disabled = true;
    el.progressSub.textContent = catalog.elevated
      ? 'Starting installer...'
      : 'Look for the Windows security prompt — it may be behind this window.';
    el.progressTitle.textContent = 'Installing';
    el.progressSummary.hidden = true;
    el.progressSummary.innerHTML = '';
    el.progressClose.hidden = false;
    el.progressFill.style.width = '0%';
    el.progressSteps.innerHTML = '';
    el.progressPanel.hidden = false;
    if (el.progressPercent) { el.progressPercent.textContent = '0%'; }
    if (el.progressPhase) { el.progressPhase.textContent = 'Starting'; }
    if (el.progressElapsed) { el.progressElapsed.textContent = '0s'; }
    if (el.progressEta) { el.progressEta.textContent = '—'; }

    api('/api/install', {
      method: 'POST',
      body: JSON.stringify({ apps: keys, options: options })
    }).then(function (data) {
      job = {
        id: data.jobId,
        expanded: new Set(),
        logOffsets: {},
        lastState: {},
        timer: null,
        startedAt: Date.now()
      };
      if (data.needsElevation) {
        el.progressSub.textContent = 'Accept the Windows security prompt if it appears (Alt+Tab if you do not see it).';
      } else {
        el.progressSub.textContent = 'Running ' + data.steps.length + ' step' + (data.steps.length === 1 ? '' : 's') + '.';
      }
      pollJob();
      loadActivity();
    }).catch(function (error) {
      el.progressTitle.textContent = 'Could not start';
      el.progressSub.textContent = error.message;
      el.progressClose.hidden = false;
      el.installBtn.disabled = false;
    });
  }

  function pollJob() {
    if (!job) { return; }

    // Always stream the running step; also stream anything the user expanded.
    var wanted = new Set(job.expanded);
    if (job.activeIndex != null) { wanted.add(job.activeIndex); }
    var tail = Array.from(wanted);
    var since = tail.map(function (index) { return job.logOffsets[index] || 0; });

    var query = '/api/job/' + encodeURIComponent(job.id);
    if (tail.length) { query += '?tail=' + tail.join(',') + '&since=' + since.join(','); }

    api(query).then(function (data) {
      renderJob(data);
      var finished = data.status.state === 'finished' || data.status.state === 'failed';
      if (!finished) {
        job.timer = setTimeout(pollJob, 500);
      } else if (data.status.launchError) {
        // Already surfaced by renderJob; just unlock the UI.
        el.progressClose.hidden = false;
        el.installBtn.disabled = false;
        job.timer = null;
      } else {
        finishJob(data.status);
      }
    }).catch(function (error) {
      el.progressSub.textContent = 'Lost contact with the installer: ' + error.message;
      el.progressClose.hidden = false;
      el.installBtn.disabled = false;
    });
  }

  function renderJob(data) {
    var status = data.status;
    var steps = status.steps || [];

    if (status.state === 'awaiting_elevation') {
      el.progressSub.textContent = 'Accept the Windows security prompt if it appears (Alt+Tab if you do not see it).';
    } else if (status.state === 'starting') {
      el.progressSub.textContent = 'Starting installer...';
    } else if (status.state === 'failed' && status.launchError) {
      el.progressTitle.textContent = 'Could not start';
      el.progressSub.textContent = status.launchError;
      el.progressClose.hidden = false;
      el.installBtn.disabled = false;
    }

    var doneCount = steps.filter(function (step) {
      return step.state === 'done' || step.state === 'failed' || step.state === 'manual';
    }).length;

    updateProgressMeta(status);

    var running = steps.filter(function (step) { return step.state === 'running'; })[0];
    job.activeIndex = running ? running.index : null;

    if (running) {
      var stepPct = stepProgressValue(running);
      var phase = PHASE_LABELS[running.phase] || 'Installing';
      el.progressSub.textContent = phase + ' ' + running.name + ' — ' + stepPct + '% (' + (doneCount + 1) + ' of ' + steps.length + ')';
      // Follow the active step automatically so the user always sees live output.
      job.expanded.add(running.index);
    }

    steps.forEach(function (step) { renderStep(step); });

    // Append any new log lines returned this tick.
    Object.keys(data.logs || {}).forEach(function (indexKey) {
      var chunk = data.logs[indexKey];
      if (!chunk || !chunk.lines || !chunk.lines.length) {
        if (chunk) { job.logOffsets[indexKey] = chunk.total; }
        return;
      }
      var pre = document.getElementById('log-' + indexKey);
      if (pre) {
        var atBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 40;
        pre.textContent += chunk.lines.join('\n') + '\n';
        if (atBottom) { pre.scrollTop = pre.scrollHeight; }
      }
      job.logOffsets[indexKey] = chunk.total;
    });
  }

  function renderStep(step) {
    var existing = document.getElementById('step-' + step.index);
    var pct = stepProgressValue(step);
    var phase = PHASE_LABELS[step.phase] || '';
    var detail = step.progressDetail || '';

    if (!existing) {
      var li = document.createElement('li');
      li.className = 'step';
      li.id = 'step-' + step.index;
      li.setAttribute('data-state', step.state);
      li.innerHTML =
        '<div class="step-head" data-index="' + step.index + '">' +
        '<span class="step-icon"></span>' +
        '<div class="step-main">' +
        '<div class="step-title-row">' +
        '<span class="step-name">' + escapeHtml(step.name) + '</span>' +
        '<span class="step-pct" id="pct-' + step.index + '"></span>' +
        '</div>' +
        '<div class="step-track"><div class="step-track-fill" id="fill-' + step.index + '"></div></div>' +
        '<div class="step-phase" id="phase-' + step.index + '"></div>' +
        '</div>' +
        '<span class="step-msg" id="msg-' + step.index + '"></span>' +
        '</div>' +
        '<pre class="step-log" id="log-' + step.index + '" hidden></pre>';
      el.progressSteps.appendChild(li);
      existing = li;
    }

    existing.setAttribute('data-state', step.state);
    var message = document.getElementById('msg-' + step.index);
    if (message) { message.textContent = step.message || ''; }

    var pctEl = document.getElementById('pct-' + step.index);
    if (pctEl) {
      if (step.state === 'pending') { pctEl.textContent = ''; }
      else if (step.state === 'done') { pctEl.textContent = '100%'; }
      else if (step.state === 'failed') { pctEl.textContent = 'failed'; }
      else if (step.state === 'manual') { pctEl.textContent = 'manual'; }
      else { pctEl.textContent = pct + '%'; }
    }

    var fill = document.getElementById('fill-' + step.index);
    if (fill) { fill.style.width = pct + '%'; }

    var phaseEl = document.getElementById('phase-' + step.index);
    if (phaseEl) {
      if (step.state === 'running') {
        phaseEl.textContent = (phase || 'Working') + (detail ? ' · ' + detail : '');
      } else {
        phaseEl.textContent = '';
      }
    }

    var log = document.getElementById('log-' + step.index);
    if (log) { log.hidden = !job.expanded.has(step.index); }
  }

  function finishJob(status) {
    var steps = status.steps || [];
    var failed = steps.filter(function (step) { return step.state === 'failed'; });
    var manual = steps.filter(function (step) { return step.state === 'manual'; });
    var done = steps.filter(function (step) { return step.state === 'done'; });

    el.progressFill.style.width = '100%';
    if (el.progressPercent) { el.progressPercent.textContent = '100%'; }
    if (el.progressEta) { el.progressEta.textContent = 'done'; }
    updateProgressMeta(status);
    el.progressTitle.textContent = failed.length ? 'Finished with problems' : 'All done';
    el.progressSub.textContent = done.length + ' of ' + steps.length + ' installed successfully.';
    el.progressClose.hidden = false;
    el.installBtn.disabled = false;

    var items = [];
    if (done.length) {
      items.push('<li class="tone-ok">' + done.length + ' app' + (done.length === 1 ? '' : 's') + ' installed.</li>');
    }
    items.push('<li>Open a <strong>new</strong> terminal before using the new commands. Existing windows still hold the old PATH.</li>');
    if (status.rebootNeeded) {
      items.push('<li class="tone-warn">A restart is required before some of these will work.</li>');
    }
    manual.forEach(function (step) {
      items.push('<li class="tone-warn">' + escapeHtml(step.name) + ' needs a manual step. Expand it above for instructions.</li>');
    });
    failed.forEach(function (step) {
      items.push('<li class="tone-err">' + escapeHtml(step.name) + ' failed: ' + escapeHtml(step.message || 'unknown error') + '</li>');
    });

    el.progressSummary.innerHTML = '<h3>What next</h3><ul>' + items.join('') + '</ul>';
    el.progressSummary.hidden = false;

    job.timer = null;
    loadInstalled(true);
  }

  // ---------------------------------------------------------------- options

  function readOptionsFromForm() {
    options.gitName = el.optGitName.value.trim();
    options.gitEmail = el.optGitEmail.value.trim();
    options.vscodeExtensions = el.optVscodeExt.value
      .split(/[\s,]+/)
      .map(function (value) { return value.trim(); })
      .filter(Boolean);
    // Cursor is a VS Code fork and takes the same marketplace ids.
    options.cursorExtensions = options.vscodeExtensions.slice();
  }

  // ---------------------------------------------------------------- events

  el.categoryNav.addEventListener('click', function (event) {
    var button = event.target.closest('button[data-category]');
    if (!button) { return; }
    activeCategory = button.getAttribute('data-category');
    renderCategories();
    renderApps();
  });

  el.presetList.addEventListener('click', function (event) {
    var chip = event.target.closest('[data-preset]');
    if (!chip) { return; }
    var preset = catalog.presets.filter(function (item) { return item.key === chip.getAttribute('data-preset'); })[0];
    if (!preset) { return; }
    preset.apps.forEach(function (key) { selected.add(key); });
    renderApps();
    renderSelection();
  });

  el.appGroups.addEventListener('click', function (event) {
    if (event.target.closest('.iso-card')) {
      if (event.target.closest('.iso-download')) {
        event.preventDefault();
        startIsoDownload(event.target.closest('.iso-card'));
      }
      return;
    }
    var card = event.target.closest('.app-card');
    if (card) { toggleApp(card.getAttribute('data-key')); }
  });

  el.appGroups.addEventListener('change', function (event) {
    var card = event.target.closest('.iso-card');
    if (!card) { return; }
    if (event.target.classList.contains('iso-edition')) {
      refreshIsoArchOptions(card);
    }
  });

  el.appGroups.addEventListener('keydown', function (event) {
    if (event.target.closest('.iso-card')) { return; }
    if (event.key !== 'Enter' && event.key !== ' ') { return; }
    var card = event.target.closest('.app-card');
    if (!card) { return; }
    event.preventDefault();
    toggleApp(card.getAttribute('data-key'));
  });

  el.search.addEventListener('input', function () {
    searchTerm = el.search.value.trim().toLowerCase();
    renderApps();
  });

  document.addEventListener('keydown', function (event) {
    if (event.key === '/' && document.activeElement !== el.search) {
      event.preventDefault();
      el.search.focus();
      el.search.select();
    }
    if (event.key === 'Escape') {
      if (activityOpen) { openActivityPanel(false); }
      else if (!el.optionsModal.hidden) { el.optionsModal.hidden = true; }
      else if (!el.progressPanel.hidden && !el.progressClose.hidden) { el.progressPanel.hidden = true; }
    }
  });

  function clearAllSelection() {
    selected.clear();
    renderApps();
    renderSelection();
  }

  el.clearSelection.addEventListener('click', clearAllSelection);
  if (el.deselectAll) {
    el.deselectAll.addEventListener('click', clearAllSelection);
  }

  el.refresh.addEventListener('click', function () {
    el.refresh.textContent = 'Scanning...';
    loadInstalled(true).then(function () {
      setTimeout(function () {
        loadInstalled(false).then(function () { el.refresh.textContent = 'Rescan'; });
      }, 14000);
    });
  });

  el.configureBtn.addEventListener('click', function () { el.optionsModal.hidden = false; });
  el.optionsClose.addEventListener('click', function () {
    readOptionsFromForm();
    el.optionsModal.hidden = true;
  });
  el.optionsModal.addEventListener('click', function (event) {
    if (event.target === el.optionsModal) { el.optionsModal.hidden = true; }
  });

  el.installBtn.addEventListener('click', startInstall);

  if (el.activityBtn) {
    el.activityBtn.addEventListener('click', function (event) {
      event.stopPropagation();
      openActivityPanel(el.activityPanel.hidden);
    });
  }
  if (el.activityRefresh) {
    el.activityRefresh.addEventListener('click', function (event) {
      event.stopPropagation();
      loadActivity();
    });
  }
  if (el.activityList) {
    el.activityList.addEventListener('click', function (event) {
      var item = event.target.closest('.activity-item');
      if (!item) { return; }
      var kind = item.getAttribute('data-kind');
      var jobId = item.getAttribute('data-job');
      openActivityPanel(false);
      if (kind === 'install') {
        resumeInstallJob(jobId);
      } else if (kind === 'iso') {
        activeCategory = 'os';
        renderCategories();
        renderApps();
        var key = null;
        // Prefer matching card from activity payload via data attributes on button
        var isoKey = item.getAttribute('data-key');
        if (isoKey) {
          attachIsoJobToCard(isoKey, jobId, { message: 'Reconnected…' });
        }
        var group = document.getElementById('group-os');
        if (group) { group.scrollIntoView({ behavior: 'smooth', block: 'start' }); }
      }
    });
  }
  document.addEventListener('click', function (event) {
    if (!activityOpen) { return; }
    if (event.target.closest('.activity-wrap')) { return; }
    openActivityPanel(false);
  });

  el.progressClose.addEventListener('click', function () {
    el.progressPanel.hidden = true;
    // Keep polling in the background so Activity stays up to date.
  });

  el.progressSteps.addEventListener('click', function (event) {
    var head = event.target.closest('.step-head');
    if (!head || !job) { return; }
    var index = parseInt(head.getAttribute('data-index'), 10);
    if (job.expanded.has(index)) { job.expanded.delete(index); } else { job.expanded.add(index); }
    var log = document.getElementById('log-' + index);
    if (log) { log.hidden = !job.expanded.has(index); }
  });

  // ---------------------------------------------------------------- boot

  if (!token) {
    showBanner('<strong>No session token.</strong> Open WinForge through <code>WinForge.cmd</code> rather than typing the address by hand.', 'err');
  }

  loadCatalog()
    .then(function () { return loadInstalled(false); })
    .then(function () { return loadActivity(); })
    .then(function () { scheduleActivityPoll(); })
    .catch(function (error) {
      el.appGroups.innerHTML = '<div class="empty-state">Could not load the catalog: ' + escapeHtml(error.message) + '</div>';
    });
})();
