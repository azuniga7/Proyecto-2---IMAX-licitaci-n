
import threading
import time
from datetime import datetime

import psycopg2

# ---- CONFIGURACION: cambia la contrasena por la de tu postgres ----
CONFIG = dict(host="localhost", port=5432, dbname="imax",
              user="postgres", password="postgres")
N_HILOS = 30          # el enunciado pide entre 20 y 50
ARCHIVO_SALIDA = "resultado_concurrencia.txt"

lineas = []


def log(texto=""):
    print(texto)
    lineas.append(texto)


def conectar():
    return psycopg2.connect(**CONFIG)


def primera_linea(error):
    return str(error).strip().splitlines()[0]


def lanzar_hilos(trabajo, usuarios, **datos):
    """Abre N conexiones, las deja listas y las suelta todas al mismo tiempo."""
    barrera = threading.Barrier(len(usuarios))
    resultados = [None] * len(usuarios)
    hilos = [
        threading.Thread(target=trabajo, args=(i, u, barrera, resultados), kwargs=datos)
        for i, u in enumerate(usuarios)
    ]
    for h in hilos:
        h.start()
    for h in hilos:
        h.join()
    return resultados


def resumen(resultados):
    exitos = [r for r in resultados if r and r[0] == "EXITO"]
    rechazos = [r for r in resultados if r and r[0] == "RECHAZADO"]
    for i, r in enumerate(resultados, start=1):
        log(f"  hilo {i:02d} | usuario {r[1]:>6} | {r[0]:<9} | {r[2]*1000:7.1f} ms | {r[3]}")
    log(f"  Exitosos: {len(exitos)}   Rechazados: {len(rechazos)}")
    return len(exitos), len(rechazos)


# ---------------------------------------------------------------- prueba 1
def intento_bloqueo(i, usuario, barrera, resultados, funcion, asiento):
    con = conectar()
    cur = con.cursor()
    t0 = time.perf_counter()
    try:
        barrera.wait(timeout=60)
        t0 = time.perf_counter()
        cur.execute("SELECT fn_bloquear_asiento(%s, %s, %s)", (funcion, asiento, usuario))
        con.commit()
        resultados[i] = ("EXITO", usuario, time.perf_counter() - t0, "asiento bloqueado")
    except Exception as e:
        con.rollback()
        resultados[i] = ("RECHAZADO", usuario, time.perf_counter() - t0, primera_linea(e))
    finally:
        con.close()


# ---------------------------------------------------------------- prueba 2
def intento_boleto(i, usuario, barrera, resultados, funcion, asiento, compra):
    con = conectar()
    cur = con.cursor()
    t0 = time.perf_counter()
    try:
        barrera.wait(timeout=60)
        t0 = time.perf_counter()
        cur.execute(
            "INSERT INTO boleto (compra_id, funcion_id, asiento_id, tipo_entrada_id, precio_final) "
            "VALUES (%s, %s, %s, 1, 0)", (compra, funcion, asiento))
        con.commit()
        resultados[i] = ("EXITO", usuario, time.perf_counter() - t0, "boleto insertado")
    except Exception as e:
        con.rollback()
        resultados[i] = ("RECHAZADO", usuario, time.perf_counter() - t0, primera_linea(e))
    finally:
        con.close()


def main():
    inicio = datetime.now()
    log(f"PRUEBA DE CONCURRENCIA - {inicio:%Y-%m-%d %H:%M:%S} - {N_HILOS} solicitudes simultaneas")

    con = conectar()
    cur = con.cursor()

    # Dos asientos libres de una funcion futura (uno por prueba)
    cur.execute("""
        SELECT fa.funcion_id, fa.asiento_id
        FROM funcion_asiento fa
        JOIN funcion f ON f.funcion_id = fa.funcion_id
        WHERE fa.estado = 'disponible' AND f.activa AND f.inicio > now() + interval '1 day'
        ORDER BY fa.funcion_id, fa.asiento_id
        LIMIT 2""")
    asientos = cur.fetchall()
    if len(asientos) < 2:
        raise SystemExit("No hay asientos disponibles en funciones futuras. Carga los datos de prueba.")
    (f1, a1), (f2, a2) = asientos

    # N clientes distintos
    cur.execute("""
        SELECT usuario_id FROM usuario
        WHERE rol_id = (SELECT rol_id FROM rol WHERE nombre = 'cliente')
        ORDER BY usuario_id LIMIT %s""", (N_HILOS,))
    usuarios = [r[0] for r in cur.fetchall()]
    if len(usuarios) < N_HILOS:
        raise SystemExit("No hay suficientes clientes en la base.")

    # ------------------------- PRUEBA 1 -------------------------
    log("")
    log(f"PRUEBA 1: {N_HILOS} clientes bloquean el asiento {a1} de la funcion {f1} (fn_bloquear_asiento)")
    resultados = lanzar_hilos(intento_bloqueo, usuarios, funcion=f1, asiento=a1)
    exitos1, _ = resumen(resultados)

    cur.execute("SELECT estado, bloqueado_por FROM funcion_asiento WHERE funcion_id=%s AND asiento_id=%s",
                (f1, a1))
    estado, dueno = cur.fetchone()
    cur.execute("""SELECT count(*) FROM asiento_auditoria_log
                   WHERE funcion_id=%s AND asiento_id=%s AND evento='bloqueado' AND fecha >= %s""",
                (f1, a1, inicio))
    filas_log = cur.fetchone()[0]
    log(f"  Estado final del asiento: {estado}, bloqueado por el usuario {dueno}")
    log(f"  Filas 'bloqueado' en asiento_auditoria_log durante la prueba: {filas_log}")
    ok1 = exitos1 == 1 and estado == "bloqueado" and filas_log == 1
    log("  RESULTADO PRUEBA 1: " + ("APROBADA" if ok1 else "FALLO"))

    # ------------------------- PRUEBA 2 -------------------------
    log("")
    log(f"PRUEBA 2: {N_HILOS} inserciones del mismo boleto (funcion {f2}, asiento {a2})")
    cur.execute("INSERT INTO compra (usuario_id, canal) VALUES (%s, 'online') RETURNING compra_id",
                (usuarios[0],))
    compra = cur.fetchone()[0]
    con.commit()
    resultados = lanzar_hilos(intento_boleto, usuarios, funcion=f2, asiento=a2, compra=compra)
    exitos2, _ = resumen(resultados)

    cur.execute("SELECT count(*) FROM boleto WHERE funcion_id=%s AND asiento_id=%s AND estado <> 'anulado'",
                (f2, a2))
    boletos = cur.fetchone()[0]
    log(f"  Boletos activos para ese asiento y funcion: {boletos}")
    ok2 = exitos2 == 1 and boletos == 1
    log("  RESULTADO PRUEBA 2: " + ("APROBADA" if ok2 else "FALLO"))

    # ------------------------- LIMPIEZA -------------------------
    cur.execute("DELETE FROM boleto WHERE compra_id = %s", (compra,))
    cur.execute("DELETE FROM compra WHERE compra_id = %s", (compra,))
    cur.execute("""UPDATE funcion_asiento SET estado='disponible', bloqueado_por=NULL, bloqueado_hasta=NULL
                   WHERE funcion_id=%s AND asiento_id=%s""", (f1, a1))
    con.commit()
    con.close()
    log("")
    log("Limpieza hecha: el asiento y la compra de prueba quedaron como antes "
        "(las bitacoras no se borran, por la regla RN-20).")

    with open(ARCHIVO_SALIDA, "w", encoding="utf-8") as f:
        f.write("\n".join(lineas) + "\n")
    print(f"Resultado guardado en {ARCHIVO_SALIDA}")


if __name__ == "__main__":
    main()
