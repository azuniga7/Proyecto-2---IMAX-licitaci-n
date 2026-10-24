"""
app.py  |  Proyecto 2: Licitacion IMAX  |  Interfaz web (Flask + PostgreSQL)

Pantallas:
  1. Cartelera con filtros                (cliente, taquillero)
  2. Mapa de asientos en vivo             (cliente, taquillero)
  3. Pago simulado                        (cliente, taquillero)
  4. Entrada digital con QR               (cliente; el taquillero la ve al cobrar)
  5. Dashboard                            (contador, administrador)
  6. Administracion (administrador): peliculas, funciones, precios y promociones, salas,
     operaciones manuales (reembolso forzado, cambio de asiento, cortesias, configuracion) y bitacora
  Extras: login con contrasena, validacion de QR en puerta (operador de sala), corte de caja (taquillero)

Toda la logica de negocio esta en la base de datos (funciones, vistas, triggers).
Esta app solo llama a esas funciones y vistas. Para cada peticion se hace
SET ROLE al rol de PostgreSQL que corresponde al usuario, asi que los permisos
del script 07 se aplican de verdad.

Antes de correrla: scripts 01 a 07, 09 (datos), 11_app_gui.sql y 12_login_seguro.sql.
Ver gui/LEEME.md.
"""
import io
import os
import time
import uuid
from contextlib import contextmanager
from datetime import date
from functools import wraps

import psycopg2
import psycopg2.extras
import psycopg2.pool
import qrcode
import qrcode.image.svg
from flask import (Flask, Response, abort, flash, jsonify, redirect,
                   render_template, request, session, url_for)
from psycopg2 import sql

# ------------------------------------------------------------------ CONFIGURACION
DB = dict(
    host=os.getenv("IMAX_DB_HOST", "localhost"),
    port=int(os.getenv("IMAX_DB_PORT", "5432")),
    dbname=os.getenv("IMAX_DB_NAME", "imax"),
    user=os.getenv("IMAX_DB_USER", "app_imax"),
    password=os.getenv("IMAX_DB_PASSWORD", "imax_app_2026"),
)
SECRET_KEY = os.getenv("IMAX_SECRET_KEY", "cambiar-esta-clave-imax-2026")
MONEDA = ""                           # simbolo que se muestra antes de los precios ("" = ninguno)
ZONA_HORARIA = "America/Costa_Rica"   # para mostrar fechas y horas
POR_PELICULA = 10                     # funciones que se muestran por pelicula en la cartelera

# rol de la tabla "rol"  ->  rol de PostgreSQL (script 07)
ROL_PG = {
    "cliente": "rol_cliente",
    "taquillero": "rol_taquillero",
    "operador_sala": "rol_operador_sala",
    "contador": "rol_contador",
    "administrador": "rol_administrador",
}
# pantalla inicial de cada rol
DESTINO_INICIAL = {
    "cliente": "cartelera",
    "taquillero": "cartelera",
    "operador_sala": "validar",
    "contador": "dashboard",
    "administrador": "dashboard",
}

app = Flask(__name__)
app.secret_key = SECRET_KEY


# ------------------------------------------------------------------ BASE DE DATOS
_pool = None


def get_pool():
    global _pool
    if _pool is None:
        _pool = psycopg2.pool.ThreadedConnectionPool(1, 10, **DB)
    return _pool


@contextmanager
def db(rol_pg=None):
    """Entrega un cursor (filas como diccionarios). Si se indica rol_pg, la
    transaccion corre con SET LOCAL ROLE, que se deshace sola al terminar.
    Hace commit si todo sale bien y rollback si hay un error."""
    pool = get_pool()
    con = pool.getconn()
    try:
        cur = con.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        cur.execute(sql.SQL("SET LOCAL TIME ZONE {}").format(sql.Literal(ZONA_HORARIA)))
        if rol_pg:
            cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(rol_pg)))
        yield cur
        con.commit()
    except Exception:
        try:
            con.rollback()
        except Exception:
            pass
        raise
    finally:
        pool.putconn(con, close=bool(con.closed))


def usar_db():
    """Conexion con el rol de PostgreSQL del usuario que inicio sesion."""
    return db(ROL_PG[session["rol"]])


def consulta(cur, texto, params=()):
    """Ejecuta una consulta de lectura sin romper la transaccion si falla
    (por ejemplo por 'permission denied'). Devuelve {'filas': ..., 'error': ...}."""
    cur.execute("SAVEPOINT consulta")
    try:
        cur.execute(texto, params)
        filas = cur.fetchall()
        cur.execute("RELEASE SAVEPOINT consulta")
        return {"filas": filas, "error": None}
    except psycopg2.Error as e:
        cur.execute("ROLLBACK TO SAVEPOINT consulta")
        return {"filas": None, "error": msg_error(e)}


def msg_error(e):
    """Mensaje corto de un error de PostgreSQL (el texto del RAISE EXCEPTION)."""
    diag = getattr(e, "diag", None)
    texto = getattr(diag, "message_primary", None) if diag else None
    return texto or (str(e).strip().splitlines() or ["Error de base de datos"])[0]


_cache = {}


def con_cache(clave, calcular, ttl=60):
    ahora = time.time()
    hit = _cache.get(clave)
    if hit and ahora - hit[0] < ttl:
        return hit[1]
    valor = calcular()
    _cache[clave] = (ahora, valor)
    return valor


# ------------------------------------------------------------------ SESION
def login_required(*roles):
    def decorador(f):
        @wraps(f)
        def envoltura(*a, **k):
            if "uid" not in session:
                if request.path.startswith("/api/"):
                    return jsonify(ok=False, error="Sesion vencida, vuelve a iniciar sesion"), 401
                return redirect(url_for("login", next=request.path))
            if roles and session["rol"] not in roles:
                if request.path.startswith("/api/"):
                    return jsonify(ok=False, error="Tu rol no tiene acceso"), 403
                flash("Tu rol no tiene acceso a esa pantalla.", "error")
                return redirect(url_for("inicio"))
            return f(*a, **k)
        return envoltura
    return decorador


# ------------------------------------------------------------------ FORMATOS
@app.template_filter("dinero")
def f_dinero(v):
    if v is None:
        return ""
    return f"{MONEDA}{float(v):,.2f}".replace(",", " ")


@app.template_filter("hora")
def f_hora(v):
    return v.strftime("%H:%M") if v else ""


@app.template_filter("fechacorta")
def f_fecha_corta(v):
    return v.strftime("%d/%m") if v else ""


@app.template_filter("fechalarga")
def f_fecha_larga(v):
    return v.strftime("%d/%m/%Y") if v else ""


@app.template_filter("fechahora")
def f_fecha_hora(v):
    return v.strftime("%d/%m/%Y %H:%M") if v else ""


# ------------------------------------------------------------------ ERRORES
@app.errorhandler(404)
def no_encontrado(_e):
    return render_template("error.html", titulo="No encontrado",
                           mensaje="La pagina, funcion o compra que buscas no existe o no es tuya."), 404


@app.errorhandler(psycopg2.Error)
def error_bd(e):
    return render_template("error.html", titulo="Error de base de datos",
                           mensaje=msg_error(e)), 500


# ------------------------------------------------------------------ LOGIN
@app.route("/")
def inicio():
    if "uid" not in session:
        return redirect(url_for("login"))
    return redirect(url_for(DESTINO_INICIAL[session["rol"]]))


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        correo = request.form.get("correo", "").strip()
        clave = request.form.get("clave", "")
        try:
            with db() as cur:
                cur.execute("SELECT * FROM fn_login_usuario(%s, %s)", (correo, clave))
                u = cur.fetchone()
        except psycopg2.Error as e:
            flash(f"No se pudo consultar la base de datos: {msg_error(e)}", "error")
            return render_template("login.html")
        if not u or u["rol"] not in ROL_PG:
            flash("Correo o contraseña incorrectos.", "error")
            return render_template("login.html")
        session.clear()
        session["uid"] = u["usuario_id"]
        session["nombre"] = f"{u['nombre']} {u['apellido']}"
        session["rol"] = u["rol"]
        destino = request.args.get("next", "")
        if destino.startswith("/") and not destino.startswith("//"):
            return redirect(destino)
        return redirect(url_for("inicio"))
    return render_template("login.html")


@app.post("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ------------------------------------------------------------------ 1. CARTELERA
@app.route("/cartelera")
@login_required("cliente", "taquillero")
def cartelera():
    if request.args:
        f = {k: request.args.get(k, "").strip()
             for k in ("q", "genero", "ciudad", "cine", "clasificacion", "fecha")}
    else:  # primera visita: solo las funciones de hoy
        f = dict(q="", genero="", ciudad="", cine="", clasificacion="", fecha=date.today().isoformat())

    cond, par = [], []
    if f["q"]:
        cond.append("titulo ILIKE %s")
        par.append(f"%{f['q']}%")
    if f["genero"]:
        cond.append("%s = ANY(generos)")
        par.append(f["genero"])
    if f["ciudad"]:
        cond.append("ciudad = %s")
        par.append(f["ciudad"])
    if f["cine"].isdigit():
        cond.append("cine_id = %s")
        par.append(int(f["cine"]))
    if f["clasificacion"]:
        cond.append("clasificacion = %s")
        par.append(f["clasificacion"])
    if f["fecha"]:
        try:
            dia = date.fromisoformat(f["fecha"])
            cond.append("inicio >= %s::date AND inicio < (%s::date + 1)")
            par += [dia, dia]
        except ValueError:
            flash("La fecha no es valida, se ignoro el filtro.", "error")
            f["fecha"] = ""
    donde = ("WHERE " + " AND ".join(cond)) if cond else ""

    consulta_sql = f"""
        WITH x AS (
            SELECT v.*,
                   row_number() OVER (PARTITION BY pelicula_id ORDER BY inicio) AS rn,
                   count(*)     OVER (PARTITION BY pelicula_id)                 AS total
            FROM v_cartelera v
            {donde}
        )
        SELECT * FROM x WHERE rn <= %s ORDER BY titulo, inicio"""

    with usar_db() as cur:
        cur.execute(consulta_sql, par + [POR_PELICULA])
        filas = cur.fetchall()

        def opciones():
            cur.execute("SELECT DISTINCT unnest(generos) AS g FROM v_cartelera ORDER BY 1")
            generos = [r["g"] for r in cur.fetchall()]
            cur.execute("SELECT DISTINCT cine_id, cine, ciudad FROM v_cartelera ORDER BY ciudad, cine")
            cines = cur.fetchall()
            cur.execute("SELECT DISTINCT clasificacion FROM v_cartelera ORDER BY 1")
            clasif = [r["clasificacion"] for r in cur.fetchall()]
            return dict(generos=generos, cines=cines,
                        ciudades=sorted({c["ciudad"] for c in cines}), clasificaciones=clasif)

        opc = con_cache("opciones_cartelera", opciones)

    peliculas = {}
    for r in filas:
        p = peliculas.setdefault(r["pelicula_id"], dict(
            titulo=r["titulo"], sinopsis=r["sinopsis"], duracion_min=r["duracion_min"],
            clasificacion=r["clasificacion"], generos_texto=r["generos_texto"],
            poster_url=r["poster_url"], total=r["total"], funciones=[]))
        p["funciones"].append(r)
    return render_template("cartelera.html", peliculas=list(peliculas.values()), f=f, opc=opc)


# ------------------------------------------------------------------ 2. MAPA DE ASIENTOS
@app.route("/funcion/<int:funcion_id>")
@login_required("cliente", "taquillero")
def funcion(funcion_id):
    with usar_db() as cur:
        cur.execute("SELECT * FROM v_cartelera WHERE funcion_id = %s", (funcion_id,))
        f = cur.fetchone()
        if not f:
            abort(404)
        cur.execute("""SELECT zona, tipo_entrada_id, tipo_entrada, precio
                       FROM v_tarifas_funcion WHERE funcion_id = %s
                       ORDER BY zona, tipo_entrada_id""", (funcion_id,))
        tarifas = {}
        for t in cur.fetchall():
            tarifas.setdefault(t["zona"], []).append(dict(
                id=t["tipo_entrada_id"],
                nombre=t["tipo_entrada"].replace("_", " ").capitalize(),
                precio=float(t["precio"])))
    cfg = dict(funcionId=funcion_id, tarifas=tarifas, moneda=MONEDA)
    return render_template("funcion.html", f=f, cfg=cfg)


@app.route("/api/funcion/<int:funcion_id>/mapa")
@login_required("cliente", "taquillero")
def api_mapa(funcion_id):
    uid = session["uid"]
    with usar_db() as cur:
        cur.execute("""
            SELECT asiento_id, zona, fila, numero, estado, bloqueado_por,
                   CASE WHEN bloqueado_hasta IS NOT NULL
                        THEN GREATEST(0, extract(epoch FROM (bloqueado_hasta - now()))::int)
                   END AS seg
            FROM v_mapa_asientos
            WHERE funcion_id = %s
            ORDER BY fila, numero""", (funcion_id,))
        filas = cur.fetchall()
    asientos = []
    for r in filas:
        estado = r["estado"]
        if estado == "bloqueado" and r["bloqueado_por"] == uid:
            estado = "mio"
        asientos.append(dict(id=r["asiento_id"], zona=r["zona"], fila=r["fila"],
                             numero=r["numero"], estado=estado,
                             seg=r["seg"] if estado == "mio" else None))
    return jsonify(ok=True, asientos=asientos)


@app.post("/api/funcion/<int:funcion_id>/bloquear")
@login_required("cliente", "taquillero")
def api_bloquear(funcion_id):
    datos = request.get_json(silent=True) or {}
    try:
        asiento = int(datos.get("asiento_id"))
    except (TypeError, ValueError):
        return jsonify(ok=False, error="Asiento invalido"), 400
    try:
        with usar_db() as cur:
            cur.execute("SELECT fn_bloquear_asiento(%s::bigint, %s::bigint, %s::bigint) AS hasta",
                        (funcion_id, asiento, session["uid"]))
        return jsonify(ok=True)
    except psycopg2.Error as e:
        return jsonify(ok=False, error=msg_error(e)), 409


@app.post("/funcion/<int:funcion_id>/comprar")
@login_required("cliente", "taquillero")
def comprar(funcion_id):
    try:
        asientos = [int(x) for x in request.form.getlist("asiento")]
        tipos = [int(x) for x in request.form.getlist("tipo")]
    except ValueError:
        flash("Seleccion invalida.", "error")
        return redirect(url_for("funcion", funcion_id=funcion_id))
    if not asientos or len(asientos) != len(tipos):
        flash("Elige al menos un asiento y su tipo de entrada.", "error")
        return redirect(url_for("funcion", funcion_id=funcion_id))

    uid = session["uid"]
    es_taquilla = session["rol"] == "taquillero"
    comprador = None if es_taquilla else uid    # en taquilla el comprador no tiene cuenta
    vendedor = uid if es_taquilla else None
    try:
        with usar_db() as cur:
            cur.execute("""SELECT fn_crear_compra(%s::bigint, %s::bigint, %s::bigint[], %s::int[], %s::bigint) AS id""",
                        (comprador, funcion_id, asientos, tipos, vendedor))
            compra_id = cur.fetchone()["id"]
    except psycopg2.Error as e:
        flash(msg_error(e), "error")
        return redirect(url_for("funcion", funcion_id=funcion_id))
    return redirect(url_for("pago", compra_id=compra_id))


# ------------------------------------------------------------------ 3. PAGO SIMULADO
SQL_COMPRA = """
    SELECT r.*,
           CASE WHEN r.bloqueo_hasta IS NOT NULL
                THEN GREATEST(0, extract(epoch FROM (r.bloqueo_hasta - now()))::int)
           END AS segundos
    FROM v_compra_resumen r
    WHERE r.compra_id = %s AND (r.usuario_id = %s OR r.vendedor_id = %s)"""


@app.route("/pago/<int:compra_id>", methods=["GET", "POST"])
@login_required("cliente", "taquillero")
def pago(compra_id):
    uid = session["uid"]

    if request.method == "POST":
        try:
            metodo = int(request.form.get("metodo", ""))
        except ValueError:
            flash("Elige un metodo de pago.", "error")
            return redirect(url_for("pago", compra_id=compra_id))
        aprobar = request.form.get("resultado", "aprobar") == "aprobar"
        texto = None
        try:
            with usar_db() as cur:
                cur.execute(SQL_COMPRA, (compra_id, uid, uid))
                c = cur.fetchone()
                if not c:
                    abort(404)
                if c["estado"] == "pendiente":
                    cur.execute("SELECT fn_pagar_compra(%s::bigint, %s::smallint, %s::boolean) AS r",
                                (compra_id, metodo, aprobar))
                    texto = cur.fetchone()["r"]
                else:
                    flash(f"Esa compra ya fue procesada (estado: {c['estado']}).", "info")
        except psycopg2.Error as e:
            flash(msg_error(e), "error")
            return redirect(url_for("pago", compra_id=compra_id))
        if texto:
            aprobado = texto.startswith("APROBADO")
            flash(texto, "ok" if aprobado else "error")
            if aprobado:
                return redirect(url_for("entradas_compra", compra_id=compra_id))
        return redirect(url_for("pago", compra_id=compra_id))

    with usar_db() as cur:
        cur.execute(SQL_COMPRA, (compra_id, uid, uid))
        c = cur.fetchone()
        if not c:
            abort(404)
        cur.execute("""SELECT * FROM v_compra_boletos WHERE compra_id = %s
                       ORDER BY fila, numero""", (compra_id,))
        boletos = cur.fetchall()
        cur.execute("SELECT metodo_pago_id, nombre FROM metodo_pago ORDER BY metodo_pago_id")
        metodos = cur.fetchall()
    return render_template("pago.html", c=c, boletos=boletos, metodos=metodos)


# ------------------------------------------------------------------ 4. ENTRADAS CON QR
@app.route("/mis-entradas")
@login_required("cliente")
def mis_entradas():
    ver = request.args.get("ver", "proximas")
    proximas = ver != "pasadas"
    with usar_db() as cur:
        if proximas:
            cur.execute("""SELECT * FROM v_mis_boletos
                           WHERE usuario_id = %s AND inicio >= now() - interval '3 hours'
                           ORDER BY inicio, fila, numero LIMIT 60""", (session["uid"],))
        else:
            cur.execute("""SELECT * FROM v_mis_boletos
                           WHERE usuario_id = %s AND inicio < now() - interval '3 hours'
                           ORDER BY inicio DESC, fila, numero LIMIT 60""", (session["uid"],))
        boletos = cur.fetchall()
    return render_template("entradas.html", boletos=boletos, ver=ver, tabs=True,
                           titulo_pagina="Mis entradas")


@app.route("/compra/<int:compra_id>/entradas")
@login_required("cliente", "taquillero")
def entradas_compra(compra_id):
    uid = session["uid"]
    with usar_db() as cur:
        cur.execute("""SELECT * FROM v_compra_boletos
                       WHERE compra_id = %s AND (usuario_id = %s OR vendedor_id = %s)
                         AND estado IN ('valido', 'usado')
                       ORDER BY fila, numero""", (compra_id, uid, uid))
        boletos = cur.fetchall()
    if not boletos:
        flash("Esa compra no tiene entradas emitidas todavia.", "info")
        return redirect(url_for("pago", compra_id=compra_id))
    return render_template("entradas.html", boletos=boletos, ver=None, tabs=False,
                           titulo_pagina=f"Entradas de la compra #{compra_id}")


@app.route("/qr/<codigo>.svg")
@login_required("cliente", "taquillero")
def qr(codigo):
    try:
        uuid.UUID(codigo)
    except ValueError:
        abort(404)
    img = qrcode.make(codigo, image_factory=qrcode.image.svg.SvgPathImage, box_size=10, border=1)
    buf = io.BytesIO()
    img.save(buf)
    return Response(buf.getvalue(), mimetype="image/svg+xml")


# ------------------------------------------------------------------ TAQUILLA: CORTE DE CAJA
@app.route("/corte")
@login_required("taquillero")
def corte():
    with usar_db() as cur:
        cur.execute("""SELECT dia, metodo_pago, compras, total FROM v_corte_caja
                       WHERE vendedor_id = %s ORDER BY dia DESC, metodo_pago LIMIT 60""",
                    (session["uid"],))
        filas = cur.fetchall()
    hoy = date.today()
    total_hoy = sum(float(r["total"]) for r in filas if r["dia"] == hoy)
    compras_hoy = sum(r["compras"] for r in filas if r["dia"] == hoy)
    return render_template("corte.html", filas=filas, total_hoy=total_hoy, compras_hoy=compras_hoy)


# ------------------------------------------------------------------ OPERADOR: VALIDAR ENTRADA
@app.route("/validar", methods=["GET", "POST"])
@login_required("operador_sala")
def validar():
    resultado = None
    valores = dict(codigo="", funcion="", puerta="Puerta 1")
    if request.method == "POST":
        valores = dict(codigo=request.form.get("codigo", "").strip(),
                       funcion=request.form.get("funcion", "").strip(),
                       puerta=request.form.get("puerta", "").strip() or "Puerta 1")
        try:
            codigo = str(uuid.UUID(valores["codigo"]))
            funcion_id = int(valores["funcion"])
        except ValueError:
            resultado = dict(ok=False, texto="Revisa el codigo QR (formato UUID) y el numero de funcion.")
        else:
            try:
                with usar_db() as cur:
                    cur.execute("SELECT fn_validar_entrada(%s::uuid, %s::bigint, %s::varchar) AS r",
                                (codigo, funcion_id, valores["puerta"]))
                    texto = cur.fetchone()["r"]
                resultado = dict(ok=texto.startswith("ACCESO PERMITIDO"), texto=texto)
            except psycopg2.Error as e:
                resultado = dict(ok=False, texto=msg_error(e))
    with usar_db() as cur:
        cur.execute("""SELECT funcion_id, titulo, cine, sala, inicio FROM v_cartelera
                       ORDER BY inicio LIMIT 12""")
        proximas = cur.fetchall()
    return render_template("validar.html", resultado=resultado, v=valores, proximas=proximas)


# ------------------------------------------------------------------ 5. DASHBOARD
SQL_VENTAS = """
    SELECT dia, boletos, ingresos, (current_date - dia) AS antiguedad
    FROM v_ventas_diarias
    WHERE dia >= current_date - 13
    ORDER BY dia"""

SQL_METODOS = """
    SELECT mp.nombre AS metodo_pago,
           count(*)  AS pagos,
           round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS porcentaje
    FROM pago pa
    JOIN metodo_pago mp ON mp.metodo_pago_id = pa.metodo_pago_id
    WHERE pa.estado = 'aprobado'
    GROUP BY mp.nombre
    ORDER BY pagos DESC"""

SQL_TOP = """
    SELECT p.pelicula_id, p.titulo, count(*) AS boletos_vendidos
    FROM boleto b
    JOIN funcion  f ON f.funcion_id  = b.funcion_id
    JOIN pelicula p ON p.pelicula_id = f.pelicula_id
    WHERE b.estado IN ('valido', 'usado')
      AND b.fecha_emision >= now() - interval '7 days'
    GROUP BY p.pelicula_id, p.titulo
    ORDER BY boletos_vendidos DESC, p.titulo
    LIMIT 5"""

SQL_OCUPACION = """
    SELECT funcion_id, titulo, cine, sala, inicio, capacidad,
           asientos_vendidos, porcentaje_ocupacion, ingresos
    FROM v_ocupacion_funcion
    WHERE inicio >= now() AND inicio < now() + interval '1 day'
    ORDER BY porcentaje_ocupacion DESC, inicio
    LIMIT 10"""

SQL_FUNCION = """
    SELECT funcion_id, titulo, cine, sala, inicio, capacidad,
           asientos_vendidos, porcentaje_ocupacion, ingresos
    FROM v_ocupacion_funcion
    WHERE funcion_id = %s"""

SQL_AUDITORIA = """
    SELECT a.usuario_id,
           u.nombre || ' ' || u.apellido AS administrador,
           a.accion,
           count(*)     AS operaciones,
           max(a.fecha) AS ultima
    FROM admin_operacion_audit a
    JOIN usuario u ON u.usuario_id = a.usuario_id
    WHERE a.fecha >= now() - interval '1 month'
    GROUP BY a.usuario_id, u.nombre, u.apellido, a.accion
    ORDER BY a.usuario_id, operaciones DESC"""


@app.route("/dashboard")
@login_required("contador", "administrador")
def dashboard():
    fid = request.args.get("funcion", "").strip()
    d = {}
    with usar_db() as cur:
        d["ventas"] = consulta(cur, SQL_VENTAS)
        d["metodos"] = consulta(cur, SQL_METODOS)
        d["ocupacion"] = consulta(cur, SQL_OCUPACION)
        d["top"] = consulta(cur, SQL_TOP)
        d["auditoria"] = consulta(cur, SQL_AUDITORIA)
        d["una"] = consulta(cur, SQL_FUNCION, (int(fid),)) if fid.isdigit() else None

    # indicadores de los ultimos 7 dias y barras de ventas
    kpi = dict(boletos=0, ingresos=0.0)
    if d["ventas"]["filas"]:
        maximo = max(float(r["ingresos"]) for r in d["ventas"]["filas"]) or 1.0
        for r in d["ventas"]["filas"]:
            r["pct"] = round(100.0 * float(r["ingresos"]) / maximo, 1)
            if r["antiguedad"] <= 6:
                kpi["boletos"] += r["boletos"]
                kpi["ingresos"] += float(r["ingresos"])
    if d["top"]["filas"]:
        maximo = max(r["boletos_vendidos"] for r in d["top"]["filas"]) or 1
        for r in d["top"]["filas"]:
            r["pct"] = round(100.0 * r["boletos_vendidos"] / maximo, 1)
    return render_template("dashboard.html", d=d, kpi=kpi, fid=fid)


import admin  # noqa: E402  (pantallas del administrador)

admin.registrar(app, login_required, usar_db, msg_error)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
