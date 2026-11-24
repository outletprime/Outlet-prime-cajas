/* Aviso de versión nueva (app de Cajas y panel del live).
 * Cada vez que se publica un cambio, a quien tenga la página abierta le sale una franja arriba:
 * "Hay una versión nueva · Actualizar". No hay que anotar ningún número de versión: se compara la fecha
 * en que se publicó la página que está abierta contra la que hay publicada en este momento. */
(function () {
  if (!/^https?:$/.test(location.protocol)) return;
  var abierta = Date.parse(document.lastModified);   // cuándo se publicó lo que esta persona tiene abierto
  if (!abierta) return;
  var avisado = false, revisando = false;

  function avisar() {
    if (avisado) return;
    avisado = true;
    var f = document.createElement('button');
    f.type = 'button';
    f.id = 'aviso-version';
    f.setAttribute('style', 'position:fixed;left:0;right:0;top:0;z-index:99999;display:block;width:100%;border:0;margin:0;'
      + 'padding:calc(env(safe-area-inset-top, 0px) + 12px) 16px 12px;background:#c8102e;color:#fff;font:600 15px/1.35 system-ui,-apple-system,sans-serif;'
      + 'text-align:center;cursor:pointer;box-shadow:0 2px 10px rgba(0,0,0,.35)');
    f.innerHTML = 'Hay una versión nueva del sistema. <u>Toca aquí para actualizar</u><br>'
      + '<small style="font-weight:400">Si no cambia, cierra la página y vuelve a abrirla.</small>';
    f.onclick = function () { f.textContent = 'Actualizando…'; location.reload(); };
    document.body.appendChild(f);
  }

  function revisar() {
    if (avisado || revisando || document.hidden || navigator.onLine === false) return;
    revisando = true;
    fetch(location.pathname + '?v=' + Date.now(), { method: 'HEAD', cache: 'no-store' })
      .then(function (r) {
        var publicada = Date.parse(r.headers.get('last-modified') || '');
        if (r.ok && publicada && publicada - abierta > 5000) avisar();
      })
      .catch(function () { /* sin conexión: se revisa en la siguiente vuelta */ })
      .then(function () { revisando = false; });
  }

  setInterval(revisar, 3 * 60 * 1000);
  document.addEventListener('visibilitychange', revisar);
  window.addEventListener('focus', revisar);
  window.addEventListener('online', revisar);
  setTimeout(revisar, 20000);
})();
