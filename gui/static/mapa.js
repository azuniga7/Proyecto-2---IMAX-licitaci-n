// mapa.js | Mapa de asientos en vivo (se actualiza solo cada pocos segundos).
// Estados que llegan del servidor: disponible, ocupado, bloqueado (de otro) y mio.
(function () {
  const cfg = window.CFG;
  const mapa = document.getElementById("mapa");
  const form = document.getElementById("form-compra");
  const lista = document.getElementById("lista-sel");
  const vacio = document.getElementById("vacio");
  const totalEl = document.getElementById("total");
  const cuentaEl = document.getElementById("cuenta");
  const continuar = document.getElementById("continuar");
  const toastEl = document.getElementById("toast");

  const CLASE = { disponible: "libre", ocupado: "ocupado", bloqueado: "otro", mio: "mio" };
  let asientos = [];
  let tipoSel = {};      // asiento_id -> tipo_entrada_id elegido
  let firma = "";        // detecta si cambió la lista de asientos propios
  let segundos = null;   // lo que le queda al bloqueo que vence primero
  let peticion = 0;

  function dinero(n) {
    return cfg.moneda + n.toLocaleString("es-CR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  let temporizador = null;
  function aviso(texto) {
    toastEl.textContent = texto;
    toastEl.hidden = false;
    clearTimeout(temporizador);
    temporizador = setTimeout(function () { toastEl.hidden = true; }, 4000);
  }

  function pintarMapa() {
    mapa.replaceChildren();
    let zonaActual = null, filaActual = null, contenedor = null;
    asientos.forEach(function (a) {
      if (a.zona !== zonaActual) {
        zonaActual = a.zona; filaActual = null;
        const h = document.createElement("div");
        h.className = "zona";
        h.textContent = "Zona " + a.zona;
        mapa.appendChild(h);
      }
      if (a.fila !== filaActual) {
        filaActual = a.fila;
        contenedor = document.createElement("div");
        contenedor.className = "fila";
        const etq = document.createElement("span");
        etq.className = "etq";
        etq.textContent = a.fila;
        contenedor.appendChild(etq);
        mapa.appendChild(contenedor);
      }
      const b = document.createElement("button");
      b.type = "button";
      b.className = "asiento " + CLASE[a.estado];
      b.textContent = a.numero;
      b.dataset.id = a.id;
      b.title = "Fila " + a.fila + ", asiento " + a.numero + " · zona " + a.zona;
      b.setAttribute("aria-label", b.title + " (" + a.estado + ")");
      if (a.estado === "ocupado" || a.estado === "bloqueado") b.disabled = true;
      contenedor.appendChild(b);
    });
  }

  function calcularTotal() {
    let total = 0, faltaTarifa = false;
    lista.querySelectorAll("select").forEach(function (sel) {
      const opciones = cfg.tarifas[sel.dataset.zona] || [];
      const t = opciones.find(function (x) { return String(x.id) === sel.value; });
      if (t) total += t.precio; else faltaTarifa = true;
    });
    totalEl.textContent = dinero(total);
    continuar.disabled = faltaTarifa;
  }

  function actualizarPanel() {
    const mios = asientos.filter(function (a) { return a.estado === "mio"; });
    const nueva = mios.map(function (a) { return a.id; }).join(",");
    form.hidden = mios.length === 0;
    vacio.hidden = mios.length > 0;
    if (nueva !== firma) {
      firma = nueva;
      lista.replaceChildren();
      mios.forEach(function (a) {
        const li = document.createElement("li");
        const nombre = document.createElement("span");
        nombre.textContent = "Fila " + a.fila + " · asiento " + a.numero + " (" + a.zona + ")";
        const oculto = document.createElement("input");
        oculto.type = "hidden"; oculto.name = "asiento"; oculto.value = a.id;
        const sel = document.createElement("select");
        sel.name = "tipo"; sel.dataset.zona = a.zona;
        sel.setAttribute("aria-label", "Tipo de entrada del asiento " + a.fila + a.numero);
        (cfg.tarifas[a.zona] || []).forEach(function (t) {
          const o = document.createElement("option");
          o.value = t.id;
          o.textContent = t.nombre + " · " + dinero(t.precio);
          if (String(tipoSel[a.id]) === String(t.id)) o.selected = true;
          sel.appendChild(o);
        });
        tipoSel[a.id] = sel.value;
        sel.addEventListener("change", function () { tipoSel[a.id] = sel.value; calcularTotal(); });
        li.append(nombre, oculto, sel);
        lista.appendChild(li);
      });
      calcularTotal();
    }
    const vence = mios.map(function (a) { return a.seg; }).filter(function (s) { return s !== null; });
    segundos = vence.length ? Math.min.apply(null, vence) : null;
    pintarCuenta();
  }

  function pintarCuenta() {
    if (segundos === null) { cuentaEl.textContent = ""; return; }
    const m = String(Math.floor(segundos / 60)).padStart(2, "0");
    const s = String(segundos % 60).padStart(2, "0");
    cuentaEl.textContent = "Tus asientos se liberan en " + m + ":" + s + " si no completas la compra.";
  }

  async function refrescar() {
    const mia = ++peticion;
    try {
      const r = await fetch("/api/funcion/" + cfg.funcionId + "/mapa", { headers: { Accept: "application/json" } });
      if (r.status === 401) { location.href = "/login"; return; }
      const d = await r.json();
      if (mia !== peticion || !d.ok) return;
      asientos = d.asientos;
      pintarMapa();
      actualizarPanel();
    } catch (e) { /* sin conexión: se reintenta en el siguiente ciclo */ }
  }

  mapa.addEventListener("click", async function (ev) {
    const b = ev.target.closest("button.asiento");
    if (!b) return;
    const a = asientos.find(function (x) { return String(x.id) === b.dataset.id; });
    if (!a) return;
    if (a.estado === "mio") { aviso("Ese asiento ya es tuyo. Puedes cambiar el tipo de entrada a la derecha."); return; }
    if (a.estado !== "disponible") { aviso("Ese asiento no está disponible."); return; }
    b.disabled = true;
    try {
      const r = await fetch("/api/funcion/" + cfg.funcionId + "/bloquear", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ asiento_id: a.id })
      });
      if (r.status === 401) { location.href = "/login"; return; }
      const d = await r.json().catch(function () { return {}; });
      if (!d.ok) aviso(d.error || "No se pudo bloquear el asiento.");
    } catch (e) {
      aviso("No hay conexión con el servidor.");
    }
    refrescar();
  });

  // cuenta regresiva local; al llegar a cero se vuelve a consultar el mapa
  setInterval(function () {
    if (segundos === null) return;
    if (segundos > 0) { segundos -= 1; pintarCuenta(); }
    if (segundos === 0) { segundos = null; refrescar(); }
  }, 1000);

  refrescar();
  setInterval(refrescar, 4000);
})();
