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
  var catalog = { apps: [], categories: [], presets: [] };
  var installedByKey = {};
  var selected = new Set();
  var activeCategory = 'all';
  var searchTerm = '';
  var options = { gitName: '', gitEmail: '', vscodeExtensions: [], cursorExtensions: [] };

  var job = null;          // { id, steps, logOffsets, expanded, timer }

  var el = {
    search: document.getElementById('search'),
    refresh: document.getElementById('refresh-installed'),
    banners: document.getElementById('banner-area'),
    categoryNav: document.getElementById('category-nav'),
    presetList: document.getElementById('preset-list'),
    appGroups: document.getElementById('app-groups'),
    clearSelection: document.getElementById('clear-selection'),
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
      return isNaN(percent) ? 8 : Math.max(0, Math.min(99, percent));
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
    return catalog.apps.filter(function (app) { return app.category === categoryId; });
  }

  function renderCategories() {
    var html = '<button data-category="all" class="' + (activeCategory === 'all' ? 'active' : '') + '">' +
      '<span>All apps</span><span class="count">' + catalog.apps.length + '</span></button>';

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

  function renderApps() {
    var visible = catalog.apps.filter(function (app) {
      if (activeCategory !== 'all' && app.category !== activeCategory) { return false; }
      return matchesSearch(app);
    });

    if (!visible.length) {
      el.appGroups.innerHTML = '<div class="empty-state">No apps match "' + escapeHtml(searchTerm) + '".</div>';
      return;
    }

    // Searching flattens the grouping: when you type "docker" you want one
    // list of hits, not a category outline with a single card in it.
    var groups = [];
    if (searchTerm) {
      groups.push({ id: 'results', name: 'Results', apps: visible });
    } else {
      catalog.categories.forEach(function (category) {
        var apps = visible.filter(function (app) { return app.category === category.id; });
        if (apps.length) { groups.push({ id: category.id, name: category.name, apps: apps }); }
      });
    }

    el.appGroups.innerHTML = groups.map(function (group) {
      return '<section class="app-group" id="group-' + escapeHtml(group.id) + '">' +
        '<div class="group-head"><h2>' + escapeHtml(group.name) + '</h2>' +
        '<span class="group-count">' + group.apps.length + '</span></div>' +
        '<div class="app-grid">' + group.apps.map(renderCard).join('') + '</div></section>';
    }).join('');
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
    var card = event.target.closest('.app-card');
    if (card) { toggleApp(card.getAttribute('data-key')); }
  });

  el.appGroups.addEventListener('keydown', function (event) {
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
      if (!el.optionsModal.hidden) { el.optionsModal.hidden = true; }
      else if (!el.progressPanel.hidden && !el.progressClose.hidden) { el.progressPanel.hidden = true; }
    }
  });

  el.clearSelection.addEventListener('click', function () {
    selected.clear();
    renderApps();
    renderSelection();
  });

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

  el.progressClose.addEventListener('click', function () {
    el.progressPanel.hidden = true;
    if (job && job.timer) { clearTimeout(job.timer); }
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
    .catch(function (error) {
      el.appGroups.innerHTML = '<div class="empty-state">Could not load the catalog: ' + escapeHtml(error.message) + '</div>';
    });
})();
