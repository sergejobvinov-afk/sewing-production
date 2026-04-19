// ============================================================
// api.js — Обёртка для вызова Google Apps Script как REST API
// Заменяет google.script.run на fetch()
// ============================================================

var API = (function() {
  // ⚠️ ЗАМЕНИТЕ НА URL ВАШЕГО РАЗВЕРНУТОГО СКРИПТА
  var BASE_URL = 'https://script.google.com/macros/s/AKfycbwqNxJH6mb1FYo5p0eL1aaoQOY4U0H26HjJx-VpLb4MD_VOy-A2BKYOY-OAdp5axL5I/exec';
  
  // Индикатор статуса API
  var _statusEl = null;
  var _online = null; // null = unknown, true = online, false = offline
  
  function setBaseUrl(url) {
    BASE_URL = url;
    // Сохраняем в localStorage для удобства
    try { localStorage.setItem('api_base_url', url); } catch(e){}
  }
  
  function getBaseUrl() {
    // Попытка загрузить из localStorage
    try {
      var saved = localStorage.getItem('api_base_url');
      if (saved) BASE_URL = saved;
    } catch(e){}
    return BASE_URL;
  }
  
  // Инициализация индикатора статуса
  function initStatusIndicator() {
    _statusEl = document.getElementById('api-status');
    if (!_statusEl) {
      // Создаем индикатор если его нет
      _statusEl = document.createElement('div');
      _statusEl.id = 'api-status';
      _statusEl.style.cssText = 'position:fixed;top:4px;right:4px;width:12px;height:12px;border-radius:50%;z-index:10000;cursor:pointer;border:2px solid rgba(255,255,255,0.8);transition:background 0.3s;';
      _statusEl.title = 'Статус API: проверка...';
      _statusEl.style.background = '#ffc107'; // yellow = checking
      document.body.appendChild(_statusEl);
      _statusEl.addEventListener('click', function() {
        checkConnection();
      });
    }
    checkConnection();
    // Периодическая проверка каждые 60 сек
    setInterval(checkConnection, 60000);
  }
  
  function updateStatus(online) {
    _online = online;
    if (_statusEl) {
      _statusEl.style.background = online ? '#4caf50' : '#f44336';
      _statusEl.title = online ? 'API: подключено ✅' : 'API: недоступно ❌ (кликните для проверки)';
    }
  }
  
  function checkConnection() {
    if (_statusEl) {
      _statusEl.style.background = '#ffc107';
      _statusEl.title = 'API: проверка...';
    }
    apiGet('ping', {})
      .then(function(r) { updateStatus(r && r.success); })
      .catch(function() { updateStatus(false); });
  }
  
  // ============================================================
  // GET-запрос (для чтения данных)
  // ============================================================
  function apiGet(action, params) {
  var url = getBaseUrl() + '?action=' + encodeURIComponent(action);
  if (params) {
    Object.keys(params).forEach(function(key) {
      if (params[key] !== undefined && params[key] !== null) {
        url += '&' + encodeURIComponent(key) + '=' + encodeURIComponent(params[key]);
      }
    });
  }
  // Добавляем случайный параметр для обхода кэша
  url += '&_=' + Date.now();
  
  return fetch(url, {
    method: 'GET',
    cache: 'no-store',
    redirect: 'follow'
    })
    .then(function(resp) {
      if (!resp.ok) throw new Error('HTTP ' + resp.status);
      return resp.json();
    })
    .then(function(data) {
      if (_online === false) updateStatus(true);
      return data;
    })
    .catch(function(err) {
      updateStatus(false);
      throw err;
    });
  }
  
  // ============================================================
  // POST-запрос (для записи данных)
  // ============================================================
  function apiPost(action, body) {
    body.action = action;
    
    return fetch(getBaseUrl(), {
      method: 'POST',
      redirect: 'follow',
      headers: { 'Content-Type': 'text/plain' },
      body: JSON.stringify(body)
    })
    .then(function(resp) {
      if (!resp.ok) throw new Error('HTTP ' + resp.status);
      return resp.json();
    })
    .then(function(data) {
      if (_online === false) updateStatus(true);
      return data;
    })
    .catch(function(err) {
      updateStatus(false);
      throw err;
    });
  }
  
  // ============================================================
  // Публичный API — замена google.script.run
  // Каждый метод возвращает Promise
  // ============================================================
  return {
    setBaseUrl: setBaseUrl,
    getBaseUrl: getBaseUrl,
    initStatusIndicator: initStatusIndicator,
    checkConnection: checkConnection,
    isOnline: function() { return _online; },
    
    // === Auth ===
    login: function(pin) {
      return apiGet('login', { pin: pin });
    },
    
    // === Pack Status ===
    getPackStatus: function(qr, pin) {
  return apiPost('getPackStatus', { qr: qr, pin: pin });
},
    
    // === Sewer List ===
    getSewerList: function(pin) {
      return apiGet('getSewerList', { pin: pin });
    },
    
    // Получить операции модели
    getModelOperations: function(model) {
      return apiGet('getModelOperations', { model: model });
    },

    // Выдать пачку с распределением операций (заменяет старый scanAssign)
    scanAssign: function(qr, operationsData, pin) {
      return apiPost('scanAssign', { qr: qr, operationsData: operationsData, pin: pin });
    },

    // Принять ОТК с распределением по операциям (заменяет старый scanFinish)
    scanFinish: function(qr, acceptedByOperation, pin) {
      return apiPost('scanFinish', { qr: qr, acceptedByOperation: acceptedByOperation, pin: pin });
    },
    
    // === Dashboard ===
    getDashboardData: function(pin) {
      return apiGet('getDashboardData', { pin: pin });
    },
    
    // === Add Pack ===
    getModelList: function() {
      return apiGet('getModelList', {});
    },
    
    addPack: function(model, size, qty, passport, color, pin) {
      return apiPost('addPack', { model: model, size: size, qty: qty, passport: passport, color: color, pin: pin });
    },
    
    // === Pack List ===
    getAllPacks: function(pin) {
      return apiGet('getAllPacks', { pin: pin });
    },
    
    // === Passport ===
    getPassportData: function(packId, pin) {
      return apiGet('getPassportData', { packId: packId, pin: pin });
    },
    
    // === Users ===
    getUsers: function(pin) {
      return apiGet('getUsers', { pin: pin });
    },
    
    // === Sewer Packs ===
    getSewerPacks: function(pin) {
      return apiGet('getSewerPacks', { pin: pin });
    },
    
    addUser: function(name, newPin, role, adminPin) {
      return apiPost('addUser', { name: name, newPin: newPin, role: role, adminPin: adminPin });
    },
    
    toggleUser: function(targetPin, adminPin) {
      return apiPost('toggleUser', { targetPin: targetPin, adminPin: adminPin });
    }
  };
})();
