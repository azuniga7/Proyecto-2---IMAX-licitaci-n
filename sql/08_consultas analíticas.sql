-- 08_consultas_analiticas.sql  |  Proyecto 2: Licitacion IMAX
-- Las 4 consultas analiticas que la gerencia revisa con regularidad.
-- Son solo SELECT, no cambian datos. En pgAdmin, selecciona una consulta
-- y ejecuta solo esa (si corres todo el archivo, solo se ve el ultimo resultado).
-- Requiere las vistas de 06_vistas.sql.

 
-- CONSULTA 1: Ocupacion y recaudacion por funcion
-- Porcentaje de asientos vendidos contra la capacidad de la sala e ingresos
-- totales de una funcion. Cambia el 1 por el funcion_id que quieras revisar.
-- (La logica esta en la vista v_ocupacion_funcion.)
SELECT funcion_id, titulo, cine, sala, inicio,
       capacidad, asientos_vendidos, porcentaje_ocupacion, ingresos
FROM v_ocupacion_funcion
WHERE funcion_id = 1;
 
-- CONSULTA 2: Top 5 de peliculas mas demandadas en la ultima semana
-- Cuenta los boletos emitidos (validos o usados) en los ultimos 7 dias, a nivel
-- global. Los boletos anulados o reembolsados no cuentan.

SELECT p.pelicula_id,
       p.titulo,
       count(*) AS boletos_vendidos
FROM boleto b
JOIN funcion  f ON f.funcion_id  = b.funcion_id
JOIN pelicula p ON p.pelicula_id = f.pelicula_id
WHERE b.estado IN ('valido', 'usado')
  AND b.fecha_emision >= now() - interval '7 days'
GROUP BY p.pelicula_id, p.titulo
ORDER BY boletos_vendidos DESC, p.titulo
LIMIT 5;
 

-- CONSULTA 3: Metodos de pago preferidos (porcentaje de uso)
-- Se toman solo los pagos aprobados.

SELECT mp.nombre AS metodo_pago,
       count(*)  AS pagos,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS porcentaje
FROM pago pa
JOIN metodo_pago mp ON mp.metodo_pago_id = pa.metodo_pago_id
WHERE pa.estado = 'aprobado'
GROUP BY mp.nombre
ORDER BY pagos DESC;
 

-- CONSULTA 4: Auditoria de operaciones criticas del ultimo mes
-- Todas las modificaciones manuales (cortesias, cambios de asiento,
-- reembolsos forzados, cambios de precio y de configuracion) agrupadas por
-- administrador. La bitacora solo guarda operaciones manuales.

 
-- 4a. Resumen: cuantas operaciones hizo cada administrador, por tipo
SELECT a.usuario_id,
       u.nombre || ' ' || u.apellido AS administrador,
       a.accion,
       count(*)     AS operaciones,
       min(a.fecha) AS primera,
       max(a.fecha) AS ultima
FROM admin_operacion_audit a
JOIN usuario u ON u.usuario_id = a.usuario_id
WHERE a.fecha >= now() - interval '1 month'
GROUP BY a.usuario_id, u.nombre, u.apellido, a.accion
ORDER BY a.usuario_id, operaciones DESC;
 
-- 4b. Detalle: cada operacion, con la fecha, la IP y el motivo
SELECT a.usuario_id,
       a.fecha,
       a.accion,
       a.tabla_afectada,
       a.registro_id,
       a.ip,
       a.detalle ->> 'motivo' AS motivo,
       a.detalle
FROM admin_operacion_audit a
WHERE a.fecha >= now() - interval '1 month'
ORDER BY a.usuario_id, a.fecha;