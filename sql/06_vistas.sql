-- 06_vistas.sql  |  Proyecto 2: Licitacion IMAX


-- Cartelera (RN-01, RN-02)
-- Solo funciones activas, de peliculas y salas activas, con inicio futuro.
-- Cada fila es una funcion.

CREATE OR REPLACE VIEW v_cartelera AS
SELECT f.funcion_id,
       p.pelicula_id,
       p.titulo,
       p.sinopsis,
       p.duracion_min,
       cl.codigo      AS clasificacion,
       cl.edad_minima,
       p.poster_url,
       g.generos,
       array_to_string(g.generos, ', ') AS generos_texto,
       c.cine_id,
       c.nombre       AS cine,
       c.pais,
       c.ciudad,
       c.direccion,
       s.sala_id,
       s.nombre       AS sala,
       f.inicio,
       f.fin
FROM funcion f
JOIN pelicula p       ON p.pelicula_id = f.pelicula_id
JOIN clasificacion cl ON cl.clasificacion_id = p.clasificacion_id
JOIN sala s           ON s.sala_id = f.sala_id
JOIN cine c           ON c.cine_id = s.cine_id
LEFT JOIN LATERAL (
    SELECT array_agg(ge.nombre ORDER BY ge.nombre) AS generos
    FROM pelicula_genero pg
    JOIN genero ge ON ge.genero_id = pg.genero_id
    WHERE pg.pelicula_id = p.pelicula_id
) g ON TRUE
WHERE f.activa
  AND p.activa
  AND s.activa
  AND f.inicio > now();
 
---------------------------------------------------------------------------
-- Mapa de asientos de una funcion (RN-03)
-- Estados para el mapa: 'disponible', 'ocupado' y 'bloqueado'.
-- Un bloqueo que ya vencio se muestra como disponible aunque la fila
-- todavia no haya sido liberada por fn_liberar_bloqueos_expirados.
-- bloqueado_por permite a la interfaz pintar en azul los asientos del propio
-- usuario y en amarillo los de otros. Uso:
--   SELECT * FROM v_mapa_asientos WHERE funcion_id = 1 ORDER BY fila, numero;
---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_mapa_asientos AS
SELECT fa.funcion_id,
       a.asiento_id,
       z.nombre AS zona,
       a.fila,
       a.numero,
       CASE
           WHEN fa.estado = 'vendido' THEN 'ocupado'
           WHEN fa.estado = 'bloqueado' AND fa.bloqueado_hasta > now() THEN 'bloqueado'
           ELSE 'disponible'
       END AS estado,
       CASE WHEN fa.estado = 'bloqueado' AND fa.bloqueado_hasta > now()
            THEN fa.bloqueado_por END AS bloqueado_por,
       CASE WHEN fa.estado = 'bloqueado' AND fa.bloqueado_hasta > now()
            THEN fa.bloqueado_hasta END AS bloqueado_hasta
FROM funcion_asiento fa
JOIN asiento a ON a.asiento_id = fa.asiento_id
JOIN zona z    ON z.zona_id = a.zona_id;
 

-- Mis boletos (RN-13): boletos con QR de un cliente. Uso:
--   SELECT * FROM v_mis_boletos WHERE usuario_id = 3 ORDER BY inicio;
-- Solo aparecen boletos validos o usados (los unicos que tienen QR, RN-11).

CREATE OR REPLACE VIEW v_mis_boletos AS
SELECT c.usuario_id,
       b.boleto_id,
       b.compra_id,
       p.titulo,
       ci.nombre AS cine,
       s.nombre  AS sala,
       f.inicio,
       z.nombre  AS zona,
       a.fila,
       a.numero,
       te.nombre AS tipo_entrada,
       b.precio_final,
       b.estado,
       b.codigo_qr,
       b.fecha_emision
FROM boleto b
JOIN compra c        ON c.compra_id = b.compra_id
JOIN funcion f       ON f.funcion_id = b.funcion_id
JOIN pelicula p      ON p.pelicula_id = f.pelicula_id
JOIN sala s          ON s.sala_id = f.sala_id
JOIN cine ci         ON ci.cine_id = s.cine_id
JOIN asiento a       ON a.asiento_id = b.asiento_id
JOIN zona z          ON z.zona_id = a.zona_id
JOIN tipo_entrada te ON te.tipo_entrada_id = b.tipo_entrada_id
WHERE b.estado IN ('valido', 'usado');
 

-- Corte de caja del taquillero: ventas presenciales pagadas por dia y metodo
-- de pago. Uso:  SELECT * FROM v_corte_caja WHERE vendedor_id = 2;

CREATE OR REPLACE VIEW v_corte_caja AS
SELECT c.vendedor_id,
       pa.fecha::date    AS dia,
       mp.nombre         AS metodo_pago,
       count(*)          AS compras,
       sum(pa.monto)     AS total
FROM compra c
JOIN pago pa ON pa.compra_id = c.compra_id AND pa.estado = 'aprobado'
JOIN metodo_pago mp ON mp.metodo_pago_id = pa.metodo_pago_id
WHERE c.canal = 'taquilla'
  AND c.estado = 'pagada'
GROUP BY c.vendedor_id, pa.fecha::date, mp.nombre;
 

-- Ocupacion y recaudacion por funcion
-- Ocupacion = asientos vendidos / capacidad de la sala.
-- Ingresos  = suma del precio final de los boletos validos o usados.

CREATE OR REPLACE VIEW v_ocupacion_funcion AS
SELECT f.funcion_id,
       p.titulo,
       c.nombre   AS cine,
       s.nombre   AS sala,
       f.inicio,
       s.capacidad,
       COALESCE(o.vendidos, 0)                                   AS asientos_vendidos,
       round(100.0 * COALESCE(o.vendidos, 0) / s.capacidad, 2)   AS porcentaje_ocupacion,
       COALESCE(i.ingresos, 0)                                   AS ingresos
FROM funcion f
JOIN pelicula p ON p.pelicula_id = f.pelicula_id
JOIN sala s     ON s.sala_id = f.sala_id
JOIN cine c     ON c.cine_id = s.cine_id
LEFT JOIN LATERAL (
    SELECT count(*) AS vendidos
    FROM funcion_asiento fa
    WHERE fa.funcion_id = f.funcion_id AND fa.estado = 'vendido'
) o ON TRUE
LEFT JOIN LATERAL (
    SELECT sum(b.precio_final) AS ingresos
    FROM boleto b
    WHERE b.funcion_id = f.funcion_id AND b.estado IN ('valido', 'usado')
) i ON TRUE;
 

-- Ventas por dia (tendencia de compra para el dashboard)

CREATE OR REPLACE VIEW v_ventas_diarias AS
SELECT fecha_emision::date AS dia,
       count(*)            AS boletos,
       sum(precio_final)   AS ingresos
FROM boleto
WHERE estado IN ('valido', 'usado')
GROUP BY fecha_emision::date;