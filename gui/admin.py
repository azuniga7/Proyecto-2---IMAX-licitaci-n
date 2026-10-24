"""
admin.py  |  Pantallas del administrador (Proyecto 2: Licitacion IMAX)

Se registra desde app.py con registrar(app, ...). Todas las rutas son solo para
el rol "administrador" y corren con SET ROLE rol_administrador, asi que ademas
de la app, la base misma decide que se puede hacer (script 07).

  /admin                 resumen y accesos
  /admin/peliculas       alta de cartelera (sinopsis, clasificacion, duracion, poster, generos)
  /admin/funciones       programar funciones (sala + horario sin traslapes + matriz de precios)
  /admin/precios         matriz de precios por zona y tipo de entrada, y promociones
  /admin/salas           gestion de salas (RN-18: no se tocan salas con ventas)
  /admin/operaciones     reembolso forzado, cambio de asiento, cortesias, configuracion y bitacora
"""
from datetime import date, datetime
from decimal import Decimal, InvalidOperation

import psycopg2
from flask import flash, jsonify, redirect, render_template, request, session, url_for


def registrar(app, login_required, usar_db, msg_error):
    solo_admin = login_required("administrador")

    # ------------------------------------------------------------ utilidades
    def error_amigable(e):
        codigo = getattr(e, "pgcode", None)
        if codigo == "23P01":
            return "Esa sala ya tiene una función que se traslapa con ese horario."
        if codigo == "23503":
            return ("No se puede completar: hay registros que dependen de este dato "
                    "(por ejemplo funciones o boletos).")
        if codigo == "23505":
            return "Ya existe un registro con esos datos."
        if codigo == "42501":
            return "Permiso denegado por la base de datos: " + msg_error(e)
        return msg_error(e)

    def entero(nombre, minimo=None, maximo=None):
        valor = int(request.form.get(nombre, "").strip())
        if (minimo is not None and valor < minimo) or (maximo is not None and valor > maximo):
            raise ValueError(nombre)
        return valor

    def decimal(nombre, minimo=0):
        try:
            valor = Decimal(request.form.get(nombre, "").strip().replace(",", "."))
        except InvalidOperation:
            raise ValueError(nombre)
        if valor < minimo:
            raise ValueError(nombre)
        return valor

    def texto(nombre, obligatorio=True):
        valor = request.form.get(nombre, "").strip()
        if obligatorio and not valor:
            raise ValueError(nombre)
        return valor or None

    def volver(endpoint, **kw):
        return redirect(url_for(endpoint, **kw))

    def resultado_fn(r):
        """Las funciones de la base devuelven texto; 'RECHAZADO...' significa que no se hizo."""
        return ("error" if r.upper().startswith("RECHAZADO") else "ok")

    # ------------------------------------------------------------ resumen
    @app.route("/admin")
    @solo_admin
    def admin_inicio():
        with usar_db() as cur:
            cur.execute("""SELECT
                (SELECT count(*) FROM pelicula WHERE activa)            AS peliculas,
                (SELECT count(*) FROM funcion WHERE activa AND fin > now()) AS funciones,
                (SELECT count(*) FROM sala WHERE activa)                AS salas,
                (SELECT count(*) FROM admin_operacion_audit
                  WHERE fecha >= now() - interval '1 month')            AS operaciones""")
            r = cur.fetchone()
        return render_template("admin_inicio.html", r=r, seccion="inicio")

    # ------------------------------------------------------------ peliculas
    @app.route("/admin/peliculas")
    @solo_admin
    def admin_peliculas():
        with usar_db() as cur:
            cur.execute("SELECT clasificacion_id, codigo, edad_minima FROM clasificacion ORDER BY edad_minima, codigo")
            clasificaciones = cur.fetchall()
            cur.execute("SELECT genero_id, nombre FROM genero ORDER BY nombre")
            generos = cur.fetchall()
            cur.execute("""
                SELECT p.pelicula_id, p.titulo, cl.codigo AS clasificacion, p.duracion_min, p.activa,
                       (SELECT string_agg(g.nombre, ', ' ORDER BY g.nombre)
                          FROM pelicula_genero pg JOIN genero g ON g.genero_id = pg.genero_id
                         WHERE pg.pelicula_id = p.pelicula_id) AS generos
                FROM pelicula p
                JOIN clasificacion cl ON cl.clasificacion_id = p.clasificacion_id
                ORDER BY p.pelicula_id DESC LIMIT 25""")
            peliculas = cur.fetchall()
        return render_template("admin_peliculas.html", seccion="peliculas",
                               clasificaciones=clasificaciones, generos=generos, peliculas=peliculas)

    @app.post("/admin/peliculas/crear")
    @solo_admin
    def admin_pelicula_crear():
        try:
            titulo = texto("titulo")
            sinopsis = texto("sinopsis")
            poster = texto("poster_url", obligatorio=False)
            duracion = entero("duracion_min", 1, 600)
            clasificacion = entero("clasificacion_id")
            generos = [int(x) for x in request.form.getlist("genero")]
        except ValueError:
            flash("Revisa los datos: título, sinopsis, clasificación y duración son obligatorios.", "error")
            return volver("admin_peliculas")
        try:
            with usar_db() as cur:
                cur.execute("""INSERT INTO pelicula (titulo, sinopsis, duracion_min, clasificacion_id, poster_url)
                               VALUES (%s, %s, %s, %s, %s) RETURNING pelicula_id""",
                            (titulo, sinopsis, duracion, clasificacion, poster))
                pid = cur.fetchone()["pelicula_id"]
                for g in generos:
                    cur.execute("INSERT INTO pelicula_genero (pelicula_id, genero_id) VALUES (%s, %s)", (pid, g))
        except psycopg2.Error as e:
            flash(error_amigable(e), "error")
            return volver("admin_peliculas")
        flash(f"Película creada (n.º {pid}). Ya se puede programar en una función.", "ok")
        return volver("admin_peliculas")

    @app.post("/admin/peliculas/<int:pelicula_id>/activa")
    @solo_admin
    def admin_pelicula_activa(pelicula_id):
        try:
            with usar_db() as cur:
                cur.execute("UPDATE pelicula SET activa = NOT activa WHERE pelicula_id = %s RETURNING activa",
                            (pelicula_id,))
                fila = cur.fetchone()
            flash("Película " + ("activada." if fila and fila["activa"] else "desactivada."), "ok")
        except psycopg2.Error as e:
            flash(error_amigable(e), "error")
        return volver("admin_peliculas")

    # ------------------------------------------------------------ funciones
    @app.route("/admin/funciones")
    @solo_admin
    def admin_funciones():
        cine = request.args.get("cine", "")
        with usar_db() as cur:
            cur.execute("SELECT pelicula_id, titulo, duracion_min FROM pelicula WHERE activa ORDER BY titulo")
            peliculas = cur.fetchall()
            cur.execute("""SELECT s.sala_id, c.nombre AS cine, s.nombre AS sala
                           FROM sala s JOIN cine c ON c.cine_id = s.cine_id
                           WHERE s.activa ORDER BY c.nombre, s.nombre""")
            salas = cur.fetchall()
            cur.execute("SELECT cine_id, nombre FROM cine ORDER BY nombre")
            cines = cur.fetchall()
            cur.execute("SELECT tipo_entrada_id, nombre FROM tipo_entrada ORDER BY tipo_entrada_id")
            tipos = cur.fetchall()
            filtro = "AND c.cine_id = %s" if cine.isdigit() else ""
            params = (int(cine),) if cine.isdigit() else ()
            cur.execute(f"""
                SELECT f.funcion_id, p.titulo, c.nombre AS cine, s.nombre AS sala,
                       f.inicio, f.fin, f.activa
                FROM funcion f
                JOIN pelicula p ON p.pelicula_id = f.pelicula_id
                JOIN sala s     ON s.sala_id = f.sala_id
                JOIN cine c     ON c.cine_id = s.cine_id
                WHERE f.fin > now() {filtro}
                ORDER BY f.inicio, f.funcion_id LIMIT 40""", params)
            funciones = cur.fetchall()
        cfg = dict(tipos=[dict(id=t["tipo_entrada_id"], nombre=t["nombre"].replace("_", " ").capitalize())
                          for t in tipos])
        return render_template("admin_funciones.html", seccion="funciones", peliculas=peliculas,
                               salas=salas, cines=cines, funciones=funciones, cine=cine, cfg=cfg)

    @app.route("/api/admin/sala/<int:sala_id>/zonas")
    @solo_admin
    def api_admin_zonas(sala_id):
        with usar_db() as cur:
            cur.execute("""SELECT z.zona_id, z.nombre, count(a.asiento_id) AS asientos
                           FROM zona z LEFT JOIN asiento a ON a.zona_id = z.zona_id
                           WHERE z.sala_id = %s GROUP BY z.zona_id, z.nombre ORDER BY z.zona_id""",
                        (sala_id,))
            zonas = cur.fetchall()
        return jsonify(ok=True, zonas=[dict(id=z["zona_id"], nombre=z["nombre"], asientos=z["asientos"])
                                       for z in zonas])

    @app.post("/admin/funciones/crear")
    @solo_admin
    def admin_funcion_crear():
        try:
            pelicula = entero("pelicula_id")
            sala = entero("sala_id")
            limpieza = entero("limpieza", 0, 180)
            inicio = datetime.strptime(request.form.get("inicio", ""), "%Y-%m-%dT%H:%M")
        except ValueError:
            flash("Revisa película, sala, fecha/hora y minutos de limpieza.", "error")
            return volver("admin_funciones")
        precios = {}
        try:
            for clave in request.form:
                if clave.startswith("precio_"):
                    _, z, t = clave.split("_")
                    precios[(int(z), int(t))] = decimal(clave)
        except ValueError:
            flash("Todos los precios deben ser números mayores o iguales a cero.", "error")
            return volver("admin_funciones")
        try:
            with usar_db() as cur:
                cur.execute("SELECT duracion_min FROM pelicula WHERE pelicula_id = %s AND activa", (pelicula,))
                p = cur.fetchone()
                if not p:
                    raise ValueError("pelicula")
                cur.execute("SELECT zona_id FROM zona WHERE sala_id = %s ORDER BY zona_id", (sala,))
                zonas = [r["zona_id"] for r in cur.fetchall()]
                cur.execute("SELECT tipo_entrada_id FROM tipo_entrada ORDER BY tipo_entrada_id")
                tipos = [r["tipo_entrada_id"] for r in cur.fetchall()]
                if not zonas:
                    raise ValueError("zonas")
                faltan = [(z, t) for z in zonas for t in tipos if (z, t) not in precios]
                if faltan:
                    raise ValueError("precios")
                cur.execute("""INSERT INTO funcion (pelicula_id, sala_id, inicio, fin)
                               VALUES (%s, %s, %s::timestamptz,
                                       %s::timestamptz + make_interval(mins => %s))
                               RETURNING funcion_id""",
                            (pelicula, sala, inicio.strftime("%Y-%m-%d %H:%M"),
                             inicio.strftime("%Y-%m-%d %H:%M"), p["duracion_min"] + limpieza))
                funcion_id = cur.fetchone()["funcion_id"]
                for z in zonas:
                    for t in tipos:
                        cur.execute("""INSERT INTO tarifa (funcion_id, zona_id, tipo_entrada_id, precio)
                                       VALUES (%s, %s, %s, %s)""", (funcion_id, z, t, precios[(z, t)]))
        except ValueError as e:
            motivo = {"pelicula": "La película no existe o está desactivada.",
                      "zonas": "Esa sala no tiene zonas definidas.",
                      "precios": "Falta algún precio de la matriz (zona por tipo de entrada)."}
            flash(motivo.get(str(e), "Datos inválidos."), "error")
            return volver("admin_funciones")
        except psycopg2.Error as e:
            flash(error_amigable(e), "error")
            return volver("admin_funciones")
        flash(f"Función n.º {funcion_id} creada con su matriz de precios. Los asientos ya están disponibles para la venta.", "ok")
        return volver("admin_funciones")

    @app.post("/admin/funciones/<int:funcion_id>/cancelar")
    @solo_admin
    def admin_funcion_cancelar(funcion_id):
        mensaje, categoria = None, "ok"
        try:
            with usar_db() as cur:
                cur.execute("""SELECT count(*) AS n FROM boleto
                               WHERE funcion_id = %s AND estado IN ('reservado', 'valido')""", (funcion_id,))
                n = cur.fetchone()["n"]
                if n:
                    mensaje = (f"La función tiene {n} entradas vendidas o reservadas. "
                               "Reembólsalas primero (Operaciones) antes de cancelarla.")
                    categoria = "error"
                else:
                    cur.execute("UPDATE funcion SET activa = false WHERE funcion_id = %s", (funcion_id,))
                    mensaje = f"Función {funcion_id} cancelada."
        except psycopg2.Error as e:
            mensaje, categoria = error_amigable(e), "error"
        flash(mensaje, categoria)
        return volver("admin_funciones")

    # ------------------------------------------------------------ precios y promociones
    @app.route("/admin/precios")
    @solo_admin
    def admin_precios():
        fid = request.args.get("funcion", "").strip()
        info, tarifas = None, []
        with usar_db() as cur:
            cur.execute("""SELECT f.funcion_id, p.titulo, c.nombre AS cine, s.nombre AS sala, f.inicio
                           FROM funcion f
                           JOIN pelicula p ON p.pelicula_id = f.pelicula_id
                           JOIN sala s ON s.sala_id = f.sala_id
                           JOIN cine c ON c.cine_id = s.cine_id
                           WHERE f.activa AND f.inicio > now()
                           ORDER BY f.inicio, f.funcion_id LIMIT 10""")
            proximas = cur.fetchall()
            if fid.isdigit():
                cur.execute("""SELECT f.funcion_id, p.titulo, c.nombre AS cine, s.nombre AS sala, f.inicio
                               FROM funcion f
                               JOIN pelicula p ON p.pelicula_id = f.pelicula_id
                               JOIN sala s ON s.sala_id = f.sala_id
                               JOIN cine c ON c.cine_id = s.cine_id
                               WHERE f.funcion_id = %s""", (int(fid),))
                info = cur.fetchone()
                if info:
                    cur.execute("""SELECT t.tarifa_id, z.nombre AS zona, te.nombre AS tipo, t.precio
                                   FROM tarifa t
                                   JOIN zona z ON z.zona_id = t.zona_id
                                   JOIN tipo_entrada te ON te.tipo_entrada_id = t.tipo_entrada_id
                                   WHERE t.funcion_id = %s
                                   ORDER BY z.zona_id, te.tipo_entrada_id""", (int(fid),))
                    tarifas = cur.fetchall()
            cur.execute("""SELECT promocion_id, nombre, tipo, valor, dia_semana,
                                  vigente_desde, vigente_hasta, activa
                           FROM promocion ORDER BY promocion_id DESC LIMIT 30""")
            promos = cur.fetchall()
        return render_template("admin_precios.html", seccion="precios", proximas=proximas,
                               info=info, tarifas=tarifas, promos=promos, fid=fid)

    @app.post("/admin/precios/<int:tarifa_id>")
    @solo_admin
    def admin_precio_cambiar(tarifa_id):
        funcion = request.form.get("funcion", "")
        try:
            precio = decimal("precio")
            motivo = texto("motivo")
        except ValueError:
            flash("Indica un precio válido y el motivo del cambio (queda en la bitácora).", "error")
            return volver("admin_precios", funcion=funcion)
        try:
            with usar_db() as cur:
                cur.execute("SELECT fn_cambiar_tarifa(%s::bigint, %s::bigint, %s::numeric, %s::text) AS r",
                            (session["uid"], tarifa_id, precio, motivo))
                r = cur.fetchone()["r"]
            flash(r, resultado_fn(r))
        except psycopg2.Error as e:
            flash(error_amigable(e), "error")
        return volver("admin_precios", funcion=funcion)

    @app.post("/admin/promociones/crear")
    @solo_admin
    def admin_promo_crear():
        try:
            nombre = texto("nombre")
            tipo = texto("tipo")
            if tipo not in ("2x1", "porcentaje"):
                raise ValueError("tipo")
            valor = decimal("valor") if tipo == "porcentaje" else None
            dia = request.form.get("dia_semana", "").strip()
            dia = int(dia) if dia != "" else None
            desde = date.fromisoformat(request.form.get("vigente_desde", ""))
            hasta = date.fromisoformat(request.form.get("vigente_hasta", ""))
        except ValueError:
            flash("Revisa la promoción: nombre, tipo, valor (si es porcentaje) y fechas.", "error")
            return volver("admin_precios")
        try:
            with usar_db() as cur:
                cur.execute("""INSERT INTO promocion (nombre, tipo, valor, dia_semana, vigente_desde, vigente_hasta)
                               VALUES (%s, %s, %s, %s, %s, %s)""", (nombre, tipo, valor, dia, desde, hasta))
            flash("Promoción creada. Se aplica sola a las compras que cumplan el día y las fechas.", "ok")
        except psycopg2.Error as e:
            flash(error_amigable(e), "error")
        return volver("admin_precios")

    @app.post("/admin/promociones/<int:promocion_id>/activa")
    @solo_admin
    def admin_promo_activa(promocion_id):
        try:
            with usar_db() as cur:
                cur.execute("UPDATE promocion SET activa = NOT activa WHERE promocion_id = %s RETURNING activa",
                            (promocion_id,))
                fila = cur.fetchone()
            flash("Promoción " + ("activada." if fila and fila["activa"] else "desactivada."), "ok")
        except psycopg2.Error as e:
            flash(error_amigable(e), "error")
        return volver("admin_precios")

    # ------------------------------------------------------------ salas
    @app.route("/admin/salas")
    @solo_admin
    def admin_salas():
        cine = request.args.get("cine", "")
        with usar_db() as cur:
            cur.execute("SELECT cine_id, nombre, ciudad FROM cine ORDER BY nombre")
            cines = cur.fetchall()
            if not cine.isdigit() and cines:
                cine = str(cines[0]["cine_id"])
            salas = []
            if cine.isdigit():
                cur.execute("""
                    SELECT s.sala_id, s.nombre, s.capacidad, s.activa,
                           (SELECT count(*) FROM zona z WHERE z.sala_id = s.sala_id)     AS zonas,
                           (SELECT count(*) FROM asiento a WHERE a.sala_id = s.sala_id)  AS asientos,
                           EXISTS (SELECT 1 FROM boleto b
                                   JOIN funcion f ON f.funcion_id = b.funcion_id
                                   WHERE f.sala_id = s.sala_id AND f.activa AND f.fin > now()
                                     AND b.estado IN ('reservado', 'valido')) AS con_ventas
                    FROM sala s WHERE s.cine_id = %s ORDER BY s.nombre""", (int(cine),))
                salas = cur.fetchall()
        return render_template("admin_salas.html", seccion="salas", cines=cines, cine=cine, salas=salas)

    @app.post("/admin/salas/crear")
    @solo_admin
    def admin_sala_crear():
        try:
            cine = entero("cine_id")
            nombre = texto("nombre")
            filas = entero("filas", 1, 26)
            columnas = entero("columnas", 1, 40)
            zonas = []
            for i in (1, 2, 3):
                n = request.form.get(f"z{i}_nombre", "").strip()
                f = request.form.get(f"z{i}_filas", "").strip()
                if n or f:
                    zonas.append((n, int(f)))
            if not zonas or any(not n or f < 1 for n, f in zonas):
                raise ValueError("zonas")
            if sum(f for _, f in zonas) != filas:
                raise ValueError("suma")
            if len({n.lower() for n, _ in zonas}) != len(zonas):
                raise ValueError("repetidas")
        except ValueError as e:
            texto_error = {"suma": "Las filas de las zonas deben sumar exactamente el total de filas.",
                           "repetidas": "Los nombres de las zonas no se pueden repetir."}
            flash(texto_error.get(str(e), "Revisa los datos de la sala (filas 1 a 26, asientos por fila 1 a 40, "
                                          "y al menos una zona con nombre y filas)."), "error")
            return volver("admin_salas")
        try:
            with usar_db() as cur:
                cur.execute("""INSERT INTO sala (cine_id, nombre, capacidad) VALUES (%s, %s, %s)
                               RETURNING sala_id""", (cine, nombre, filas * columnas))
                sala_id = cur.fetchone()["sala_id"]
                fila_inicial = 1
                for nombre_zona, cantidad in zonas:
                    cur.execute("INSERT INTO zona (sala_id, nombre) VALUES (%s, %s) RETURNING zona_id",
                                (sala_id, nombre_zona))
                    zona_id = cur.fetchone()["zona_id"]
                    cur.execute("""INSERT INTO asiento (sala_id, zona_id, fila, numero)
                                   SELECT %s, %s, chr(64 + r), n
                                   FROM generate_series(%s, %s) AS r, generate_series(1, %s) AS n""",
                                (sala_id, zona_id, fila_inicial, fila_inicial + cantidad - 1, columnas))
                    fila_inicial += cantidad
        except psycopg2.Error as e:
            flash(error_amigable(e), "error")
            return volver("admin_salas", cine=cine)
        flash(f"Sala creada con {filas * columnas} asientos. Ya se pueden programar funciones en ella.", "ok")
        return volver("admin_salas", cine=cine)

    @app.post("/admin/salas/<int:sala_id>/activa")
    @solo_admin
    def admin_sala_activa(sala_id):
        cine = request.form.get("cine", "")
        try:
            with usar_db() as cur:
                cur.execute("UPDATE sala SET activa = NOT activa WHERE sala_id = %s RETURNING activa", (sala_id,))
                fila = cur.fetchone()
            flash("Sala " + ("activada." if fila and fila["activa"] else "desactivada."), "ok")
        except psycopg2.Error as e:
            flash(error_amigable(e), "error")
        return volver("admin_salas", cine=cine)

    @app.post("/admin/salas/<int:sala_id>/eliminar")
    @solo_admin
    def admin_sala_eliminar(sala_id):
        """Borra el mapa de la sala. Si tiene ventas, el trigger de RN-18 lo impide."""
        cine = request.form.get("cine", "")
        try:
            with usar_db() as cur:
                cur.execute("DELETE FROM asiento WHERE sala_id = %s", (sala_id,))
                cur.execute("DELETE FROM zona WHERE sala_id = %s", (sala_id,))
                cur.execute("DELETE FROM sala WHERE sala_id = %s", (sala_id,))
            flash("Sala eliminada.", "ok")
        except psycopg2.Error as e:
            if getattr(e, "pgcode", None) == "23503":
                flash("La sala tiene funciones registradas, por eso no se puede eliminar. Desactívala en su lugar.", "error")
            else:
                flash(error_amigable(e), "error")
        return volver("admin_salas", cine=cine)

    # ------------------------------------------------------------ operaciones manuales y bitacora
    @app.route("/admin/operaciones")
    @solo_admin
    def admin_operaciones():
        correo = request.args.get("correo", "").strip()
        with usar_db() as cur:
            cur.execute("SELECT tipo_entrada_id, nombre FROM tipo_entrada ORDER BY tipo_entrada_id")
            tipos = cur.fetchall()
            cur.execute("SELECT clave, valor FROM configuracion ORDER BY clave")
            config = cur.fetchall()
            boletos = []
            if correo:
                cur.execute("""
                    SELECT b.boleto_id, p.titulo, f.funcion_id, f.inicio, a.fila, a.numero,
                           b.estado, b.precio_final
                    FROM usuario u
                    JOIN compra c  ON c.usuario_id = u.usuario_id
                    JOIN boleto b  ON b.compra_id = c.compra_id
                    JOIN funcion f ON f.funcion_id = b.funcion_id
                    JOIN pelicula p ON p.pelicula_id = f.pelicula_id
                    JOIN asiento a ON a.asiento_id = b.asiento_id
                    WHERE lower(u.correo) = lower(%s)
                    ORDER BY b.boleto_id DESC LIMIT 15""", (correo,))
                boletos = cur.fetchall()
            cur.execute("""
                SELECT a.fecha, a.usuario_id, u.nombre || ' ' || u.apellido AS administrador,
                       a.accion, a.tabla_afectada, a.registro_id, host(a.ip) AS ip,
                       a.detalle ->> 'motivo' AS motivo
                FROM admin_operacion_audit a
                JOIN usuario u ON u.usuario_id = a.usuario_id
                ORDER BY a.fecha DESC LIMIT 30""")
            bitacora = cur.fetchall()
        return render_template("admin_operaciones.html", seccion="operaciones", tipos=tipos,
                               config=config, boletos=boletos, correo=correo, bitacora=bitacora)

    def ejecutar_operacion(accion):
        """Corre accion(cur) dentro de una transaccion y muestra el resultado."""
        try:
            with usar_db() as cur:
                r = accion(cur)
            flash(r, resultado_fn(r))
        except ValueError as e:
            flash(str(e) or "Datos inválidos.", "error")
        except psycopg2.Error as e:
            flash(error_amigable(e), "error")
        return volver("admin_operaciones")

    @app.post("/admin/operaciones/reembolso")
    @solo_admin
    def admin_op_reembolso():
        try:
            boleto = entero("boleto_id")
            motivo = texto("motivo")
        except ValueError:
            flash("Indica el número de boleto y el motivo.", "error")
            return volver("admin_operaciones")

        def accion(cur):
            cur.execute("SELECT fn_reembolsar_boleto(%s::bigint, %s::bigint, %s::text, true) AS r",
                        (boleto, session["uid"], motivo))
            return cur.fetchone()["r"]
        return ejecutar_operacion(accion)

    @app.post("/admin/operaciones/cambio-asiento")
    @solo_admin
    def admin_op_cambio_asiento():
        try:
            boleto = entero("boleto_id")
            fila = texto("fila").upper()
            numero = entero("numero", 1)
            motivo = texto("motivo")
        except ValueError:
            flash("Indica boleto, fila, número de asiento y motivo.", "error")
            return volver("admin_operaciones")

        def accion(cur):
            cur.execute("""SELECT a.asiento_id
                           FROM boleto b
                           JOIN funcion f ON f.funcion_id = b.funcion_id
                           JOIN asiento a ON a.sala_id = f.sala_id
                           WHERE b.boleto_id = %s AND upper(a.fila) = %s AND a.numero = %s""",
                        (boleto, fila, numero))
            a = cur.fetchone()
            if not a:
                raise ValueError("Ese asiento no existe en la sala del boleto (o el boleto no existe).")
            cur.execute("SELECT fn_cambiar_asiento(%s::bigint, %s::bigint, %s::bigint, %s::text) AS r",
                        (session["uid"], boleto, a["asiento_id"], motivo))
            return cur.fetchone()["r"]
        return ejecutar_operacion(accion)

    @app.post("/admin/operaciones/cortesia")
    @solo_admin
    def admin_op_cortesia():
        try:
            funcion = entero("funcion_id")
            fila = texto("fila").upper()
            numero = entero("numero", 1)
            correo = texto("correo")
            tipo = entero("tipo_entrada_id")
            motivo = texto("motivo")
        except ValueError:
            flash("Completa función, asiento, correo del destinatario, tipo de entrada y motivo.", "error")
            return volver("admin_operaciones")

        def accion(cur):
            cur.execute("""SELECT a.asiento_id
                           FROM funcion f JOIN asiento a ON a.sala_id = f.sala_id
                           WHERE f.funcion_id = %s AND upper(a.fila) = %s AND a.numero = %s""",
                        (funcion, fila, numero))
            a = cur.fetchone()
            if not a:
                raise ValueError("Ese asiento no existe en la sala de la función (o la función no existe).")
            cur.execute("SELECT usuario_id FROM usuario WHERE lower(correo) = lower(%s)", (correo,))
            u = cur.fetchone()
            if not u:
                raise ValueError("No existe un usuario con ese correo.")
            cur.execute("""SELECT fn_otorgar_cortesia(%s::bigint, %s::bigint, %s::bigint, %s::bigint,
                                                      %s::int, %s::text) AS r""",
                        (session["uid"], funcion, a["asiento_id"], u["usuario_id"], tipo, motivo))
            return cur.fetchone()["r"]
        return ejecutar_operacion(accion)

    @app.post("/admin/operaciones/configuracion")
    @solo_admin
    def admin_op_configuracion():
        try:
            clave = texto("clave")
            valor = texto("valor")
            motivo = texto("motivo")
        except ValueError:
            flash("Indica el nuevo valor y el motivo del cambio.", "error")
            return volver("admin_operaciones")

        def accion(cur):
            cur.execute("SELECT fn_cambiar_configuracion(%s::bigint, %s::varchar, %s::varchar, %s::text) AS r",
                        (session["uid"], clave, valor, motivo))
            return cur.fetchone()["r"]
        return ejecutar_operacion(accion)
