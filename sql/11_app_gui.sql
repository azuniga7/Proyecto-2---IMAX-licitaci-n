---------------------------------------------------------------------------
-- 11_app_gui.sql  |  Proyecto 2: Licitacion IMAX
-- Soporte de base de datos para la interfaz web (carpeta gui/).
-- Correr como postgres, despues de 01 a 07 (y de preferencia con los datos
-- de 09_datos_prueba.sql). Se puede correr mas de una vez sin problema.
--
-- Que hace:
--   1. Crea el login "app_imax", que es con el que se conecta la aplicacion.
--      No tiene permisos propios sobre las tablas. Para cada peticion la app
--      hace SET ROLE al rol del usuario que inicio sesion (rol_cliente,
--      rol_taquillero, etc.), asi que los permisos del script 07 se respetan.
--   2. fn_login_usuario: busca un usuario por correo sin exponer password_hash.
--   3. Tres vistas para que el cliente y el taquillero vean tarifas y su compra
--      sin tener permiso sobre las tablas tarifa/compra/boleto.
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- 1. Login de la aplicacion
-- Cambia la contrasena si quieres (y usa la misma en la variable
-- IMAX_DB_PASSWORD de la app).
---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_imax') THEN
        CREATE ROLE app_imax LOGIN NOINHERIT PASSWORD 'imax_app_2026';
    END IF;
END $$;

GRANT USAGE ON SCHEMA public TO app_imax;

-- WITH INHERIT FALSE: app_imax puede cambiarse a estos roles (SET ROLE),
-- pero no hereda sus permisos mientras no lo haga.
GRANT rol_cliente       TO app_imax WITH INHERIT FALSE;
GRANT rol_taquillero    TO app_imax WITH INHERIT FALSE;
GRANT rol_operador_sala TO app_imax WITH INHERIT FALSE;
GRANT rol_contador      TO app_imax WITH INHERIT FALSE;
GRANT rol_administrador TO app_imax WITH INHERIT FALSE;

---------------------------------------------------------------------------
-- 2. Login por correo
-- Los usuarios demo del script 09 tienen password_hash = 'hash_demo', asi que
-- no hay contrasenas reales que verificar: el login de la demo es por correo.
-- La funcion no devuelve el hash en ningun caso.
---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_login_usuario(p_correo VARCHAR)
RETURNS TABLE (usuario_id BIGINT, nombre VARCHAR, apellido VARCHAR, rol VARCHAR)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT u.usuario_id, u.nombre, u.apellido, r.nombre
    FROM usuario u
    JOIN rol r ON r.rol_id = u.rol_id
    WHERE lower(u.correo) = lower(p_correo)
      AND u.activo;
$$;

REVOKE ALL ON FUNCTION fn_login_usuario(VARCHAR) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_login_usuario(VARCHAR) TO app_imax;

---------------------------------------------------------------------------
-- 3. Vistas para la compra
-- Las vistas se ejecutan con los permisos de quien las creo, por eso el
-- cliente puede leerlas sin tener acceso a las tablas de abajo (igual que
-- v_mis_boletos). La interfaz siempre filtra por el usuario de la sesion.
---------------------------------------------------------------------------

-- Precios de una funcion por zona y tipo de entrada
CREATE OR REPLACE VIEW v_tarifas_funcion AS
SELECT t.funcion_id,
       z.nombre  AS zona,
       te.tipo_entrada_id,
       te.nombre AS tipo_entrada,
       t.precio
FROM tarifa t
JOIN zona z          ON z.zona_id = t.zona_id
JOIN tipo_entrada te ON te.tipo_entrada_id = t.tipo_entrada_id;

-- Totales de una compra y hora en que vence el bloqueo de sus asientos
CREATE OR REPLACE VIEW v_compra_resumen AS
SELECT c.compra_id,
       c.usuario_id,
       c.vendedor_id,
       c.canal,
       c.estado,
       c.subtotal,
       c.descuento,
       c.cargo_servicio,
       c.total,
       c.fecha_creacion,
       l.bloqueo_hasta
FROM compra c
LEFT JOIN LATERAL (
    SELECT min(fa.bloqueado_hasta) AS bloqueo_hasta
    FROM boleto b
    JOIN funcion_asiento fa
      ON fa.funcion_id = b.funcion_id AND fa.asiento_id = b.asiento_id
    WHERE b.compra_id = c.compra_id AND fa.estado = 'bloqueado'
) l ON TRUE;

-- Boletos de una compra (incluye los reservados que aun no se pagan).
-- codigo_qr solo existe cuando el boleto esta valido o usado (RN-11).
CREATE OR REPLACE VIEW v_compra_boletos AS
SELECT c.compra_id,
       c.usuario_id,
       c.vendedor_id,
       c.estado    AS estado_compra,
       b.boleto_id,
       f.funcion_id,
       p.titulo,
       ci.nombre   AS cine,
       s.nombre    AS sala,
       f.inicio,
       z.nombre    AS zona,
       a.fila,
       a.numero,
       te.nombre   AS tipo_entrada,
       b.precio_final,
       b.estado,
       b.codigo_qr
FROM compra c
JOIN boleto b        ON b.compra_id = c.compra_id
JOIN funcion f       ON f.funcion_id = b.funcion_id
JOIN pelicula p      ON p.pelicula_id = f.pelicula_id
JOIN sala s          ON s.sala_id = f.sala_id
JOIN cine ci         ON ci.cine_id = s.cine_id
JOIN asiento a       ON a.asiento_id = b.asiento_id
JOIN zona z          ON z.zona_id = a.zona_id
JOIN tipo_entrada te ON te.tipo_entrada_id = b.tipo_entrada_id;

GRANT SELECT ON v_tarifas_funcion, v_compra_resumen, v_compra_boletos
    TO rol_cliente, rol_taquillero;

