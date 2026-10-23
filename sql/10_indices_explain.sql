---------------------------------------------------------------------------
-- 10_indices_explain.sql  |  Proyecto 2: Licitacion IMAX
-- Indices estrategicos y comparacion de EXPLAIN ANALYZE ANTES y DESPUES.
--
-- Requiere 01 a 08 y los datos masivos de 09_datos_prueba.sql.
-- Con pocos datos PostgreSQL prefiere leer la tabla completa (Seq Scan) y los
-- indices no se notan. Se corre por pasos, ejecutando solo lo que dice cada paso
-- (selecciona el texto y dale a ejecutar). Toma captura de cada resultado.
-- Los ids se eligen solos con una subconsulta; en el plan aparece como
-- "InitPlan", es normal.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- PASO 0. Dejar la base sin los indices de este script (para poder repetir
-- la prueba) y actualizar las estadisticas del optimizador.
---------------------------------------------------------------------------
DROP INDEX IF EXISTS idx_boleto_compra;
DROP INDEX IF EXISTS idx_compra_usuario;
DROP INDEX IF EXISTS idx_boleto_emision_vendidos;
DROP INDEX IF EXISTS idx_funcion_asiento_bloqueados;
DROP INDEX IF EXISTS idx_funcion_inicio_activa;
ANALYZE;

---------------------------------------------------------------------------
-- PASO 0b (opcional). Los datos masivos no traen asientos bloqueados. Esto
-- deja unos cuantos con el bloqueo vencido para que la consulta 1.4 tenga
-- algo que encontrar. Ejecutalo una sola vez, antes del PASO 1.
---------------------------------------------------------------------------
UPDATE funcion_asiento
   SET estado = 'bloqueado',
       bloqueado_por = (SELECT usuario_id FROM usuario WHERE correo = 'cliente1@demo.imax'),
       bloqueado_hasta = now() - interval '5 minutes'
 WHERE estado = 'disponible' AND random() < 0.002;

---------------------------------------------------------------------------
-- PASO 1. ANTES. Ejecuta cada consulta por separado y guarda el plan.
-- Fijate en el tipo de scan (Seq Scan / Index Scan), "Execution Time" y
-- "Buffers".
---------------------------------------------------------------------------

-- 1.1 Boletos de una compra (la usan el pago y la anulacion de compras)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM boleto
WHERE compra_id = (SELECT compra_id FROM compra ORDER BY compra_id OFFSET 30000 LIMIT 1);

-- 1.2 "Mis boletos" de un cliente (pantalla de entrada digital)
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM v_mis_boletos
WHERE usuario_id = (SELECT usuario_id FROM compra
                    WHERE usuario_id IS NOT NULL ORDER BY compra_id OFFSET 30000 LIMIT 1);

-- 1.3 Top 5 de peliculas de la ultima semana (consulta analitica 2)
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.pelicula_id, p.titulo, count(*) AS boletos_vendidos
FROM boleto b
JOIN funcion  f ON f.funcion_id  = b.funcion_id
JOIN pelicula p ON p.pelicula_id = f.pelicula_id
WHERE b.estado IN ('valido', 'usado')
  AND b.fecha_emision >= now() - interval '7 days'
GROUP BY p.pelicula_id, p.titulo
ORDER BY boletos_vendidos DESC, p.titulo
LIMIT 5;

-- 1.4 Bloqueos de asiento vencidos (lo que revisa fn_liberar_bloqueos_expirados)
EXPLAIN (ANALYZE, BUFFERS)
SELECT funcion_id, asiento_id, bloqueado_por
FROM funcion_asiento
WHERE estado = 'bloqueado' AND bloqueado_hasta <= now();

-- 1.5 Cartelera de un dia (filtrado por fecha)
EXPLAIN (ANALYZE, BUFFERS)
SELECT funcion_id, titulo, cine, inicio
FROM v_cartelera
WHERE inicio >= current_date + 1 AND inicio < current_date + 2;

---------------------------------------------------------------------------
-- PASO 2. Crear los indices (ejecuta este bloque completo)
---------------------------------------------------------------------------

-- Las llaves foraneas no crean indice solas en PostgreSQL.
-- boleto.compra_id: buscar los boletos de una compra
CREATE INDEX idx_boleto_compra ON boleto (compra_id);

-- compra.usuario_id: buscar las compras de un cliente
CREATE INDEX idx_compra_usuario ON compra (usuario_id);

-- Parcial y "cubriente": solo boletos validos o usados, ordenados por fecha de
-- emision e incluyendo funcion_id, para que el top semanal se resuelva con un
-- Index Only Scan sin leer la tabla.
CREATE INDEX idx_boleto_emision_vendidos
    ON boleto (fecha_emision) INCLUDE (funcion_id)
    WHERE estado IN ('valido', 'usado');

-- Parcial: solo los asientos bloqueados (una fraccion minima de la tabla).
CREATE INDEX idx_funcion_asiento_bloqueados
    ON funcion_asiento (bloqueado_hasta)
    WHERE estado = 'bloqueado';

-- Parcial: solo funciones activas, para filtrar la cartelera por fecha.
CREATE INDEX idx_funcion_inicio_activa
    ON funcion (inicio)
    WHERE activa;

---------------------------------------------------------------------------
-- PASO 3. Actualizar estadisticas.
-- Ejecuta cada linea POR SEPARADO (VACUUM no corre dentro de un bloque con
-- otras sentencias). El VACUUM de boleto hace que el Index Only Scan funcione.
---------------------------------------------------------------------------
ANALYZE;

VACUUM (ANALYZE) boleto;

---------------------------------------------------------------------------
-- PASO 4. DESPUES. Vuelve a ejecutar las 5 consultas del PASO 1, una por una,
-- y compara con las capturas de antes: tipo de scan, Execution Time, Buffers.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- NOTAS PARA EL DOCUMENTO
--
-- Consultas que NO necesitan indice nuevo (ya usan Index Scan por las llaves
-- que define el DDL). Sirven para mostrar que el diseno ya las cubre:
--
-- a) Disponibilidad de asientos de una funcion: usa funcion_asiento_pkey
--    (funcion_id, asiento_id).
EXPLAIN (ANALYZE, BUFFERS)
SELECT asiento_id, zona, fila, numero
FROM v_mapa_asientos
WHERE funcion_id = (SELECT funcion_id FROM funcion ORDER BY funcion_id OFFSET 2000 LIMIT 1)
  AND estado = 'disponible';

-- b) Validacion de un QR en la puerta: usa boleto_codigo_qr_key (UNIQUE).
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM boleto WHERE codigo_qr = (SELECT codigo_qr FROM boleto LIMIT 1);

-- c) Ocupacion y recaudacion de una funcion (consulta analitica 1):
--    usa funcion_asiento_pkey y uq_boleto_asiento_activo.
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM v_ocupacion_funcion
WHERE funcion_id = (SELECT funcion_id FROM funcion ORDER BY funcion_id OFFSET 2000 LIMIT 1);

-- d) Auditoria del ultimo mes (consulta analitica 4): el particionamiento por
--    fecha hace que PostgreSQL solo lea la particion del anio que corresponde
--    (en el plan, las particiones de otros anios aparecen como "never executed"
--    o no aparecen).
EXPLAIN (ANALYZE, BUFFERS)
SELECT usuario_id, accion, count(*)
FROM admin_operacion_audit
WHERE fecha >= now() - interval '1 month' AND fecha <= now()
GROUP BY usuario_id, accion;

-- Consulta que NO mejora con un indice: metodos de pago (consulta analitica 3).
-- Recorre todos los pagos aprobados para contarlos; en las pruebas el indice
-- no cambio el plan ni el tiempo, asi que no se crea.
