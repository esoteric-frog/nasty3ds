/// The one page the phone gets. Self-contained: no outside scripts, fonts or images.
public enum PhonePage {
    public static func html(livePort: UInt16) -> String {
        template.replacingOccurrences(of: "__LIVE_PORT__", with: String(livePort))
    }

    private static let template = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Nasty3DS">
    <meta name="theme-color" content="#000000">
    <title>Nasty3DS</title>
    <style>
    :root { color-scheme: dark; }
    html, body { margin: 0; height: 100%; background: #000; overflow: hidden; touch-action: none;
      -webkit-user-select: none; user-select: none; -webkit-touch-callout: none;
      -webkit-tap-highlight-color: transparent; }
    /* The lower screen is 4:3. It takes the largest size that fits inside the safe area. */
    #screen { position: fixed; inset: 0; margin: auto; display: block;
      --w: calc(100vw - env(safe-area-inset-left) - env(safe-area-inset-right));
      --h: calc(100dvh - env(safe-area-inset-top) - env(safe-area-inset-bottom));
      width: min(var(--w), calc(var(--h) * 4 / 3)); height: min(var(--h), calc(var(--w) * 3 / 4));
      image-rendering: pixelated; opacity: 0; transition: opacity 240ms cubic-bezier(0.16, 1, 0.3, 1); }
    #screen.live { opacity: 1; }
    #screen.dim { opacity: 0.3; }
    #status { position: fixed; inset: 0; display: flex; align-items: center; justify-content: center;
      gap: 10px; padding: 24px; color: #f5f5f7; font: 500 17px/1.35 -apple-system, system-ui, sans-serif;
      text-align: center; pointer-events: none; transition: opacity 240ms cubic-bezier(0.16, 1, 0.3, 1); }
    #status:empty { opacity: 0; }
    #status.busy::before { content: ""; flex: none; width: 8px; height: 8px; border-radius: 50%;
      background: #f5f5f7; animation: wait 1.2s ease-in-out infinite; }
    /* Safari on the iPhone cannot hide its bars for a page. This note says how to get full screen. */
    #tip { position: fixed; left: 0; right: 0; bottom: calc(env(safe-area-inset-bottom) + 12px); margin: 0 auto;
      width: fit-content; max-width: calc(100vw - 32px); box-sizing: border-box; display: none; align-items: center;
      gap: 12px; padding: 10px 10px 10px 16px; border-radius: 14px; background: #1c1c1e; color: #f5f5f7;
      font: 15px/1.3 -apple-system, system-ui, sans-serif; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5); }
    #tip.show { display: flex; }
    #wake { position: fixed; left: 0; right: 0; top: calc(env(safe-area-inset-top) + 12px); margin: 0 auto;
      width: fit-content; max-width: calc(100vw - 32px); display: none; padding: 8px 14px; border-radius: 12px;
      background: #1c1c1e; color: #f5f5f7; font: 15px/1.3 -apple-system, system-ui, sans-serif;
      box-shadow: 0 8px 24px rgba(0, 0, 0, 0.5); pointer-events: none; }
    #wake.show { display: block; }
    #tip button { flex: none; border: 0; border-radius: 10px; padding: 8px 12px; background: #3a3a3c; color: #f5f5f7;
      font: 600 15px -apple-system, system-ui, sans-serif; touch-action: manipulation; }
    #tip button:active { background: #48484a; }
    @keyframes wait { 0%, 100% { opacity: 0.25; transform: scale(0.8); } 50% { opacity: 1; transform: scale(1); } }
    @media (prefers-reduced-motion: reduce) {
      #screen, #status { transition: none; }
      #status.busy::before { animation: none; opacity: 0.7; }
    }
    </style>
    </head>
    <body>
    <img id="screen" alt="Lower game screen" draggable="false">
    <div id="status" class="busy" role="status" aria-live="polite">Connecting to your Mac…</div>
    <div id="wake" role="status">Tap the screen once to keep the display on.</div>
    <div id="tip"><span>For full screen: tap Share, then Add to Home Screen.</span><button type="button" id="tipHide">Hide</button></div>
    <script>
    const key = new URLSearchParams(location.search).get('k') || '';
    const view = document.getElementById('screen');
    const note = document.getElementById('status');
    let socket = null, retry = 1000, lastURL = null, closed = false;

    function say(text, busy) {
      note.textContent = text;
      note.classList.toggle('busy', !!busy);
      view.classList.toggle('dim', text !== '');
    }
    function send(message) { if (socket && socket.readyState === 1) socket.send(JSON.stringify(message)); }

    // Keep the display on. Safari can refuse the request until a tap has finished, and the
    // system releases the lock when the page is hidden. So: ask at load, ask again after each
    // finished tap until the lock is held, and ask again when the page shows again.
    let wakeLock = null, wakeBusy = false, wakeError = '';
    async function holdWake() {
      if (wakeLock || wakeBusy || !('wakeLock' in navigator)) return;      // a request on a hidden page fails; that is caught
      wakeBusy = true;
      try {
        wakeLock = await navigator.wakeLock.request('screen');
        wakeError = '';
        // The system can take the lock away at any time. Ask for it again at once.
        wakeLock.addEventListener('release', () => { wakeLock = null; wakeError = 'released'; setTimeout(holdWake, 250); });
      } catch (e) { wakeLock = null; wakeError = e && e.name ? e.name : 'error'; }
      wakeBusy = false;
      showWakeNote();
    }
    if (!('wakeLock' in navigator)) wakeError = 'noapi';
    // If the lock is not held, say what to do. One tap is enough.
    function showWakeNote() {
      const need = !wakeLock && document.visibilityState === 'visible';
      document.getElementById('wake').classList.toggle('show', need);
    }
    setInterval(() => { holdWake(); showWakeNote(); }, 10000);      // a lost lock comes back with no tap, if the system allows it
    document.addEventListener('visibilitychange', holdWake);
    for (const name of ['pointerup', 'touchend', 'click']) document.addEventListener(name, holdWake, true);
    holdWake();

    function connect() {
      socket = new WebSocket('wss://' + location.hostname + ':__LIVE_PORT__/');
      socket.binaryType = 'arraybuffer';
      socket.onopen = () => { retry = 1000; closed = false; send({ t: 'hello', k: key }); };
      socket.onmessage = (event) => {
        if (typeof event.data === 'string') {
          let m; try { m = JSON.parse(event.data); } catch (e) { return; }
          if (m.t === 'ping') send({ t: 'pong', id: m.id, w: wakeLock ? 1 : 0, e: wakeError });
          if (m.t === 'state') {
            closed = m.s === 'closed';
            say(m.s === 'closed' ? 'Game closed' : m.s === 'paused' ? 'Game paused' : '', false);
          }
          return;
        }
        const url = URL.createObjectURL(new Blob([event.data], { type: 'image/jpeg' }));
        view.onload = () => { if (lastURL) URL.revokeObjectURL(lastURL); lastURL = url; view.classList.add('live'); };
        view.src = url;
        if (!closed) say('', false);
      };
      socket.onclose = () => {
        if (!closed) say('Connecting to your Mac…', true);
        setTimeout(connect, retry);
        retry = Math.min(retry * 2, 5000);
      };
    }

    function point(event) {
      const r = view.getBoundingClientRect();
      return { u: (event.clientX - r.left) / r.width, v: (event.clientY - r.top) / r.height };
    }
    view.addEventListener('pointerdown', (e) => {
      e.preventDefault();
      view.setPointerCapture(e.pointerId);
      send({ t: 'down', ...point(e) });
    });
    view.addEventListener('pointermove', (e) => {
      if (e.buttons || e.pointerType === 'touch') send({ t: 'move', ...point(e) });
    });
    for (const name of ['pointerup', 'pointercancel']) view.addEventListener(name, () => send({ t: 'up' }));
    for (const name of ['touchstart', 'touchmove', 'gesturestart', 'contextmenu'])
      document.addEventListener(name, (e) => { if (!e.target.closest || !e.target.closest('#tip')) e.preventDefault(); }, { passive: false });

    // Opened from the home screen icon, the page has no Safari bars. In Safari, say how to get that.
    const tip = document.getElementById('tip');
    let tipHidden = false;
    try { tipHidden = localStorage.getItem('tipHidden') === '1'; } catch (e) {}
    if (!navigator.standalone && !tipHidden) tip.classList.add('show');
    document.getElementById('tipHide').addEventListener('click', () => {
      tip.classList.remove('show');
      try { localStorage.setItem('tipHidden', '1'); } catch (e) {}
    });

    connect();
    </script>
    </body>
    </html>
    """#
}
