(() => {
  'use strict';

  const TOKEN = new URLSearchParams(window.location.search).get('k') || '';
  if (TOKEN) window.history.replaceState(null, '', '/');
  let nativeRequestID = 0;
  const nativeRequests = new Map();
  window.__x6NativeReply = (requestID, encodedJSON) => {
    const pending = nativeRequests.get(requestID);
    if (!pending) return;
    nativeRequests.delete(requestID);
    try {
      const binary = atob(encodedJSON);
      const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
      const result = JSON.parse(new TextDecoder().decode(bytes));
      if (!result.ok) {
        const error = new Error(result.message || result.error || 'Ошибка X6 Control');
        error.payload = result;
        pending.reject(error);
      } else pending.resolve(result);
    } catch (error) { pending.reject(error); }
  };

  const defaults = {
    dpi: { stages: [800, 1200, 1600, 3200, 5600, 26000], activeStage: 2, angleSnap: false, rippleControl: false, lodMm: 2 },
    pollingHz: 1000,
    lighting: { mode: 'breathing', color: '#00FF00', speed: 6, sleepMinutes: 0.5, debounceMs: 8 },
    buttons: ['left', 'right', 'middle', 'forward', 'backward', 'dpi_plus', 'dpi_minus'],
  };

  const modeInfo = {
    off: { name: 'Выключено', note: 'LED не горит', icon: '◌', color: '#909a89', preview: 'Подсветка выключена' },
    fixed: { name: 'Постоянный', note: 'Ровное свечение', icon: '●', color: '#c9ff59', preview: 'Постоянный свет' },
    breathing: { name: 'Дыхание', note: 'Плавный импульс', icon: '◒', color: '#69e58a', preview: 'Дыхание' },
    neon: { name: 'Неон', note: 'Динамический эффект', icon: 'ϟ', color: '#71a6ff', preview: 'Неон' },
    color_cycle: { name: 'Смена цветов', note: 'Цветовой цикл', icon: '◉', color: '#e391ff', preview: 'Смена цветов' },
    dpi_static: { name: 'Цвет по DPI', note: 'Цвет активного уровня', icon: '◈', color: '#ffbd70', preview: 'Цвет по DPI' },
    dpi_breathing: { name: 'Дыхание по DPI', note: 'Пульс по уровню DPI', icon: '✳', color: '#85b5ff', preview: 'Дыхание по DPI' },
  };
  const swatches = [
    { color: '#00FF00', label: 'Зелёный' }, { color: '#F95EF9', label: 'Фиолетовый' },
    { color: '#007FFF', label: 'Голубой' }, { color: '#00FFFF', label: 'Бирюзовый' },
    { color: '#FF7F00', label: 'Оранжевый' }, { color: '#FFFFFF', label: 'Белый' },
  ];
  const stageColors = ['#ff5555', '#70e18d', '#7897ff', '#f5d96b', '#50dbd2', '#df7df0'];
  const buttons = [
    { name: 'Левый клик', detail: 'Левая основная', default: 'left' },
    { name: 'Правый клик', detail: 'Правая основная', default: 'right' },
    { name: 'Нажатие колеса', detail: 'Средняя кнопка', default: 'middle' },
    { name: 'Кнопка вперёд', detail: 'Боковая · передняя', default: 'forward' },
    { name: 'Кнопка назад', detail: 'Боковая · задняя', default: 'backward' },
    { name: 'DPI +', detail: 'За колесом · верхняя', default: 'dpi_plus' },
    { name: 'DPI −', detail: 'За колесом · нижняя', default: 'dpi_minus' },
  ];
  const actionGroups = [
    { label: 'ОСНОВНОЕ', items: [['left', 'Левый клик'], ['right', 'Правый клик'], ['middle', 'Нажатие колеса'], ['backward', 'Назад'], ['forward', 'Вперёд'], ['double_click', 'Двойной клик'], ['fire', 'Fire'], ['off', 'Отключено']] },
    { label: 'УПРАВЛЕНИЕ МЫШЬЮ', items: [['scroll_up', 'Прокрутка вверх'], ['scroll_down', 'Прокрутка вниз'], ['dpi_cycle', 'Следующий DPI'], ['dpi_plus', 'DPI +'], ['dpi_minus', 'DPI −']] },
    { label: 'МУЛЬТИМЕДИА', items: [['media_player', 'Медиаплеер'], ['play_pause', 'Пуск / пауза'], ['stop', 'Стоп'], ['previous_track', 'Предыдущий трек'], ['next_track', 'Следующий трек'], ['volume_up', 'Громкость +'], ['volume_down', 'Громкость −'], ['mute', 'Без звука']] },
    { label: 'БРАУЗЕР И СИСТЕМА', items: [['browser_calculator', 'Калькулятор'], ['browser_email', 'Почта'], ['browser_forward', 'Вперёд в браузере'], ['browser_backward', 'Назад в браузере'], ['browser_stop', 'Остановить загрузку'], ['browser_computer', 'Этот компьютер'], ['browser_refresh', 'Обновить страницу'], ['browser_home', 'Домашняя страница'], ['browser_search', 'Поиск']] },
  ];

  const app = {
    devices: [], selected: null, deviceKey: '', online: false,
    profile: clone(defaults), profileID: '', profileName: 'Предпросмотр', profileList: [],
    activePage: 'overview', selectedStage: 2, dirty: new Set(), busy: false,
    saveTimer: null, saveQueue: Promise.resolve(), saveRevision: 0,
    dialogResolve: null, dialogAction: null,
  };

  function clone(value) { return JSON.parse(JSON.stringify(value)); }
  function byId(id) { return document.getElementById(id); }
  function escapeHTML(value) {
    return String(value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char]);
  }
  function formatNumber(value) { return Number(value).toLocaleString('ru-RU'); }
  function formatHalf(value) { return Number(value).toLocaleString('ru-RU', { minimumFractionDigits: Number.isInteger(value) ? 0 : 1, maximumFractionDigits: 1 }); }
  function modeName(mode) { return (modeInfo[mode] || modeInfo.breathing).name; }
  function selectedDeviceParams() {
    return { locationID: app.selected ? app.selected.locationID : '', deviceKey: app.deviceKey, profileID: app.profileID };
  }

  function readLocal(key) {
    try { return window.localStorage.getItem(key) || ''; } catch (_) { return ''; }
  }
  function writeLocal(key, value) {
    try { window.localStorage.setItem(key, String(value)); } catch (_) { /* Device selection is optional. */ }
  }

  async function request(path, options = {}) {
    const nativeHandler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.x6Native;
    if (nativeHandler) {
      const id = ++nativeRequestID;
      const body = options.body ? JSON.parse(options.body) : null;
      const result = await new Promise((resolve, reject) => {
        nativeRequests.set(id, { resolve, reject });
        nativeHandler.postMessage({ id, path, method: options.method || 'GET', body });
      });
      return result;
    }
    const headers = { 'X-X6-Token': TOKEN, ...(options.headers || {}) };
    if (options.body) headers['Content-Type'] = 'application/json';
    const response = await fetch(path, { ...options, headers, cache: 'no-store' });
    let result;
    try { result = await response.json(); } catch (_) { result = { error: `HTTP ${response.status}` }; }
    if (!response.ok || result.ok === false) {
      const error = new Error(result.message || result.error || `HTTP ${response.status}`);
      error.payload = result;
      throw error;
    }
    return result;
  }

  function post(path, body) { return request(path, { method: 'POST', body: JSON.stringify(body) }); }

  async function loadState(locationID = '', deviceKey = '', preserveProfile = false) {
    const previous = {
      profile: clone(app.profile), profileID: app.profileID, deviceKey: app.deviceKey,
      profileName: app.profileName, dirty: new Set(app.dirty), selectedStage: app.selectedStage,
    };
    const params = new URLSearchParams();
    if (locationID) params.set('location', String(locationID));
    if (deviceKey) params.set('deviceKey', deviceKey);
    const result = await request(`/api/state?${params.toString()}`);
    app.devices = result.devices || [];
    app.selected = result.selected || null;
    app.online = Boolean(result.online && app.selected);
    app.deviceKey = result.deviceKey || (app.selected && app.selected.deviceKey) || deviceKey || '';
    const keepEdits = preserveProfile && previous.deviceKey && previous.deviceKey === app.deviceKey && previous.profileID && previous.profileID === result.profileID;
    app.profile = keepEdits ? previous.profile : (result.profile ? clone(result.profile) : clone(defaults));
    app.profileID = result.profileID || '';
    app.profileName = keepEdits ? previous.profileName : (result.profileName || 'Предпросмотр');
    app.profileList = result.profileList?.profiles || [];
    app.selectedStage = keepEdits ? previous.selectedStage : (app.profile.dpi.activeStage || 1);
    if (keepEdits) app.dirty = previous.dirty;
    else app.dirty.clear();
    if (app.selected) {
      writeLocal('x6.location', app.selected.locationID);
      writeLocal('x6.deviceKey', app.selected.deviceKey);
    } else if (app.deviceKey) {
      writeLocal('x6.deviceKey', app.deviceKey);
    }
    renderAll(result.message || '', result.bridgeError || '');
  }

  function switchPage(page) {
    if (!document.querySelector(`[data-view="${page}"]`)) return;
    const changedPage = app.activePage !== page;
    app.activePage = page;
    document.querySelectorAll('.page-view').forEach(item => item.classList.toggle('active', item.dataset.view === page));
    document.querySelectorAll('.nav-item').forEach(item => item.classList.toggle('active', item.dataset.page === page));
    const titles = {
      overview: ['ТВОЯ МЫШЬ. ТВОИ ПРАВИЛА.', 'Центр управления'],
      lighting: ['01 / ВИЗУАЛ', 'Подсветка'],
      performance: ['02 / ТОЧНОСТЬ', 'Производительность'],
      controls: ['03 / КОНТРОЛЬ', 'Сенсор и кнопки'],
      buttons: ['04 / ПЕРСОНАЛИЗАЦИЯ', 'Назначение кнопок'],
      device: ['05 / УПРАВЛЕНИЕ', 'Профили и устройство'],
    };
    byId('pageEyebrow').textContent = titles[page][0];
    byId('pageTitle').textContent = titles[page][1];
    if (changedPage) window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function renderAll(message = '', bridgeError = '') {
    renderConnection(message, bridgeError);
    renderHeader();
    renderSidebar();
    renderOverview();
    renderLighting();
    renderPerformance();
    renderControls();
    renderButtons();
    renderDevicePage();
    renderDirty();
    switchPage(app.activePage);
    setBusy(app.busy);
  }

  function renderConnection(message, bridgeError) {
    const banner = byId('connectionBanner');
    const text = byId('connectionMessage');
    banner.classList.remove('offline', 'error');
    if (bridgeError) {
      banner.classList.add('error');
      text.textContent = `USB-мост недоступен: ${bridgeError}`;
    } else if (app.online && app.selected) {
      text.textContent = `${app.selected.product || 'Attack Shark X6'} на связи · ${app.selected.transport}. Настройки мыши доступны только для записи.`;
    } else if (app.devices.length > 1 && !app.selected) {
      banner.classList.add('offline');
      text.textContent = message || 'Найдено несколько устройств — выберите X6 в меню справа.';
    } else if (app.deviceKey) {
      banner.classList.add('offline');
      text.textContent = 'X6 не подключён. Можно редактировать локальный профиль; для записи подключите мышь или приёмник.';
    } else {
      banner.classList.add('offline');
      text.textContent = message || 'Подключите Attack Shark X6 кабелем или через 2.4 ГГц приёмник.';
    }
  }

  function renderHeader() {
    const deviceSelect = byId('deviceSelect');
    const previous = app.selected ? String(app.selected.locationID) : '';
    const options = ['<option value="">Выбрать X6…</option>'];
    app.devices.forEach(device => {
      const label = `${device.product || 'Attack Shark X6'} · ${device.transport || 'USB'}`;
      options.push(`<option value="${escapeHTML(device.locationID)}">${escapeHTML(label)}</option>`);
    });
    if (!app.devices.length && app.deviceKey) options.push('<option value="offline">X6 не подключён · профиль локально</option>');
    deviceSelect.innerHTML = options.join('');
    deviceSelect.value = app.selected ? previous : (app.deviceKey && !app.devices.length ? 'offline' : '');
    deviceSelect.disabled = !app.devices.length;

    const profileOptions = app.profileList.map(profile => `<option value="${escapeHTML(profile.id)}">${escapeHTML(profile.name)}</option>`);
    if (!profileOptions.length) profileOptions.push('<option value="">Предпросмотр</option>');
    byId('profileSelect').innerHTML = profileOptions.join('');
    byId('profileSelect').value = app.profileID || '';
    byId('profileSelect').disabled = app.profileList.length < 2;
    byId('applyProfile').disabled = !app.online || !app.profileID || app.busy;
    byId('applyProfilePage').disabled = !app.online || !app.profileID || app.busy;
  }

  function renderSidebar() {
    const card = byId('sidebarDevice');
    card.classList.toggle('online', app.online);
    byId('sidebarStatus').textContent = app.online ? 'Устройство на связи' : 'Мышь не подключена';
    byId('sidebarDeviceName').textContent = app.selected ? (app.selected.product || 'Attack Shark X6') : 'Attack Shark X6';
    byId('sidebarTransport').textContent = app.selected ? app.selected.transport : (app.profileName || 'Локальный профиль');
  }

  function renderOverview() {
    const dpi = app.profile.dpi;
    byId('overviewDpi').textContent = formatNumber(dpi.stages[dpi.activeStage - 1] || 0);
    byId('overviewDpiStage').innerHTML = `Этап ${dpi.activeStage} из 6 <i>↗</i>`;
    byId('overviewPolling').innerHTML = `${formatNumber(app.profile.pollingHz)} <em>Гц</em>`;
    byId('overviewLighting').textContent = modeName(app.profile.lighting.mode);
    const colorLabel = swatches.find(item => item.color.toLowerCase() === app.profile.lighting.color.toLowerCase())?.label || app.profile.lighting.color.toUpperCase();
    byId('overviewColor').innerHTML = `<span class="mini-color"></span> ${escapeHTML(colorLabel)} <i>↗</i>`;
    byId('overviewProfileTag').textContent = app.profileName;
    const mode = app.profile.lighting.mode;
    const ledColor = ['fixed', 'breathing'].includes(mode) ? app.profile.lighting.color : (mode === 'off' ? '#777777' : modeInfo[mode].color);
    document.documentElement.style.setProperty('--led-color', ledColor);
    byId('overviewGlow').style.opacity = app.profile.lighting.mode === 'off' ? '.02' : '.22';
  }

  function renderLighting() {
    const info = modeInfo[app.profile.lighting.mode] || modeInfo.breathing;
    const modeRoot = byId('lightingModes');
    modeRoot.innerHTML = Object.entries(modeInfo).map(([key, mode]) => `
      <button class="mode-card ${app.profile.lighting.mode === key ? 'selected' : ''}" type="button" data-mode="${key}" aria-pressed="${app.profile.lighting.mode === key}">
        <span class="mode-art" style="--mode-color:${mode.color}">${mode.icon}</span>
        <span class="mode-copy"><strong>${mode.name}</strong><small>${mode.note}</small></span>
        <span class="mode-check">✓</span>
      </button>`).join('');
    const colorEnabled = ['fixed', 'breathing'].includes(app.profile.lighting.mode);
    const colorInput = byId('lightingColor');
    colorInput.value = app.profile.lighting.color.toLowerCase();
    colorInput.disabled = !colorEnabled;
    byId('lightingColorHex').textContent = app.profile.lighting.color.toUpperCase();
    byId('colorSwatches').innerHTML = colorEnabled ? swatches.map(item => `<button type="button" class="swatch" data-swatch="${item.color}" aria-label="${item.label}" title="${item.label}" style="background:${item.color}"></button>`).join('') : '';
    byId('lightingSpeed').value = app.profile.lighting.speed;
    byId('speedValue').innerHTML = `${app.profile.lighting.speed} <span>/ 8</span>`;
    byId('sleepValue').innerHTML = `${formatHalf(app.profile.lighting.sleepMinutes)} <small>мин</small>`;
    byId('previewModeName').textContent = `${app.profile.lighting.color.toUpperCase()} · ${info.preview}`;
    byId('lightingPreview').classList.toggle('preview-off', app.profile.lighting.mode === 'off');
    byId('lightingPreview').classList.toggle('preview-breathing', app.profile.lighting.mode === 'breathing' || app.profile.lighting.mode === 'dpi_breathing');
    byId('lightingPreview').classList.toggle('preview-cycle', app.profile.lighting.mode === 'neon' || app.profile.lighting.mode === 'color_cycle');
    setRangeFill(byId('lightingSpeed'));
    renderOverview();
    setLedPreview();
  }

  function renderStageGrid() {
    const stages = app.profile.dpi.stages;
    byId('stageGrid').innerHTML = stages.map((value, index) => {
      const stage = index + 1;
      return `<div class="stage-card ${app.selectedStage === stage ? 'selected' : ''}" data-stage-card="${stage}">
        <button class="stage-pick" type="button" data-stage-pick="${stage}" aria-label="Сделать активным этап ${stage}">
          <span class="stage-card-top"><span>ЭТАП</span><span class="stage-index">${String(stage).padStart(2, '0')}</span></span>
          <span class="stage-card-active" ${app.profile.dpi.activeStage === stage ? '' : 'hidden'}>АКТИВЕН</span>
        </button>
        <input type="number" data-stage-input="${stage}" min="50" max="26000" step="50" value="${value}" aria-label="DPI этапа ${stage}">
        <span class="stage-unit">DPI</span>
        <span class="stage-color-dot" style="background:${stageColors[index]};color:${stageColors[index]}"></span>
      </div>`;
    }).join('');
    updateDpiControl();
  }

  function renderPerformance() {
    renderStageGrid();
    const choices = [[125, '8 ms'], [250, '4 ms'], [500, '2 ms'], [1000, '1 ms']];
    byId('pollingOptions').innerHTML = choices.map(([rate, latency]) => `
      <button type="button" class="poll-option ${app.profile.pollingHz === rate ? 'selected' : ''}" data-polling="${rate}" aria-pressed="${app.profile.pollingHz === rate}">
        <strong>${formatNumber(rate)} Hz</strong><small>${latency} interval</small>
      </button>`).join('');
    byId('pollingCurrent').innerHTML = `${formatNumber(app.profile.pollingHz)} <small>Гц</small>`;
    setRangeFill(byId('dpiSlider'));
    renderOverview();
  }

  function renderControls() {
    byId('angleToggle').setAttribute('aria-checked', String(app.profile.dpi.angleSnap));
    byId('rippleToggle').setAttribute('aria-checked', String(app.profile.dpi.rippleControl));
    document.querySelectorAll('[data-lod]').forEach(button => button.classList.toggle('selected', Number(button.dataset.lod) === app.profile.dpi.lodMm));
    byId('lodVisualValue').textContent = `${app.profile.dpi.lodMm} MM`;
    byId('debounceSlider').value = app.profile.lighting.debounceMs;
    byId('debounceValue').innerHTML = `${app.profile.lighting.debounceMs}<small>мс</small>`;
    setRangeFill(byId('debounceSlider'));
  }

  function allowedActions(buttonIndex) {
    return actionGroups.map(group => {
      const items = buttonIndex === 0 ? group.items.filter(([action]) => ['left', 'right', 'middle', 'backward', 'forward', 'double_click', 'fire', 'off'].includes(action) || action.startsWith('browser_')) : group.items;
      return items.length ? `<optgroup label="${group.label}">${items.map(([action, label]) => `<option value="${action}">${label}</option>`).join('')}</optgroup>` : '';
    }).join('');
  }

  function renderButtons() {
    byId('buttonList').innerHTML = buttons.map((button, index) => `
      <div class="button-row">
        <span class="button-number">${String(index + 1).padStart(2, '0')}</span>
        <div class="button-name"><strong>${button.name}</strong><small>${button.detail}</small></div>
        <select data-button-action="${index}" aria-label="Действие кнопки ${index + 1}">${allowedActions(index)}</select>
      </div>`).join('');
    document.querySelectorAll('[data-button-action]').forEach(select => { select.value = app.profile.buttons[Number(select.dataset.buttonAction)]; });
  }

  function renderDevicePage() {
    const list = app.profileList || [];
    byId('activeProfileBadge').textContent = app.profileName;
    byId('profileList').innerHTML = list.length ? list.map(profile => {
      const active = profile.id === app.profileID;
      return `<div class="profile-item ${active ? 'active' : ''}">
        <button type="button" class="profile-pick" data-profile-pick="${escapeHTML(profile.id)}" aria-current="${active ? 'true' : 'false'}"><span class="profile-radio"></span><strong>${escapeHTML(profile.name)}</strong></button>
        ${active ? '<span class="profile-active-label">АКТИВЕН</span>' : `<button class="profile-remove" type="button" data-profile-delete="${escapeHTML(profile.id)}" aria-label="Удалить профиль ${escapeHTML(profile.name)}" title="Удалить профиль">×</button>`}
      </div>`;
    }).join('') : '<div class="empty-profile">Профиль появится после подключения X6.</div>';
    byId('deviceStatusPill').classList.toggle('online', app.online);
    byId('deviceStatusPill').innerHTML = `<i></i> ${app.online ? 'На связи' : 'Отключена'}`;
    byId('deviceConnection').textContent = app.selected ? app.selected.transport : 'Нет подключения';
    byId('deviceVidPid').textContent = app.selected ? `${app.selected.vendorID.toUpperCase()} : ${app.selected.productID.toUpperCase()}` : '1D57 : FA61';
    byId('deviceLocation').textContent = app.selected ? String(app.selected.locationID) : '—';
    byId('deviceSerial').textContent = app.selected && app.selected.serial ? app.selected.serial : 'Не передаётся';
    byId('resetDevice').disabled = !app.online || app.busy;
    renderHeader();
  }

  function renderDirty() {
    const pairs = [['lighting', 'lightingPending'], ['performance', 'performancePending'], ['controls', 'controlsPending'], ['buttons', 'buttonsPending']];
    pairs.forEach(([key, id]) => {
      const el = byId(id);
      const dirty = app.dirty.has(key);
      el.classList.toggle('pending', dirty);
      el.textContent = dirty ? (app.profileID ? 'Есть несохранённые изменения профиля' : 'Изменения пока только в этом окне') : (key === 'lighting' ? 'Профиль хранится на этом Mac' : key === 'performance' ? 'DPI и частота хранятся в локальном профиле' : key === 'controls' ? 'Изменения сенсора сохраняются в профиле' : 'Назначения пока только в локальном профиле');
    });
    byId('applyLighting').disabled = !app.online || app.busy;
    byId('applyPerformance').disabled = !app.online || app.busy;
    byId('applyControls').disabled = !app.online || app.busy;
    byId('applyButtons').disabled = !app.online || app.busy;
    byId('applyProfile').disabled = !app.online || !app.profileID || app.busy;
    byId('applyProfilePage').disabled = !app.online || !app.profileID || app.busy;
    byId('resetDevice').disabled = !app.online || app.busy;
  }

  function setBusy(value) {
    app.busy = value;
    document.body.classList.toggle('is-busy', value);
    document.querySelectorAll('.apply-button, #applyProfile, #applyProfilePage, #resetDevice').forEach(button => { button.disabled = value || button.disabled; });
    renderDirty();
  }

  function setRangeFill(input) {
    if (!input) return;
    const min = Number(input.min), max = Number(input.max), value = Number(input.value);
    const percent = max > min ? ((value - min) * 100 / (max - min)) : 0;
    input.style.setProperty('--range-progress', `${percent}%`);
  }

  function updateDpiControl() {
    const stage = Math.min(6, Math.max(1, app.selectedStage));
    const value = app.profile.dpi.stages[stage - 1];
    byId('selectedStageNumber').textContent = String(stage).padStart(2, '0');
    byId('dpiSlider').value = value;
    byId('dpiValue').textContent = formatNumber(value);
    byId('activeStageDpi').textContent = formatNumber(app.profile.dpi.stages[app.profile.dpi.activeStage - 1]);
    setRangeFill(byId('dpiSlider'));
  }

  function setLedPreview() {
    const lighting = app.profile.lighting;
    const ledColor = ['fixed', 'breathing'].includes(lighting.mode) ? lighting.color : (lighting.mode === 'off' ? '#777777' : modeInfo[lighting.mode].color);
    document.documentElement.style.setProperty('--led-color', ledColor);
    document.documentElement.style.setProperty('--led-speed-duration', `${10 - lighting.speed}s`);
    const preview = byId('lightingPreview');
    preview.classList.toggle('preview-off', lighting.mode === 'off');
    preview.classList.toggle('preview-breathing', lighting.mode === 'breathing' || lighting.mode === 'dpi_breathing');
    preview.classList.toggle('preview-cycle', lighting.mode === 'neon' || lighting.mode === 'color_cycle');
    byId('previewModeName').textContent = `${lighting.color.toUpperCase()} · ${modeInfo[lighting.mode].preview}`;
    byId('lightingColorHex').textContent = lighting.color.toUpperCase();
    byId('overviewGlow').style.opacity = lighting.mode === 'off' ? '.02' : '.22';
  }

  function markChanged(section) {
    app.dirty.add(section);
    renderDirty();
    scheduleSave();
  }

  function scheduleSave() {
    if (!app.deviceKey || !app.profileID) return;
    const revision = ++app.saveRevision;
    clearTimeout(app.saveTimer);
    app.saveTimer = setTimeout(() => enqueueSave(revision), 240);
  }

  function enqueueSave(revision) {
    const snapshot = clone(app.profile);
    const body = { deviceKey: app.deviceKey, profileID: app.profileID, config: snapshot };
    app.saveQueue = app.saveQueue.then(async () => {
      await post('/api/profile/config', body);
      if (revision === app.saveRevision) {
        byId('connectionMessage').textContent = app.online ? 'Локальный профиль сохранён. Настройки отправляются в мышь только по кнопке.' : 'Локальный профиль сохранён. Подключи X6, чтобы отправить настройки.';
      }
    }).catch(error => showError(error, 'Не удалось сохранить профиль'));
    return app.saveQueue;
  }

  async function flushSave() {
    clearTimeout(app.saveTimer);
    if (app.deviceKey && app.profileID) enqueueSave(app.saveRevision);
    await app.saveQueue;
  }

  function updateStageValue(stage, value) {
    const parsed = Number(value);
    if (!Number.isInteger(parsed) || parsed < 50 || parsed > 26000 || parsed % 50) return false;
    app.profile.dpi.stages[stage - 1] = parsed;
    document.querySelectorAll(`[data-stage-input="${stage}"]`).forEach(input => { if (document.activeElement !== input) input.value = parsed; });
    if (stage === app.selectedStage) updateDpiControl();
    renderOverview();
    markChanged('performance');
    return true;
  }

  function updateStageSlider(value) {
    const stage = app.selectedStage;
    const parsed = Math.round(Number(value) / 50) * 50;
    app.profile.dpi.stages[stage - 1] = parsed;
    const field = document.querySelector(`[data-stage-input="${stage}"]`);
    if (field) field.value = parsed;
    updateDpiControl();
    renderOverview();
    markChanged('performance');
  }

  function changeLighting(key, value) {
    app.profile.lighting[key] = value;
    if (key === 'mode') renderLighting();
    else if (key === 'color') {
      byId('lightingColor').value = value.toLowerCase();
      byId('lightingColorHex').textContent = value.toUpperCase();
      renderLighting();
    } else if (key === 'speed') {
      byId('speedValue').innerHTML = `${value} <span>/ 8</span>`;
      byId('lightingSpeed').value = value;
      setRangeFill(byId('lightingSpeed'));
    } else if (key === 'sleepMinutes') {
      byId('sleepValue').innerHTML = `${formatHalf(value)} <small>мин</small>`;
    } else if (key === 'debounceMs') {
      byId('debounceValue').innerHTML = `${value}<small>мс</small>`;
      byId('debounceSlider').value = value;
      setRangeFill(byId('debounceSlider'));
    }
    renderOverview();
    setLedPreview();
    markChanged(key === 'debounceMs' ? 'controls' : 'lighting');
  }

  function changeDpi(key, value) {
    app.profile.dpi[key] = value;
    if (key === 'angleSnap') byId('angleToggle').setAttribute('aria-checked', String(value));
    if (key === 'rippleControl') byId('rippleToggle').setAttribute('aria-checked', String(value));
    if (key === 'lodMm') {
      document.querySelectorAll('[data-lod]').forEach(button => button.classList.toggle('selected', Number(button.dataset.lod) === value));
      byId('lodVisualValue').textContent = `${value} MM`;
    }
    markChanged('controls');
  }

  async function applySection(section) {
    if (!app.online || !app.selected) return showToast('Мышь не подключена', 'Подключи X6 и обнови список устройств.', true);
    try {
      await flushSave();
      setBusy(true);
      const result = await post('/api/apply', { ...selectedDeviceParams(), section });
      if (section === 'profile') app.dirty.clear();
      else if (section === 'controls') { app.dirty.delete('controls'); app.dirty.delete('lighting'); }
      else app.dirty.delete(section);
      renderDirty();
      const ids = (result.acknowledged || []).join(' · ');
      showToast('X6 подтвердил настройки', `Приняты команды ${ids || 'USB HID'}.`);
    } catch (error) { showError(error, 'Не удалось применить настройки'); }
    finally { setBusy(false); }
  }

  async function applyWholeProfile() {
    const okay = await openDialog({
      eyebrow: 'ЗАПИСЬ ПРОФИЛЯ', title: 'Отправить весь профиль?',
      text: 'X6 получит DPI и сенсорные параметры, подсветку и таймеры, частоту опроса и все назначения кнопок. Настройки самого устройства не считываются.',
      confirm: 'Записать в X6', icon: '↗',
    });
    if (!okay) return;
    await applySection('profile');
  }

  async function applyRemap() {
    const okay = await openDialog({
      eyebrow: 'ПЕРЕНАЗНАЧЕНИЕ КНОПОК', title: 'Применить раскладку?',
      text: 'Новые действия будут записаны в X6. Проверь, что основные кнопки остаются удобными для управления курсором.',
      confirm: 'Применить кнопки', icon: '▦',
    });
    if (okay) await applySection('buttons');
  }

  async function resetDevice() {
    const okay = await openDialog({
      eyebrow: 'ВОЗВРАТ К СТАНДАРТУ', title: 'Сбросить настройки X6?',
      text: 'Будут записаны стандартные уровни DPI с активным этапом 2, подсветка «Цвет по DPI», частота 1 000 Гц и заводские назначения кнопок. Текущие параметры мыши недоступны для чтения.',
      confirm: 'Сбросить X6', icon: '↺', danger: true,
    });
    if (!okay) return;
    try {
      await flushSave();
      setBusy(true);
      const result = await post('/api/reset', selectedDeviceParams());
      app.profile = clone(result.profile);
      app.profileID = result.profileID;
      app.profileName = result.profileName;
      app.dirty.clear();
      renderAll();
      showToast('Стандарт X6 восстановлен', `Мышь подтвердила ${result.acknowledged.join(' · ')}.`);
    } catch (error) { showError(error, 'Сброс не завершён'); }
    finally { setBusy(false); }
  }

  async function manageProfile(operation, extra = {}) {
    if (!app.deviceKey || !app.profileID) return showToast('Нет выбранного профиля', 'Сначала подключи X6.', true);
    try {
      await flushSave();
      const result = await post('/api/profile/manage', { deviceKey: app.deviceKey, profileID: extra.targetID || app.profileID, operation, ...extra });
      app.profile = clone(result.profile);
      app.profileID = result.profileID;
      app.profileName = result.profileName;
      app.profileList = result.profileList.profiles || [];
      app.dirty.clear();
      renderAll();
      return result;
    } catch (error) { showError(error, 'Не удалось обновить профиль'); return null; }
  }

  async function askProfile(operation) {
    const current = app.profileName || 'Профиль';
    const options = {
      create: { title: 'Новый профиль', text: 'Создай отдельный локальный набор на основе текущих настроек.', label: 'Название', value: 'Новый профиль', confirm: 'Создать' },
      duplicate: { title: 'Дублировать профиль', text: 'Создай копию текущих настроек для отдельного сценария.', label: 'Название копии', value: `${current} копия`, confirm: 'Дублировать' },
      rename: { title: 'Переименовать профиль', text: 'Название хранится только в локальной библиотеке.', label: 'Новое название', value: current, confirm: 'Сохранить' },
    }[operation];
    const value = await openDialog({ eyebrow: 'ЛОКАЛЬНЫЕ ПРОФИЛИ', ...options, input: true, icon: 'P' });
    if (value === false) return;
    const name = String(value || '').trim();
    if (!name) return showToast('Нужно название', 'Введите название профиля.', true);
    const result = await manageProfile(operation, { name });
    if (result) showToast(operation === 'rename' ? 'Название обновлено' : 'Профиль сохранён', 'Изменение записано в локальную библиотеку.');
  }

  async function selectProfile(profileID) {
    if (!profileID || profileID === app.profileID) return;
    const result = await manageProfile('activate', { targetID: profileID });
    if (result) showToast('Профиль выбран', 'Это локальная конфигурация; для записи в мышь нажми «Применить профиль».');
  }

  async function deleteProfile(profileID) {
    const profile = app.profileList.find(item => item.id === profileID);
    if (!profile) return;
    const okay = await openDialog({ eyebrow: 'ЛОКАЛЬНЫЕ ПРОФИЛИ', title: `Удалить «${profile.name}»?`, text: 'Удалится только сохранённая на Mac копия профиля. Настройки мыши не изменятся.', confirm: 'Удалить профиль', icon: '×', danger: true });
    if (!okay) return;
    const result = await manageProfile('delete', { targetID: profileID });
    if (result) showToast('Профиль удалён', 'Мышь не изменялась.');
  }

  function openDialog(options) {
    const dialog = byId('confirmDialog');
    byId('dialogEyebrow').textContent = options.eyebrow || 'ПОДТВЕРЖДЕНИЕ';
    byId('dialogTitle').textContent = options.title || 'Подтвердить действие?';
    byId('dialogText').textContent = options.text || '';
    byId('dialogIcon').textContent = options.icon || '↗';
    byId('dialogInputWrap').hidden = !options.input;
    byId('dialogInputLabel').textContent = options.label || 'Название';
    byId('dialogInput').value = options.value || '';
    byId('dialogConfirm').innerHTML = `${options.confirm || 'Подтвердить'} <span>↗</span>`;
    byId('dialogConfirm').classList.toggle('button-danger', Boolean(options.danger));
    byId('dialogConfirm').classList.toggle('button-primary', !options.danger);
    return new Promise(resolve => {
      app.dialogResolve = resolve;
      dialog.showModal();
      if (options.input) setTimeout(() => byId('dialogInput').focus(), 30);
    });
  }

  function closeDialog(value) {
    const dialog = byId('confirmDialog');
    if (!dialog.open) return;
    dialog.close();
    if (app.dialogResolve) {
      app.dialogResolve(value);
      app.dialogResolve = null;
    }
  }

  function showToast(title, message, error = false) {
    const node = document.createElement('div');
    node.className = `toast ${error ? 'error' : ''}`;
    node.innerHTML = `<span class="toast-icon">${error ? '!' : '✓'}</span><span><strong>${escapeHTML(title)}</strong><small>${escapeHTML(message)}</small></span>`;
    byId('toastRegion').appendChild(node);
    setTimeout(() => node.remove(), error ? 6500 : 3600);
  }

  function showError(error, title) {
    const payload = error.payload || {};
    let message = payload.message || payload.error || error.message || 'Неизвестная ошибка';
    if (payload.partial && payload.partial.length) message += ` Уже подтверждено: ${payload.partial.join(' · ')}.`;
    if (payload.unconfirmed) message += ` Ожидалось подтверждение ${payload.unconfirmed}.`;
    showToast(title, message, true);
  }

  function setSelectedStage(stage) {
    if (stage < 1 || stage > 6) return;
    app.selectedStage = stage;
    app.profile.dpi.activeStage = stage;
    document.querySelectorAll('[data-stage-card]').forEach(card => card.classList.toggle('selected', Number(card.dataset.stageCard) === stage));
    document.querySelectorAll('[data-stage-card]').forEach(card => {
      const activeLabel = card.querySelector('.stage-card-active');
      if (activeLabel) activeLabel.hidden = Number(card.dataset.stageCard) !== stage;
    });
    updateDpiControl();
    renderOverview();
    markChanged('performance');
  }

  function bindEvents() {
    document.querySelectorAll('[data-page]').forEach(button => button.addEventListener('click', () => switchPage(button.dataset.page)));
    document.querySelectorAll('[data-go]').forEach(button => button.addEventListener('click', () => switchPage(button.dataset.go)));
    byId('refreshButton').addEventListener('click', async () => {
      try { await loadState(app.selected ? app.selected.locationID : '', app.deviceKey, true); showToast('Список устройств обновлён', 'Проверено подключение X6.'); }
      catch (error) { showError(error, 'Не удалось обновить устройства'); }
    });
    byId('deviceSelect').addEventListener('change', async event => {
      if (event.target.value === 'offline') return;
      try { await loadState(event.target.value, ''); }
      catch (error) { showError(error, 'Не удалось выбрать X6'); }
    });
    byId('profileSelect').addEventListener('change', event => selectProfile(event.target.value));
    byId('applyProfile').addEventListener('click', applyWholeProfile);
    byId('applyProfilePage').addEventListener('click', applyWholeProfile);
    byId('applyLighting').addEventListener('click', () => applySection('lighting'));
    byId('applyPerformance').addEventListener('click', () => applySection('performance'));
    byId('applyControls').addEventListener('click', () => applySection('controls'));
    byId('applyButtons').addEventListener('click', applyRemap);
    byId('resetDevice').addEventListener('click', resetDevice);
    byId('createProfile').addEventListener('click', () => askProfile('create'));
    byId('renameProfile').addEventListener('click', () => askProfile('rename'));
    byId('duplicateProfile').addEventListener('click', () => askProfile('duplicate'));
    byId('dialogCancel').addEventListener('click', () => closeDialog(false));
    document.querySelector('.dialog-close').addEventListener('click', () => closeDialog(false));
    byId('dialogConfirm').addEventListener('click', () => closeDialog(byId('dialogInputWrap').hidden ? true : byId('dialogInput').value));
    byId('confirmDialog').addEventListener('cancel', event => { event.preventDefault(); closeDialog(false); });
    byId('confirmDialog').addEventListener('click', event => { if (event.target === byId('confirmDialog')) closeDialog(false); });
    byId('dialogInput').addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); closeDialog(byId('dialogInput').value); } });

    document.body.addEventListener('click', event => {
      const mode = event.target.closest('[data-mode]');
      if (mode) { changeLighting('mode', mode.dataset.mode); return; }
      const swatch = event.target.closest('[data-swatch]');
      if (swatch) { changeLighting('color', swatch.dataset.swatch); return; }
      const stage = event.target.closest('[data-stage-pick]');
      if (stage) { setSelectedStage(Number(stage.dataset.stagePick)); return; }
      const polling = event.target.closest('[data-polling]');
      if (polling) {
        app.profile.pollingHz = Number(polling.dataset.polling);
        renderPerformance(); renderOverview(); markChanged('performance'); return;
      }
      const lod = event.target.closest('[data-lod]');
      if (lod) { changeDpi('lodMm', Number(lod.dataset.lod)); return; }
      const sleepStep = event.target.closest('[data-sleep-step]');
      if (sleepStep) {
        const next = Math.min(60, Math.max(.5, app.profile.lighting.sleepMinutes + Number(sleepStep.dataset.sleepStep) * .5));
        changeLighting('sleepMinutes', next); return;
      }
      const profilePick = event.target.closest('[data-profile-pick]');
      if (profilePick) { selectProfile(profilePick.dataset.profilePick); return; }
      const profileRemove = event.target.closest('[data-profile-delete]');
      if (profileRemove) { deleteProfile(profileRemove.dataset.profileDelete); return; }
      const card = event.target.closest('[data-stage-card]');
      if (card && !event.target.closest('input')) { setSelectedStage(Number(card.dataset.stageCard)); return; }
    });

    document.body.addEventListener('input', event => {
      const target = event.target;
      if (target.id === 'lightingColor') { changeLighting('color', target.value.toUpperCase()); return; }
      if (target.id === 'lightingSpeed') { changeLighting('speed', Number(target.value)); return; }
      if (target.id === 'dpiSlider') { updateStageSlider(target.value); return; }
      if (target.id === 'debounceSlider') { changeLighting('debounceMs', Number(target.value)); return; }
      if (target.matches('[data-stage-input]')) {
        const stage = Number(target.dataset.stageInput);
        const value = Number(target.value);
        if (Number.isInteger(value) && value >= 50 && value <= 26000 && value % 50 === 0) updateStageValue(stage, value);
      }
    });
    document.body.addEventListener('change', event => {
      const target = event.target;
      if (target.matches('[data-button-action]')) {
        app.profile.buttons[Number(target.dataset.buttonAction)] = target.value;
        markChanged('buttons');
      }
      if (target.matches('[data-stage-input]')) {
        const stage = Number(target.dataset.stageInput);
        if (!updateStageValue(stage, Number(target.value))) {
          target.value = app.profile.dpi.stages[stage - 1];
          showToast('Неподходящее значение DPI', 'Используй значение от 50 до 26 000 с шагом 50.', true);
        }
      }
    });
    byId('angleToggle').addEventListener('click', () => changeDpi('angleSnap', !app.profile.dpi.angleSnap));
    byId('rippleToggle').addEventListener('click', () => changeDpi('rippleControl', !app.profile.dpi.rippleControl));
  }

  async function initialize() {
    bindEvents();
    const locationID = readLocal('x6.location');
    const deviceKey = readLocal('x6.deviceKey');
    try { await loadState(locationID, deviceKey); }
    catch (error) { renderAll('Локальный USB-мост пока недоступен.', error.message); showError(error, 'Не удалось подключиться к X6 Control'); }
    switchPage('overview');
    setInterval(async () => {
      if (app.busy || document.visibilityState !== 'visible') return;
      try { await loadState(app.selected ? app.selected.locationID : '', app.deviceKey, true); }
      catch (_) { /* Keep the current local profile visible while the device is absent. */ }
    }, 12000);
  }

  initialize();
})();
