-- -------------------------------------------------------------------------------
-- 09_datos_prueba.sql  |  Proyecto 2: Licitacion IMAX 
-- Datos de prueba masivos para las consultas analiticas y EXPLAIN ANALYZE.
-- Requiere 01 a 05 (y 06 a 07b si se quieren probar vistas y roles).
-- Ejecutar con "Execute SQL Script" (Alt + X en DBeaver), conectado como
-- postgres, con la base imax activa. Tarda de 1 a 5 minutos.
--
-- Que crea (todo identificado como "Demo", no toca tus datos de prueba):
--   20 cines, 100 salas, 10.000 asientos, 30 peliculas, 2.020 usuarios,
--   4.500 funciones (10 dias atras hasta 4 dias adelante, 3 por dia y sala),
--   54.000 tarifas, aprox. 200.000 boletos con sus compras, pagos y logs.
--
-- El script va dentro de una transaccion: o se carga todo o no se carga nada.
-- Si aparece un error, ejecuta:  ROLLBACK;  y avisame.
-- Los datos son SINTeTICOS (generados al azar con semilla fija).
-- -------------------------------------------------------------------------------

BEGIN;

-- Evita cargar los datos dos veces
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM cine WHERE nombre LIKE 'IMAX Demo %') THEN
        RAISE EXCEPTION 'Los datos de prueba ya fueron cargados en esta base';
    END IF;
END $$;

-- Semilla para que el azar sea reproducible
SELECT setseed(0.42);

-- -------------------------------------------------------------------------------
-- 1. Catalogos: clasificaciones, generos, peliculas
-- -------------------------------------------------------------------------------
INSERT INTO clasificacion (codigo, edad_minima) VALUES
    ('G', 0), ('PG', 0), ('PG-13', 13), ('R', 17), ('NC-17', 18)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO genero (nombre) VALUES
    ('Accion'), ('Aventura'), ('Ciencia ficcion'), ('Comedia'),
    ('Drama'), ('Terror'), ('Animacion'), ('Documental')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO pelicula (titulo, sinopsis, duracion_min, clasificacion_id, poster_url, activa)
SELECT 'Pelicula Demo ' || lpad(n::TEXT, 2, '0'),
       'Sinopsis de la pelicula de demostracion numero ' || n || '.',
       (90 + (n * 7) % 70)::SMALLINT,
       (SELECT c.clasificacion_id
          FROM clasificacion c
         WHERE c.codigo = (ARRAY['G', 'PG', 'PG-13', 'R', 'NC-17'])[1 + n % 5]),
       NULL,
       TRUE
FROM generate_series(1, 30) AS n;

-- Cada pelicula tiene 1 o 2 generos
WITH g AS (
    SELECT genero_id, row_number() OVER (ORDER BY nombre) AS rn FROM genero
),
p AS (
    SELECT pelicula_id, substring(titulo FROM '[0-9]+$')::INT AS n
    FROM pelicula WHERE titulo LIKE 'Pelicula Demo %'
)
INSERT INTO pelicula_genero (pelicula_id, genero_id)
SELECT p.pelicula_id, g.genero_id FROM p JOIN g ON g.rn = 1 + p.n % 8
UNION
SELECT p.pelicula_id, g.genero_id FROM p JOIN g ON g.rn = 1 + (p.n + 3) % 8
WHERE p.n % 2 = 0;

-- -------------------------------------------------------------------------------
-- 2. Cines, salas, zonas y asientos
-- -------------------------------------------------------------------------------
INSERT INTO cine (nombre, pais, ciudad, direccion)
SELECT 'IMAX Demo ' || lpad(n::TEXT, 2, '0'),
       (ARRAY['Costa Rica', 'Estados Unidos', 'Mexico', 'España', 'Japon'])[1 + n % 5],
       (ARRAY['San Jose', 'Los angeles', 'Ciudad de Mexico', 'Madrid', 'Tokio'])[1 + n % 5],
       'Avenida Demo ' || n
FROM generate_series(1, 20) AS n;

INSERT INTO sala (cine_id, nombre, capacidad)
SELECT c.cine_id, 'Sala ' || s, 100
FROM cine c
CROSS JOIN generate_series(1, 5) AS s
WHERE c.nombre LIKE 'IMAX Demo %';

INSERT INTO zona (sala_id, nombre)
SELECT s.sala_id, z.nombre
FROM sala s
JOIN cine c ON c.cine_id = s.cine_id AND c.nombre LIKE 'IMAX Demo %'
CROSS JOIN (VALUES ('platea'), ('palco'), ('vip')) AS z(nombre);

-- 10 filas (A a J) por 10 asientos: A-E platea, F-H palco, I-J vip
INSERT INTO asiento (sala_id, zona_id, fila, numero)
SELECT s.sala_id, z.zona_id, chr(64 + f), n
FROM sala s
JOIN cine c ON c.cine_id = s.cine_id AND c.nombre LIKE 'IMAX Demo %'
CROSS JOIN generate_series(1, 10) AS f
CROSS JOIN generate_series(1, 10) AS n
JOIN zona z ON z.sala_id = s.sala_id
           AND z.nombre = CASE WHEN f <= 5 THEN 'platea'
                               WHEN f <= 8 THEN 'palco'
                               ELSE 'vip' END;

-- -------------------------------------------------------------------------------
-- 3. Usuarios (las contraseñas son marcadores de posicion, no reales)
-- -------------------------------------------------------------------------------
INSERT INTO usuario (rol_id, nombre, apellido, correo, password_hash)
SELECT r.rol_id,
       initcap(replace(r.nombre, '_', ' ')),
       'Demo ' || n,
       r.nombre || n || '@demo.imax',
       'hash_demo'
FROM rol r
JOIN (VALUES ('cliente', 2000), ('taquillero', 10), ('operador_sala', 5),
             ('contador', 2), ('administrador', 3)) AS q(rol, cantidad)
  ON q.rol = r.nombre
CROSS JOIN LATERAL generate_series(1, q.cantidad) AS n;

-- -------------------------------------------------------------------------------
-- 4. Funciones: 15 dias x 3 horarios x 100 salas
--    (el trigger crea solo el estado 'disponible' de cada asiento)
-- -------------------------------------------------------------------------------
INSERT INTO funcion (pelicula_id, sala_id, inicio, fin)
SELECT pel.pelicula_id,
       s.sala_id,
       date_trunc('day', now()) + g.d * interval '1 day' + h.hora,
       date_trunc('day', now()) + g.d * interval '1 day' + h.hora + interval '2 hours 30 minutes'
FROM sala s
JOIN cine c ON c.cine_id = s.cine_id AND c.nombre LIKE 'IMAX Demo %'
CROSS JOIN generate_series(-10, 4) AS g(d)
CROSS JOIN (VALUES (0, interval '12 hours'),
                   (1, interval '15 hours 30 minutes'),
                   (2, interval '19 hours')) AS h(idx, hora)
JOIN (SELECT pelicula_id, row_number() OVER (ORDER BY pelicula_id) - 1 AS k
        FROM pelicula WHERE titulo LIKE 'Pelicula Demo %') pel
  ON pel.k = (s.sala_id * 7 + g.d + 10 + h.idx * 11) % 30;

-- Tarifas: precio por zona x tipo de entrada, para cada funcion demo
INSERT INTO tarifa (funcion_id, zona_id, tipo_entrada_id, precio)
SELECT f.funcion_id, z.zona_id, t.tipo_entrada_id,
       round(
           (CASE z.nombre WHEN 'platea' THEN 5000 WHEN 'palco' THEN 7000 ELSE 9000 END)
         * (CASE t.nombre WHEN 'adulto' THEN 1.0 WHEN 'nino' THEN 0.6
                          WHEN 'tercera_edad' THEN 0.7 ELSE 0.8 END), 2)
FROM funcion f
JOIN sala s ON s.sala_id = f.sala_id
JOIN cine c ON c.cine_id = s.cine_id AND c.nombre LIKE 'IMAX Demo %'
JOIN zona z ON z.sala_id = s.sala_id
CROSS JOIN tipo_entrada t;

-- -------------------------------------------------------------------------------
-- 5. Ventas: aprox. 45% de los asientos se venden, en compras de hasta 3
-- -------------------------------------------------------------------------------
CREATE TEMP TABLE tmp_cli AS
SELECT row_number() OVER (ORDER BY usuario_id) AS rn, usuario_id
FROM usuario WHERE correo LIKE 'cliente%@demo.imax';

CREATE TEMP TABLE tmp_tq AS
SELECT row_number() OVER (ORDER BY usuario_id) AS rn, usuario_id
FROM usuario WHERE correo LIKE 'taquillero%@demo.imax';

CREATE TEMP TABLE tmp_venta AS
SELECT v.funcion_id,
       v.asiento_id,
       ((row_number() OVER (PARTITION BY v.funcion_id ORDER BY v.asiento_id) - 1) / 3)::INT AS grupo,
       v.r_tipo
FROM (
    SELECT fa.funcion_id, fa.asiento_id, random() AS r_tipo
    FROM funcion_asiento fa
    JOIN funcion f ON f.funcion_id = fa.funcion_id
    JOIN sala s    ON s.sala_id = f.sala_id
    JOIN cine c    ON c.cine_id = s.cine_id AND c.nombre LIKE 'IMAX Demo %'
    WHERE random() < 0.45
) v;

CREATE TEMP TABLE tmp_compra AS
SELECT (SELECT COALESCE(max(compra_id), 0) FROM compra)
         + row_number() OVER (ORDER BY g.funcion_id, g.grupo) AS compra_id,
       g.funcion_id,
       g.grupo,
       1 + floor(random() * 2000)::INT AS cli_rn,
       1 + floor(random() * 10)::INT   AS tq_rn,
       random() AS r_canal,
       random() AS r_met,
       random() AS r_dias
FROM (SELECT DISTINCT funcion_id, grupo FROM tmp_venta) g;

CREATE TEMP TABLE tmp_boleto AS
SELECT tc.compra_id, v.funcion_id, v.asiento_id, te.tipo_entrada_id, t.precio
FROM tmp_venta v
JOIN tmp_compra tc ON tc.funcion_id = v.funcion_id AND tc.grupo = v.grupo
JOIN asiento a     ON a.asiento_id = v.asiento_id
JOIN tipo_entrada te
  ON te.nombre = CASE WHEN v.r_tipo < 0.60 THEN 'adulto'
                      WHEN v.r_tipo < 0.75 THEN 'nino'
                      WHEN v.r_tipo < 0.85 THEN 'tercera_edad'
                      ELSE 'estudiante' END
JOIN tarifa t
  ON t.funcion_id = v.funcion_id
 AND t.zona_id = a.zona_id
 AND t.tipo_entrada_id = te.tipo_entrada_id;

-- Compras (15% de taquilla, 85% online), con fecha anterior al inicio de la funcion
INSERT INTO compra (compra_id, usuario_id, vendedor_id, canal, estado,
                    subtotal, descuento, cargo_servicio, total, fecha_creacion)
OVERRIDING SYSTEM VALUE
SELECT tc.compra_id,
       cli.usuario_id,
       CASE WHEN tc.r_canal < 0.15 THEN tq.usuario_id END,
       CASE WHEN tc.r_canal < 0.15 THEN 'taquilla' ELSE 'online' END,
       'pagada',
       sb.subtotal, 0, 0, sb.subtotal,
       least(now(), f.inicio) - tc.r_dias * interval '7 days'
FROM tmp_compra tc
JOIN tmp_cli cli ON cli.rn = tc.cli_rn
JOIN tmp_tq tq   ON tq.rn = tc.tq_rn
JOIN funcion f   ON f.funcion_id = tc.funcion_id
JOIN (SELECT compra_id, sum(precio) AS subtotal
        FROM tmp_boleto GROUP BY compra_id) sb ON sb.compra_id = tc.compra_id;

-- Se avanza la secuencia para que las proximas compras reales no choquen
SELECT setval(pg_get_serial_sequence('compra', 'compra_id'),
              (SELECT max(compra_id) FROM compra));

-- Pagos aprobados (50% tarjeta, 20% PayPal, 20% billetera, 10% transferencia)
INSERT INTO pago (compra_id, metodo_pago_id, monto, estado, referencia_pasarela, fecha)
SELECT tc.compra_id, mp.metodo_pago_id, c.total, 'aprobado',
       'SIM-' || tc.compra_id, c.fecha_creacion + interval '1 minute'
FROM tmp_compra tc
JOIN compra c ON c.compra_id = tc.compra_id
JOIN metodo_pago mp
  ON mp.nombre = CASE WHEN tc.r_met < 0.50 THEN 'tarjeta'
                      WHEN tc.r_met < 0.70 THEN 'paypal'
                      WHEN tc.r_met < 0.90 THEN 'billetera_digital'
                      ELSE 'transferencia' END;

-- Boletos: 'usado' si la funcion ya empezo, 'valido' si todavia no
INSERT INTO boleto (compra_id, funcion_id, asiento_id, tipo_entrada_id, precio_final,
                    codigo_qr, estado, fecha_emision, fecha_uso)
SELECT tb.compra_id, tb.funcion_id, tb.asiento_id, tb.tipo_entrada_id, tb.precio,
       gen_random_uuid(),
       CASE WHEN f.inicio < now() THEN 'usado' ELSE 'valido' END,
       c.fecha_creacion + interval '1 minute',
       CASE WHEN f.inicio < now() THEN f.inicio - interval '10 minutes' END
FROM tmp_boleto tb
JOIN funcion f ON f.funcion_id = tb.funcion_id
JOIN compra c  ON c.compra_id = tb.compra_id;

-- Los asientos vendidos quedan marcados como tales
UPDATE funcion_asiento fa
   SET estado = 'vendido'
  FROM tmp_venta v
 WHERE fa.funcion_id = v.funcion_id
   AND fa.asiento_id = v.asiento_id;

-- -------------------------------------------------------------------------------
-- 6. Logs de auditoria (alimentan el calculo de almacenamiento a 5 años)
-- -------------------------------------------------------------------------------
INSERT INTO asiento_auditoria_log (funcion_id, asiento_id, usuario_id, evento, fecha)
SELECT tb.funcion_id, tb.asiento_id, c.usuario_id, 'bloqueado',
       c.fecha_creacion - interval '1 minute'
FROM tmp_boleto tb JOIN compra c ON c.compra_id = tb.compra_id
UNION ALL
SELECT tb.funcion_id, tb.asiento_id, c.usuario_id, 'vendido',
       c.fecha_creacion + interval '1 minute'
FROM tmp_boleto tb JOIN compra c ON c.compra_id = tb.compra_id;

INSERT INTO transaccion_log (compra_id, pago_id, evento, monto, resultado, fecha)
SELECT c.compra_id, p.pago_id, e.evento, c.total, e.resultado, c.fecha_creacion + e.desfase
FROM tmp_compra tc
JOIN compra c ON c.compra_id = tc.compra_id
JOIN pago p   ON p.compra_id = c.compra_id
CROSS JOIN (VALUES ('compra_creada', 'pendiente', interval '0 minutes'),
                   ('pago_aprobado', 'aprobado',  interval '1 minute'),
                   ('boleto_emitido', 'emitido',  interval '1 minute')) AS e(evento, resultado, desfase);

INSERT INTO acceso_puerta_log (boleto_id, codigo_qr, puerta, resultado, fecha)
SELECT b.boleto_id, b.codigo_qr, 'Puerta ' || (1 + b.boleto_id % 3), 'exitoso', b.fecha_uso
FROM boleto b
WHERE b.estado = 'usado'
  AND b.compra_id IN (SELECT compra_id FROM tmp_compra);

-- 60 operaciones administrativas de ejemplo (sinteticas, para la consulta de auditoria)
CREATE TEMP TABLE tmp_adm AS
SELECT row_number() OVER (ORDER BY usuario_id) AS rn, usuario_id, rol_id
FROM usuario WHERE correo LIKE 'administrador%@demo.imax';

INSERT INTO admin_operacion_audit (usuario_id, rol_id, ip, accion, tabla_afectada,
                                   registro_id, detalle, fecha)
SELECT a.usuario_id, a.rol_id,
       ('192.168.0.' || (10 + n % 20))::INET,
       (ARRAY['cortesia', 'cambio_asiento', 'reembolso_forzado',
              'cambio_precio', 'cambio_configuracion'])[1 + n % 5],
       (ARRAY['boleto', 'boleto', 'boleto', 'tarifa', 'configuracion'])[1 + n % 5],
       n::TEXT,
       jsonb_build_object('motivo', 'Operacion de demostracion ' || n),
       now() - (n % 25) * interval '1 day' - (n % 24) * interval '1 hour'
FROM generate_series(1, 60) AS n
JOIN tmp_adm a ON a.rn = 1 + n % 3;

DROP TABLE tmp_cli, tmp_tq, tmp_venta, tmp_compra, tmp_boleto, tmp_adm;

COMMIT;

-- Estadisticas actualizadas: necesarias para que EXPLAIN ANALYZE sea representativo
ANALYZE;

-- Resumen de lo cargado
SELECT 'cines' AS tabla, count(*) AS filas FROM cine
UNION ALL SELECT 'salas', count(*) FROM sala
UNION ALL SELECT 'asientos', count(*) FROM asiento
UNION ALL SELECT 'peliculas', count(*) FROM pelicula
UNION ALL SELECT 'usuarios', count(*) FROM usuario
UNION ALL SELECT 'funciones', count(*) FROM funcion
UNION ALL SELECT 'funcion_asiento', count(*) FROM funcion_asiento
UNION ALL SELECT 'tarifas', count(*) FROM tarifa
UNION ALL SELECT 'compras', count(*) FROM compra
UNION ALL SELECT 'pagos', count(*) FROM pago
UNION ALL SELECT 'boletos', count(*) FROM boleto
UNION ALL SELECT 'transaccion_log', count(*) FROM transaccion_log
UNION ALL SELECT 'asiento_auditoria_log', count(*) FROM asiento_auditoria_log
UNION ALL SELECT 'acceso_puerta_log', count(*) FROM acceso_puerta_log
UNION ALL SELECT 'admin_operacion_audit', count(*) FROM admin_operacion_audit;
